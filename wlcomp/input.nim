import std/sequtils
import wlroots
import types
import toplevel
import session
import idle
import ../zdeconfig

proc processCursorMotion*(server: Server, timeMsec: uint32) =
  if server.dragIconTree != nil:
    ## Ikonka przeciąganego obiektu (drag&drop) jedzie razem z kursorem,
    ## niezależnie od trybu (move/resize/passthrough) -- patrz seatext.nim.
    wlrSceneNodeSetPosition(treeNode(server.dragIconTree), cint(server.cursor.x), cint(server.cursor.y))

  case server.cursorMode
  of cmMove:
    if server.grabbed != nil:
      let node = treeNode(server.grabbed.sceneTree)
      wlrSceneNodeSetPosition(node, cint(server.cursor.x), cint(server.cursor.y))
    return
  of cmResize:
    if server.grabbed != nil:
      let box = geometryOf(server.grabbed)
      let newW = max(cint(1), cint(server.cursor.x) - box.x)
      let newH = max(cint(1), cint(server.cursor.y) - box.y)
      ## Rozbudowa v0.1 (XWayland): okna X11 nie mają `wlr_xdg_toplevel`,
      ## więc zmiana rozmiaru idzie przez `wlr_xwayland_surface_configure`
      ## zamiast `wlr_xdg_toplevel_set_size` -- patrz `surfaceOf`/
      ## `geometryOf` w `toplevel.nim` i duży komentarz przy `ToplevelObj`
      ## w `types.nim`.
      if server.grabbed.xdgSurface != nil and server.grabbed.xdgSurface.toplevel != nil:
        discard wlrXdgToplevelSetSize(server.grabbed.xdgSurface.toplevel, newW, newH)
      elif server.grabbed.xwaylandSurface != nil:
        wlrXwaylandSurfaceConfigure(server.grabbed.xwaylandSurface,
          int16(box.x), int16(box.y), uint16(newW), uint16(newH))
    return
  of cmPassthrough:
    discard

  let t = toplevelAt(server, server.cursor.x, server.cursor.y)
  if t != nil and surfaceOf(t) != nil:
    wlrSeatPointerNotifyEnter(server.seat, surfaceOf(t), 0, 0)
    wlrSeatPointerNotifyMotion(server.seat, timeMsec, 0, 0)
  else:
    wlrCursorSetXcursor(server.cursor, server.xcursorMgr, "default")
    wlrSeatPointerNotifyClearFocus(server.seat)

proc onCursorMotion*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, cursorMotionL)
  let event = cast[ptr WlrPointerMotionEvent](data)
  wlrCursorMove(server.cursor, nil, event.deltaX, event.deltaY)
  processCursorMotion(server, event.timeMsec)

proc onCursorMotionAbsolute*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, cursorMotionAbsL)
  # (uproszczenie v1: traktujemy jak względny ruch do centrum; pełna obsługa
  # bezwzględnych współrzędnych -- np. tabletów graficznych -- to TODO)
  processCursorMotion(server, 0)

proc onCursorButton*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, cursorButtonL)
  let event = cast[ptr WlrPointerButtonEvent](data)
  discard wlrSeatPointerNotifyButton(server.seat, event.timeMsec, event.button, uint32(event.state))
  if event.state == 0'i32:  # released
    if server.cursorMode != cmPassthrough:
      server.cursorMode = cmPassthrough
      server.grabbed = nil
  else:
    let t = toplevelAt(server, server.cursor.x, server.cursor.y)
    if t != nil:
      focusToplevel(t)

proc onCursorAxis*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  ## NAPRAWIONY BRAK: przewijanie (scroll) było odrzucane (`discard event`)
  ## zamiast przekazane do klienta z fokusem wskaźnika -- więc scroll
  ## kółkiem myszy nie działał w ŻADNEJ aplikacji uruchomionej pod
  ## zde-comp. `wlr_seat_pointer_notify_axis` przekazuje zdarzenie do
  ## powierzchni z aktualnym fokusem (uwzględniając ewentualny grab), tak
  ## jak `wlr_seat_pointer_notify_motion`/`_button` już były przekazywane
  ## wyżej -- to samo trzeba było zrobić dla osi (scrolla), tylko
  ## wcześniej tego brakowało. (Naprawiony też błąd zgłoszony przy
  ## realnym buildzie na wlroots 0.20: `wlr_seat_pointer_notify_axis()`
  ## od 0.18.0 przyjmuje dodatkowy 7. argument, `relative_direction` --
  ## rozwiązane C-shimem w shim.c, ten sam wzorzec co reszta niezgodności
  ## wersji w tym pliku, patrz NAPRAWY.md.)
  let server = containerOf(listener, Server, ServerObj, cursorAxisL)
  let event = cast[ptr WlrPointerAxisEvent](data)
  wlrSeatPointerNotifyAxis(
    server.seat, event.timeMsec, event.orientation, event.delta,
    event.deltaDiscrete, event.source,
  )

