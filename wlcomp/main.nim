import std/[os, posix, osproc]
import wlroots
import types
import output
import toplevel
import input
import layershell
import seatext
import xwayland
import session
import idle
import gestures

## NAPRAWIONY BRAK (IPC): zmiana monitorów/klawiatury w Ustawieniach
## (zde-shell) wymagała ręcznego restartu zde-comp -- configi były czytane
## tylko raz przy starcie. SIGHUP to standardowa uniksowa konwencja
## "przeładuj konfigurację" (nginx, sshd...). zde-shell, po zapisaniu
## configu, znajduje PID kompozytora w pliku `$XDG_RUNTIME_DIR/zde-comp.pid`
## (zapisywanym poniżej przy starcie) i wysyła SIGHUP -- patrz
## `apps/settings/settings.nim`, `reloadCompositor()`.
proc pidFilePath(): string =
  (if getEnv("XDG_RUNTIME_DIR", "").len > 0: getEnv("XDG_RUNTIME_DIR") else: "/tmp") / "zde-comp.pid"

## Rozbudowa v0.2 (kompozytor -- autostart zde-shell): do tej pory
## `zde-comp` NIGDY nie uruchamiał `zde-shell` samo z siebie -- trzeba
## było ręcznie odpalić je z DRUGIEGO TTY ze wskazanym WAYLAND_DISPLAY
## (patrz "Wariant A" w README, krok 5) -- README jawnie wymieniało to
## jako TODO: "docelowo zde-comp powinien sam odpalać zde-shell jako
## swój 'startup command' zamiast wymagać dwóch TTY". Ta para funkcji to
## domknięcie tego TODO.
proc findShellBinary(): string =
  ## `ZDE_SHELL_PATH`, jeśli ustawione, ZAWSZE wygrywa -- przydatne przy
  ## debugowaniu (np. wskazanie na wariant X11 zamiast Wayland, albo na
  ## binarkę zbudowaną w innym katalogu). W przeciwnym razie szukamy
  ## `zde-shell` W TYM SAMYM katalogu co uruchomiony binarny `zde-comp`
  ## (`getAppDir()`) -- oba binarki lądują razem w `dist/` (patrz
  ## `zde.nimble`/`build.janet`), więc to jedyne miejsce, o którym
  ## `zde-comp` może z rozsądną pewnością założyć, że "prawdopodobnie
  ## tam jest" -- nie polegamy na PATH ani na bieżącym katalogu roboczym
  ## (ten drugi zależy od tego, skąd użytkownik odpalił `zde-comp`, co
  ## jest niezawodne tylko przy pracy z `dist/` jako CWD, tak jak opisuje
  ## "Wariant A" w README, ale niekoniecznie ogólnie).
  let override = getEnv("ZDE_SHELL_PATH", "")
  if override.len > 0: return override
  let candidate = getAppDir() / "zde-shell"
  if fileExists(candidate): return candidate
  ""

proc spawnShell(socketName: string) =
  ## Wołane PO ustawieniu WAYLAND_DISPLAY (i DISPLAY, jeśli XWayland
  ## wystartowało) w środowisku BIEŻĄCEGO procesu (`putEnv` w `main()`
  ## niżej) -- `startProcess` domyślnie DZIEDZICZY środowisko procesu
  ## wołającego (Nim nie czyści go, chyba że jawnie poda się `env=`), więc
  ## `zde-shell` (i jego własne dzieci, np. aplikacje z launchera)
  ## dostają oba automatycznie, bez przepychania ich osobno.
  ##
  ## Świadomie "best effort", tak jak reszta integracji zewnętrznych
  ## narzędzi w ZDE (patrz np. `shell/sound.nim`, `shell/quicksettings.nim`):
  ## brak `zde-shell` obok `zde-comp` albo błąd `startProcess` NIE
  ## zatrzymuje kompozytora -- logujemy na stderr i użytkownik może
  ## zawsze odpalić powłokę ręcznie (dokładnie jak w "Wariant A" dziś),
  ## kompozytor sam w sobie jest w pełni użyteczny bez niej (można np.
  ## zamiast tego odpalić inny klient Wayland).
  if getEnv("ZDE_NO_AUTOSTART", "").len > 0:
    stderr.writeLine("zde-comp: ZDE_NO_AUTOSTART ustawione -- pomijam autostart zde-shell")
    return
  let path = findShellBinary()
  if path.len == 0:
    stderr.writeLine("zde-comp: nie znaleziono zde-shell obok zde-comp (ani ZDE_SHELL_PATH nie " &
      "ustawione) -- pomijam autostart; uruchom ręcznie: WAYLAND_DISPLAY=" & socketName & " zde-shell")
    return
  try:
    discard startProcess(path, options = {poStdErrToStdOut, poUsePath, poDaemon})
    stderr.writeLine("zde-comp: uruchomiono " & path & " (WAYLAND_DISPLAY=" & socketName & ")")
  except OSError as e:
    stderr.writeLine("zde-comp: nie udało się uruchomić " & path & ": " & e.msg &
      " -- uruchom ręcznie: WAYLAND_DISPLAY=" & socketName & " zde-shell")

