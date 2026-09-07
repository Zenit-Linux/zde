import std/[os, posix]
import wlroots
import types
import output
import toplevel
import input
import layershell
import seatext

## NAPRAWIONY BRAK (IPC): zmiana monitorów/klawiatury w Ustawieniach
## (zde-shell) wymagała ręcznego restartu zde-comp -- configi były czytane
## tylko raz przy starcie. SIGHUP to standardowa uniksowa konwencja
## "przeładuj konfigurację" (nginx, sshd...). zde-shell, po zapisaniu
## configu, znajduje PID kompozytora w pliku `$XDG_RUNTIME_DIR/zde-comp.pid`
## (zapisywanym poniżej przy starcie) i wysyła SIGHUP -- patrz
## `apps/settings/settings.nim`, `reloadCompositor()`.
proc pidFilePath(): string =
  (if getEnv("XDG_RUNTIME_DIR", "").len > 0: getEnv("XDG_RUNTIME_DIR") else: "/tmp") / "zde-comp.pid"

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
  server.backend = wlrBackendAutocreate(server.display)
  if server.backend == nil:
    quit("zde-comp: wlr_backend_autocreate() nie powiodło się")

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
  zdeSignalAdd(addr seatEvents(server.seat).requestStartDrag, addr server.requestStartDragL, onRequestStartDrag)
  zdeSignalAdd(addr seatEvents(server.seat).startDrag, addr server.startDragL, onStartDrag)

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
    stderr.writeLine("zde-comp: XWayland gotowy na DISPLAY=" & "(patrz zmienna środowiskowa DISPLAY procesu Xwayland)")

  stderr.writeLine("zde-comp: uruchomiony na WAYLAND_DISPLAY=" & $socket)

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