proc onCursorFrame*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, cursorFrameL)
  wlrSeatPointerNotifyFrame(server.seat)
  ## Rozbudowa v0.1 ("Aurora"/DPMS) -- "frame" domyka każdą paczkę zdarzeń
  ## wskaźnika (ruch/przycisk/scroll), więc to jeden wygodny punkt na
  ## zgłoszenie aktywności zamiast wpinania tego w 4 różne handlery
  ## (motion/motion-absolute/button/axis) osobno. Patrz `wlcomp/idle.nim`.
  notifyActivity(server)

# ---------------------------------------------------------------------------
# Klawiatura
# ---------------------------------------------------------------------------

const EvdevKeyTab = 15'u32

proc onKeyboardKey*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let kb = containerOf(listener, Keyboard, KeyboardObj, keyL)
  let event = cast[ptr WlrKeyboardKeyEvent](data)
  let pressed = event.state == cint(WL_KEYBOARD_KEY_STATE_PRESSED)
  ## Rozbudowa v0.1 ("Aurora"/DPMS) -- patrz `wlcomp/idle.nim`. Każdy
  ## klawisz (nawet skróty połknięte niżej, jak VT-switch/Alt+Tab) liczy
  ## się jako aktywność -- użytkownik ewidentnie jest przy komputerze.
  notifyActivity(kb.server)
  ## Rozbudowa v0.1 ("Aurora"/DRM): Ctrl+Alt+F<n> to pierwszy i jedyny na
  ## razie skrót przechwytywany na poziomie KOMPOZYTORA -- do tej pory
  ## `onKeyboardKey` bezwarunkowo przekazywało WSZYSTKO do klienta pod
  ## fokusem, więc nawet gdyby użytkownik nacisnął VT-switch, kompozytor
  ## by o tym nie wiedział (samo przełączenie i tak by zaszło -- to jądro/
  ## logind je obsługuje niezależnie od aplikacji -- ale patrz
  ## `wlcomp/session.nim` o tym, co bez tego NIE działałoby po powrocie).
  if tryHandleVtSwitch(kb.server, kb.wlrKeyboard, event.keycode, pressed):
    return
  ## Rozbudowa v0.1 ("Aurora"): Alt+Tab -- karuzela pełnoprawna, przewija
  ## po wszystkich oknach dopóki Alt jest trzymany (Shift = kierunek
  ## odwrotny), zatwierdzana dopiero puszczeniem Alt (patrz `commitAltTab`,
  ## wołane niżej w `onKeyboardModifiers` gdy bit ALT znika z maski).
  ## "Połykamy" zdarzenie (nie przekazujemy dalej do klienta) niezależnie
  ## od tego, czy w ogóle było co przełączyć -- Tab z wciśniętym Alt nigdy
  ## nie powinien trafić do aplikacji jako zwykły Tab (np. zmiana fokusu
  ## pola formularza), to by było mylące.
  if pressed and event.keycode == EvdevKeyTab:
    let mods = wlrKeyboardGetModifiers(kb.wlrKeyboard)
    if (mods and WlrModifierAlt) != 0:
      cycleAltTab(kb.server, (mods and WlrModifierShift) != 0)
      return
  wlrSeatKeyboardNotifyKey(kb.server.seat, event.timeMsec, event.keycode, uint32(event.state))