var gServer: Server  ## potrzebny w handlerze sygnału -- wl_event_loop_add_signal
                      ## i tak przekazuje `data`, ale trzymanie w globalnej
                      ## zmiennej jest prostsze niż przepychanie przez `pointer`
                      ## i rzutowanie z powrotem na ref-obiekt Nim

proc onSighup(signalNumber: cint, data: pointer): cint {.cdecl.} =
  stderr.writeLine("zde-comp: SIGHUP -- przeładowuję konfigurację")
  if gServer != nil:
    reloadOutputLayout(gServer)
    reloadKeyboardLayouts(gServer)
  return 0

proc main() =
  let server = Server()
  gServer = server
  server.display = wlDisplayCreate()
  server.backend = wlrBackendAutocreate(server.display, addr server.session)
  if server.backend == nil:
    quit("zde-comp: wlr_backend_autocreate() nie powiodło się")
  ## Rozbudowa v0.1 ("Aurora"/DRM): `server.session` jest teraz naprawdę
  ## wypełnione (gdy backend go używa -- patrz komentarz w `shim.c`),
  ## dzięki czemu `hookSessionActive` niżej (po utworzeniu `seat`u, bo
  ## dopiero wtedy sygnał ma sens jako "trzeba wybudzić kompozytor") może
  ## faktycznie nasłuchiwać na przełączanie VT. Patrz `wlcomp/session.nim`.

  server.renderer = wlrRendererAutocreate(server.backend)
  if server.renderer == nil:
    quit("zde-comp: wlr_renderer_autocreate() nie powiodło się")
  ## NAPRAWIONY BRAK/BUG (znaleziony dopiero przy realnym uruchomieniu pod
  ## zagnieżdżonym backendem X11 -- patrz NAPRAWY.md): `wl_shm` był
  ## rejestrowany DWA RAZY -- raz poprawnie, powiązany z rendererem, przez
  ## `wlr_renderer_init_wl_display()` poniżej (jej dokumentacja: "Initializes
  ## wl_shm, linux-dmabuf and other buffer factory protocols"), i raz przez
  ## `zde_display_init_shm()` (goły `wl_display_init_shm()`, BEZ żadnego
  ## powiązania z rendererem). Klient widział więc DWA globalne obiekty
  ## `wl_shm` w rejestrze (potwierdzone testowym klientem -- log pokazywał
  ## `global: wl_shm (v1)` dwukrotnie) i mógł się podpiąć pod ten "gołý",
  ## niepowiązany z rendererem -- bufory utworzone przez taki wl_shm
  ## kompozytor nie potrafił zaimportować do tekstury przy renderowaniu
  ## (`[ERROR] Unknown buffer type` w logu kompozytora, mimo że klient
  ## poprawnie zmapował swoją powierzchnię). Usunięte zbędne drugie wywołanie.
  if not wlrRendererInitWlDisplay(server.renderer, server.display):
    quit("zde-comp: wlr_renderer_init_wl_display() nie powiodło się")
  server.allocator = wlrAllocatorAutocreate(server.backend, server.renderer)
  if server.allocator == nil:
    quit("zde-comp: wlr_allocator_autocreate() nie powiodło się")

  server.compositor = wlrCompositorCreate(server.display, 5, server.renderer)
  discard wlrSubcompositorCreate(server.display)
  server.dataDeviceMgr = wlrDataDeviceManagerCreate(server.display)
  ## Rozbudowa v0.2 ("primary selection", patrz `wlcomp/seatext.nim`) --
  ## sam `_create()` wystawia protokół `zwp_primary_selection_v1` w
  ## rejestrze Waylanda (jak `wlrDataDeviceManagerCreate` wyżej dla
  ## zwykłego schowka); nasłuch na `request_set_primary_selection` jest
  ## podpięty niżej, razem z resztą zdarzeń `seat`u (bo wymaga
  ## `server.seat`, który powstaje kawałek dalej).
  server.primarySelectionMgr = wlrPrimarySelectionV1DeviceManagerCreate(server.display)

  server.outputLayout = wlrOutputLayoutCreate(server.display)
  server.scene = wlrSceneCreate()
  server.sceneLayout = wlrSceneAttachOutputLayout(server.scene, server.outputLayout)

  ## Cztery stałe warstwy sceny, utworzone w tej kolejności RAZ (kolejność
  ## dodania = kolejność z-order w wlroots -- patrz duży komentarz w
  ## types.nim i layershell.nim). Zwykłe okna aplikacji (toplevelTree) są
  ## między "bottom" a "top", więc panel/pasek zadeklarowany w warstwie
  ## "top" zawsze zostaje nad nimi.
  server.bgTree = wlrSceneTreeCreate(cast[ptr WlrSceneTree](server.scene))
  server.bottomTree = wlrSceneTreeCreate(cast[ptr WlrSceneTree](server.scene))
  server.toplevelTree = wlrSceneTreeCreate(cast[ptr WlrSceneTree](server.scene))
  server.topTree = wlrSceneTreeCreate(cast[ptr WlrSceneTree](server.scene))
  server.overlayTree = wlrSceneTreeCreate(cast[ptr WlrSceneTree](server.scene))

  server.xdgShell = wlrXdgShellCreate(server.display, 3)
  zdeSignalAdd(addr xdgShellEvents(server.xdgShell).newSurface, addr server.newXdgSurfaceL, onNewXdgSurface)

  server.layerShell = wlrLayerShellV1Create(server.display, 4)
  zdeSignalAdd(addr layerShellEvents(server.layerShell).newSurface, addr server.newLayerSurfaceL, onNewLayerSurface)

  server.cursor = wlrCursorCreate()
  wlrCursorAttachOutputLayout(server.cursor, server.outputLayout)
  server.xcursorMgr = wlrXcursorManagerCreate(nil, CursorSizePx)
  discard wlrXcursorManagerLoad(server.xcursorMgr, 1.0)

  zdeSignalAdd(addr cursorEvents(server.cursor).motion, addr server.cursorMotionL, onCursorMotion)
  zdeSignalAdd(addr cursorEvents(server.cursor).motionAbsolute, addr server.cursorMotionAbsL, onCursorMotionAbsolute)
  zdeSignalAdd(addr cursorEvents(server.cursor).button, addr server.cursorButtonL, onCursorButton)
  zdeSignalAdd(addr cursorEvents(server.cursor).axis, addr server.cursorAxisL, onCursorAxis)
  zdeSignalAdd(addr cursorEvents(server.cursor).frame, addr server.cursorFrameL, onCursorFrame)

  server.seat = wlrSeatCreate(server.display, SeatName)
  zdeSignalAdd(addr seatEvents(server.seat).requestSetSelection, addr server.requestSetSelectionL, onRequestSetSelection)
  ## Rozbudowa v0.2 ("primary selection") -- patrz komentarze przy
  ## `server.primarySelectionMgr` wyżej i `onRequestSetPrimarySelection`
  ## w `wlcomp/seatext.nim`.
  zdeSignalAdd(addr seatEvents(server.seat).requestSetPrimarySelection, addr server.requestSetPrimarySelectionL, onRequestSetPrimarySelection)
  zdeSignalAdd(addr seatEvents(server.seat).requestStartDrag, addr server.requestStartDragL, onRequestStartDrag)
  zdeSignalAdd(addr seatEvents(server.seat).startDrag, addr server.startDragL, onStartDrag)

  ## Rozbudowa v0.1 ("Aurora"/DRM) -- patrz `wlcomp/session.nim`.
  hookSessionActive(server)
  ## Rozbudowa v0.1 ("Aurora"/DRM, DPMS) -- patrz `wlcomp/idle.nim`.
  hookIdle(server)
  ## Rozbudowa v0.1 ("Aurora"/gesty) -- patrz `wlcomp/gestures.nim`.
  hookGestures(server)

  zdeSignalAdd(addr backendEvents(server.backend).newOutput, addr server.newOutputL, onNewOutput)
  zdeSignalAdd(addr backendEvents(server.backend).newInput, addr server.newInputL, onNewInput)

  let eventLoop = wlDisplayGetEventLoop(server.display)
  discard wlEventLoopAddSignal(eventLoop, cint(SIGHUP), onSighup, nil)

  if not wlrBackendStart(server.backend):
    wlrBackendDestroy(server.backend)
    wlDisplayDestroy(server.display)
    quit("zde-comp: wlr_backend_start() nie powiodło się")

  let socket = wlDisplayAddSocketAuto(server.display)
  if socket == nil:
    wlrBackendDestroy(server.backend)
    quit("zde-comp: nie udało się utworzyć socketu Waylanda")
  putEnv("WAYLAND_DISPLAY", $socket)

  server.xwayland = wlrXwaylandCreate(server.display, server.compositor, false)
  if server.xwayland != nil:
    wlrXwaylandSetSeat(server.xwayland, server.seat)
    ## Rozbudowa v0.1 ("Aurora"/XWayland): do tej pory kompozytor
    ## URUCHAMIAŁ proces Xwayland, ale nigdy nie nasłuchiwał na jego
    ## `events.new_surface` -- więc żadne okno X11 nigdy nie trafiało do
    ## sceny/listy `toplevels` (patrz `wlcomp/xwayland.nim` i komentarz
    ## "ZWERYFIKOWANE KOMPILACJĄ" nad `WlrXwayland` w `wlroots.nim`).
    zdeSignalAdd(addr xwaylandEvents(server.xwayland).newSurface, addr server.newXwaylandSurfaceL, onNewXwaylandSurface)
    ## `display_name` (np. ":2") to prawdziwe pole z `wlr_xwayland`, nie
    ## placeholder -- patrz `WlrXwayland` w `wlroots.nim`.
    let dn = if server.xwayland.displayName != nil: $server.xwayland.displayName else: "?"
    stderr.writeLine("zde-comp: XWayland gotowy na DISPLAY=" & dn)
    ## Rozbudowa v0.2 (autostart zde-shell, patrz komentarz nad
    ## `spawnShell` wyżej): DISPLAY też trzeba wystawić w środowisku
    ## BIEŻĄCEGO procesu (`putEnv`), nie tylko zalogować -- wcześniej nie
    ## było to nigdzie robione (patrz `grep putEnv` sprzed tej rundy: tylko
    ## WAYLAND_DISPLAY). Bez tego dzieci `zde-shell` odpalane przez
    ## launcher (np. terminal) NIE dostawałyby DISPLAY automatycznie, gdyby
    ## kiedyś chciały odpalić starą aplikację X11 przez XWayland.
    if dn != "?":
      putEnv("DISPLAY", dn)

  stderr.writeLine("zde-comp: uruchomiony na WAYLAND_DISPLAY=" & $socket)
  spawnShell($socket)

  try:
    writeFile(pidFilePath(), $getCurrentProcessId())
  except IOError:
    stderr.writeLine("zde-comp: nie udało się zapisać " & pidFilePath() & " -- SIGHUP z Ustawień nie zadziała, ale reszta kompozytora działa normalnie")

  wlDisplayRun(server.display)

  try:
    removeFile(pidFilePath())
  except OSError:
    discard
  wlDisplayDestroyClients(server.display)
  if server.xwayland != nil:
    wlrXwaylandDestroy(server.xwayland)
  wlDisplayDestroy(server.display)

when isMainModule:
  main()