proc onKeyboardModifiers*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let kb = containerOf(listener, Keyboard, KeyboardObj, modifiersL)
  wlrSeatSetKeyboard(kb.server.seat, kb.wlrKeyboard)
  wlrSeatKeyboardNotifyModifiers(kb.server.seat, nil)
  ## Rozbudowa v0.1 ("Aurora"): to jest miejsce, gdzie wykrywamy PUSZCZENIE
  ## Alt -- `onKeyboardKey` widzi tylko pojedyncze klawisze, a modyfikatory
  ## (Ctrl/Alt/Shift/Logo) dostają WŁASNE zdarzenie `modifiers` przy każdej
  ## zmianie stanu. Gdy karuzela Alt+Tab jest aktywna i Alt akurat zniknął
  ## z maski, zatwierdzamy wybór -- patrz `commitAltTab` w `toplevel.nim`.
  if kb.server.altTabActive:
    let mods = wlrKeyboardGetModifiers(kb.wlrKeyboard)
    if (mods and WlrModifierAlt) == 0:
      commitAltTab(kb.server)

proc onKeyboardDestroy*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let kb = containerOf(listener, Keyboard, KeyboardObj, destroyL)
  zdeListRemove(addr kb.keyL.link)
  zdeListRemove(addr kb.modifiersL.link)
  zdeListRemove(addr kb.destroyL.link)
  kb.server.keyboards.keepItIf(it != kb)

proc buildKeymap(layout: string): ptr XkbKeymap =
  let ctx = xkbContextNew(0)
  var names: XkbRuleNames
  names.layout = layout.cstring
  xkbKeymapNewFromNames(ctx, addr names, 0)

proc reloadKeyboardLayouts*(server: Server) =
  ## Wołane z obsługi SIGHUP (main.nim) -- ponownie wczytuje
  ## `xkbLayout` z configu i nakłada nową mapę klawiszy na WSZYSTKIE
  ## aktualnie podłączone klawiatury, bez restartu kompozytora ani
  ## rozłączania klientów. `wlr_keyboard_set_keymap` samo wysyła klientom
  ## zaktualizowaną mapę (przez `keymap` na `wl_keyboard`).
  let cfg = zdeconfig.loadConfig()
  let keymap = buildKeymap(cfg.xkbLayout)
  var count = 0
  for kb in server.keyboards:
    discard wlrKeyboardSetKeymap(kb.wlrKeyboard, keymap)
    inc count
  stderr.writeLine("zde-comp: przeładowano układ klawiatury (\"" & cfg.xkbLayout & "\") na " & $count & " urządzeniach")

proc setupKeyboard*(server: Server, dev: ptr WlrInputDevice) =
  let wlrKb = wlrKeyboardFromInputDevice(dev)
  let kb = Keyboard(server: server, wlrKeyboard: wlrKb)

  ## NAPRAWIONY BRAK: układ klawiatury był na sztywno "us", niezależnie od
  ## tego, co użytkownik ustawiłby w aplikacji "Ustawienia"
  ## (apps/settings/settings.nim, pole `xkbLayout` w zdeconfig.nim). Teraz
  ## czytamy to z tego samego pliku konfiguracyjnego co Ustawienia --
  ## zmiana układu w UI i SIGHUP do zde-comp (patrz `reloadKeyboardLayouts`
  ## wyżej i obsługa sygnału w main.nim) faktycznie coś zmienia, bez
  ## restartu.
  let cfg = zdeconfig.loadConfig()
  let keymap = buildKeymap(cfg.xkbLayout)
  discard wlrKeyboardSetKeymap(wlrKb, keymap)
  wlrKeyboardSetRepeatInfo(wlrKb, 25, 600)

  zdeSignalAdd(addr keyboardEvents(wlrKb).key, addr kb.keyL, onKeyboardKey)
  zdeSignalAdd(addr keyboardEvents(wlrKb).modifiers, addr kb.modifiersL, onKeyboardModifiers)
  zdeSignalAdd(addr inputDeviceEvents(asInputDevice(wlrKb)).destroy, addr kb.destroyL, onKeyboardDestroy)

  wlrSeatSetKeyboard(server.seat, wlrKb)
  server.keyboards.add(kb)

proc onNewInput*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, newInputL)
  let dev = cast[ptr WlrInputDevice](data)
  case dev.`type`
  of WlrInputDeviceKeyboard:
    setupKeyboard(server, dev)
  of WlrInputDevicePointer:
    wlrCursorAttachInputDevice(server.cursor, dev)
  else:
    discard
  wlrSeatSetCapabilities(server.seat, WL_SEAT_CAPABILITY_POINTER or WL_SEAT_CAPABILITY_KEYBOARD)
