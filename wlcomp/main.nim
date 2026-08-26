import std/[os, posix, sequtils]
import wlroots

const
  SeatName = "seat0"
  CursorSizePx = 24'u32
  WL_SEAT_CAPABILITY_POINTER = 1'u32
  WL_SEAT_CAPABILITY_KEYBOARD = 2'u32
  WL_KEYBOARD_KEY_STATE_PRESSED = 1'u32

type
  CursorMode = enum
    cmPassthrough, cmMove, cmResize

  ServerObj = object
    display: ptr WlDisplay
    backend: ptr WlrBackend
    renderer: ptr WlrRenderer
    allocator: ptr WlrAllocator
    compositor: ptr WlrCompositor
    scene: ptr WlrScene
    sceneLayout: ptr WlrSceneOutputLayout
    outputLayout: ptr WlrOutputLayout
    xdgShell: ptr WlrXdgShell
    cursor: ptr WlrCursor
    xcursorMgr: ptr WlrXcursorManager
    seat: ptr WlrSeat
    xwayland: ptr WlrXwayland

    outputs: seq[Output]
    toplevels: seq[Toplevel]
    keyboards: seq[Keyboard]

    cursorMode: CursorMode
    grabbed: Toplevel
    grabX, grabY: cdouble          ## offset kursora względem lewego-górnego rogu okna w chwili chwycenia
    grabW, grabH: cint             ## rozmiar okna w chwili rozpoczęcia resize

    newOutputL: WlListener
    newXdgSurfaceL: WlListener
    newInputL: WlListener
    cursorMotionL, cursorMotionAbsL, cursorButtonL, cursorAxisL, cursorFrameL: WlListener

  Server = ref ServerObj

  OutputObj = object
    server: Server
    wlrOutput: ptr WlrOutput
    sceneOutput: ptr WlrSceneOutput
    frameL, destroyL: WlListener
  Output = ref OutputObj

  ToplevelObj = object
    server: Server
    xdgSurface: ptr WlrXdgSurface
    sceneTree: ptr WlrSceneTree
    mapL, unmapL, destroyL: WlListener
    requestMoveL, requestResizeL: WlListener
  Toplevel = ref ToplevelObj

  KeyboardObj = object
    server: Server
    wlrKeyboard: ptr WlrKeyboard
    keyL, modifiersL, destroyL: WlListener
  Keyboard = ref KeyboardObj

## Odzyskanie obiektu-właściciela z surowego `ptr WlListener`, który dostajemy
## w callbacku z C -- klasyczny "container_of" znany z jądra Linuksa/wlroots,
## tu wyrażony przez Nimowy `offsetof`. Podajemy zarówno typ referencyjny
## (Output), jak i jego "goły" typ obiektowy (OutputObj), bo offsetof
## potrzebuje tego drugiego, a cast -- tego pierwszego.
template containerOf(listener: ptr WlListener, T, ObjT: typedesc, field: untyped): untyped =
  cast[T](cast[int](listener) - offsetof(ObjT, field))

# ---------------------------------------------------------------------------
# Output (monitor)
# ---------------------------------------------------------------------------

proc onOutputFrame(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let output = containerOf(listener, Output, OutputObj, frameL)
  var now: posix.Timespec
  discard clock_gettime(CLOCK_MONOTONIC, now)
  discard wlrSceneOutputCommit(output.sceneOutput)
  wlrSceneOutputSendFrameDone(output.sceneOutput, cast[ptr wlroots.Timespec](addr now))

proc onOutputDestroy(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let output = containerOf(listener, Output, OutputObj, destroyL)
  zdeListRemove(addr output.frameL.link)
  zdeListRemove(addr output.destroyL.link)
  output.server.outputs.keepItIf(it != output)

proc onNewOutput(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, newOutputL)
  let wlrOutput = cast[ptr WlrOutput](data)

  discard wlrOutputInitRender(wlrOutput, server.allocator, server.renderer)

  # Od wlroots 0.18 tryb/enable/commit idą przez wlr_output_state, nie przez
  # osobne wlr_output_set_mode/wlr_output_enable/wlr_output_commit (te
  # zniknęły z nagłówków -- stąd "implicit declaration" na starszym kodzie).
  var state: WlrOutputState
  wlrOutputStateInit(addr state)
  wlrOutputStateSetEnabled(addr state, true)
  let mode = wlrOutputPreferredMode(wlrOutput)
  if mode != nil:
    wlrOutputStateSetMode(addr state, mode)
  let committed = wlrOutputCommitState(wlrOutput, addr state)
  wlrOutputStateFinish(addr state)
  if not committed:
    stderr.writeLine("zde-comp: nie udało się włączyć wyjścia")
    return

  let output = Output(server: server, wlrOutput: wlrOutput)
  zdeSignalAdd(addr outputEvents(wlrOutput).frame, addr output.frameL, onOutputFrame)
  zdeSignalAdd(addr outputEvents(wlrOutput).destroy, addr output.destroyL, onOutputDestroy)
  server.outputs.add(output)

  wlrOutputLayoutAddAuto(server.outputLayout, wlrOutput)
  output.sceneOutput = wlrSceneOutputCreate(server.scene, wlrOutput)
  wlrOutputCreateGlobal(wlrOutput, server.display)  # od 0.18 wymaga jawnego display

# ---------------------------------------------------------------------------
# xdg-shell toplevele
# ---------------------------------------------------------------------------

proc focusToplevel(t: Toplevel) =
  let server = t.server
  let surface = t.xdgSurface.surface
  if surface == nil: return
  wlrSceneNodeRaiseToTop(treeNode(t.sceneTree))
  server.toplevels.keepItIf(it != t)
  server.toplevels.add(t)
  if t.xdgSurface.toplevel != nil:
    discard wlrXdgToplevelSetActivated(t.xdgSurface.toplevel, true)
  wlrSeatKeyboardNotifyEnter(server.seat, surface, nil, 0, nil)

proc onToplevelMap(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let t = containerOf(listener, Toplevel, ToplevelObj, mapL)
  t.server.toplevels.add(t)
  focusToplevel(t)

proc onToplevelUnmap(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let t = containerOf(listener, Toplevel, ToplevelObj, unmapL)
  if t.server.grabbed == t:
    t.server.cursorMode = cmPassthrough
    t.server.grabbed = nil
  t.server.toplevels.keepItIf(it != t)

proc onToplevelDestroy(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let t = containerOf(listener, Toplevel, ToplevelObj, destroyL)
  zdeListRemove(addr t.mapL.link)
  zdeListRemove(addr t.unmapL.link)
  zdeListRemove(addr t.destroyL.link)
  zdeListRemove(addr t.requestMoveL.link)
  zdeListRemove(addr t.requestResizeL.link)

proc onToplevelRequestMove(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let t = containerOf(listener, Toplevel, ToplevelObj, requestMoveL)
  let server = t.server
  server.cursorMode = cmMove
  server.grabbed = t
  # offset kursora względem lewego-górnego rogu okna, żeby nie "skakało"
  discard  # dokładna pozycja liczona w onCursorMotion na bazie server.cursor

proc onToplevelRequestResize(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let t = containerOf(listener, Toplevel, ToplevelObj, requestResizeL)
  let server = t.server
  server.cursorMode = cmResize
  server.grabbed = t

proc onNewXdgSurface(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, newXdgSurfaceL)
  let xdgSurface = cast[ptr WlrXdgSurface](data)
  if xdgSurface.role != WlrXdgSurfaceRoleToplevel:
    return  # popupy pomijamy w v1 (patrz komentarz na górze pliku)

  let t = Toplevel(server: server, xdgSurface: xdgSurface)
  t.sceneTree = wlrSceneXdgSurfaceCreate(cast[ptr WlrSceneTree](server.scene), xdgSurface)
  t.sceneTree.node.data = cast[pointer](t)

  zdeSignalAdd(addr surfaceEvents(xdgSurface.surface).map, addr t.mapL, onToplevelMap)
  zdeSignalAdd(addr surfaceEvents(xdgSurface.surface).unmap, addr t.unmapL, onToplevelUnmap)
  zdeSignalAdd(addr xdgSurfaceEvents(xdgSurface).destroy, addr t.destroyL, onToplevelDestroy)
  if xdgSurface.toplevel != nil:
    zdeSignalAdd(addr xdgToplevelEvents(xdgSurface.toplevel).requestMove, addr t.requestMoveL, onToplevelRequestMove)
    zdeSignalAdd(addr xdgToplevelEvents(xdgSurface.toplevel).requestResize, addr t.requestResizeL, onToplevelRequestResize)

# ---------------------------------------------------------------------------
# Kursor / wskaźnik
# ---------------------------------------------------------------------------

proc toplevelAt(server: Server, lx, ly: cdouble): Toplevel =
  ## Trafienie w scenie (np. bufor konkretnej powierzchni) nie ma samo w sobie
  ## `data` ustawionego -- to pole ustawiliśmy tylko na korzeniu drzewa danego
  ## toplevelu (w onNewXdgSurface). Idziemy więc w górę przez `parent`, aż
  ## znajdziemy węzeł, który go ma (albo dojdziemy do korzenia sceny).
  var sx, sy: cdouble
  var node = wlrSceneNodeAt(sceneRootNode(server.scene), lx, ly, addr sx, addr sy)
  while node != nil:
    if node.data != nil:
      return cast[Toplevel](node.data)
    if node.parent == nil: break
    node = treeNode(node.parent)
  return nil

proc processCursorMotion(server: Server, timeMsec: uint32) =
  case server.cursorMode
  of cmMove:
    if server.grabbed != nil:
      let node = treeNode(server.grabbed.sceneTree)
      wlrSceneNodeSetPosition(node, cint(server.cursor.x), cint(server.cursor.y))
    return
  of cmResize:
    if server.grabbed != nil and server.grabbed.xdgSurface.toplevel != nil:
      # Od wlroots 0.18 `geometry` jest zwykłym polem WlrXdgSurface, nie
      # wynikiem wywołania wlr_xdg_surface_get_geometry() (usuniętego).
      let box = server.grabbed.xdgSurface.geometry
      let newW = max(cint(1), cint(server.cursor.x) - box.x)
      let newH = max(cint(1), cint(server.cursor.y) - box.y)
      discard wlrXdgToplevelSetSize(server.grabbed.xdgSurface.toplevel, newW, newH)
    return
  of cmPassthrough:
    discard

  let t = toplevelAt(server, server.cursor.x, server.cursor.y)
  if t != nil and t.xdgSurface.surface != nil:
    wlrSeatPointerNotifyEnter(server.seat, t.xdgSurface.surface, 0, 0)
    wlrSeatPointerNotifyMotion(server.seat, timeMsec, 0, 0)
  else:
    wlrCursorSetXcursor(server.cursor, server.xcursorMgr, "default")
    wlrSeatPointerNotifyClearFocus(server.seat)

proc onCursorMotion(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, cursorMotionL)
  let event = cast[ptr WlrPointerMotionEvent](data)
  wlrCursorMove(server.cursor, nil, event.deltaX, event.deltaY)
  processCursorMotion(server, event.timeMsec)

proc onCursorMotionAbsolute(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, cursorMotionAbsL)
  # (uproszczenie v1: traktujemy jak względny ruch do centrum; pełna obsługa
  # bezwzględnych współrzędnych -- np. tabletów graficznych -- to TODO)
  processCursorMotion(server, 0)

proc onCursorButton(listener: ptr WlListener, data: pointer) {.cdecl.} =
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

proc onCursorAxis(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, cursorAxisL)
  let event = cast[ptr WlrPointerAxisEvent](data)
  discard event  # TODO: przewijanie (scroll) w aplikacjach -- v2

proc onCursorFrame(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, cursorFrameL)
  wlrSeatPointerNotifyFrame(server.seat)

# ---------------------------------------------------------------------------
# Klawiatura
# ---------------------------------------------------------------------------

proc onKeyboardKey(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let kb = containerOf(listener, Keyboard, KeyboardObj, keyL)
  let event = cast[ptr WlrKeyboardKeyEvent](data)
  wlrSeatKeyboardNotifyKey(kb.server.seat, event.timeMsec, event.keycode, uint32(event.state))

proc onKeyboardModifiers(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let kb = containerOf(listener, Keyboard, KeyboardObj, modifiersL)
  wlrSeatSetKeyboard(kb.server.seat, kb.wlrKeyboard)
  wlrSeatKeyboardNotifyModifiers(kb.server.seat, nil)

proc onKeyboardDestroy(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let kb = containerOf(listener, Keyboard, KeyboardObj, destroyL)
  zdeListRemove(addr kb.keyL.link)
  zdeListRemove(addr kb.modifiersL.link)
  zdeListRemove(addr kb.destroyL.link)
  kb.server.keyboards.keepItIf(it != kb)

proc setupKeyboard(server: Server, dev: ptr WlrInputDevice) =
  let wlrKb = wlrKeyboardFromInputDevice(dev)
  let kb = Keyboard(server: server, wlrKeyboard: wlrKb)

  let ctx = xkbContextNew(0)
  var names: XkbRuleNames
  names.layout = "us"
  let keymap = xkbKeymapNewFromNames(ctx, addr names, 0)
  discard wlrKeyboardSetKeymap(wlrKb, keymap)
  wlrKeyboardSetRepeatInfo(wlrKb, 25, 600)

  zdeSignalAdd(addr keyboardEvents(wlrKb).key, addr kb.keyL, onKeyboardKey)
  zdeSignalAdd(addr keyboardEvents(wlrKb).modifiers, addr kb.modifiersL, onKeyboardModifiers)
  zdeSignalAdd(addr inputDeviceEvents(asInputDevice(wlrKb)).destroy, addr kb.destroyL, onKeyboardDestroy)

  wlrSeatSetKeyboard(server.seat, wlrKb)
  server.keyboards.add(kb)

proc onNewInput(listener: ptr WlListener, data: pointer) {.cdecl.} =
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

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

proc main() =
  let server = Server()
  server.display = wlDisplayCreate()
  # Od wlroots 0.18 wlr_backend_autocreate() bierze wl_event_loop, nie
  # wl_display bezpośrednio.
  let eventLoop = wlDisplayGetEventLoop(server.display)
  server.backend = wlrBackendAutocreate(eventLoop)
  if server.backend == nil:
    quit("zde-comp: wlr_backend_autocreate() nie powiodło się")

  server.renderer = wlrRendererAutocreate(server.backend)
  discard wlrRendererInitWlDisplay(server.renderer, server.display)
  server.allocator = wlrAllocatorAutocreate(server.backend, server.renderer)

  zdeDisplayInitShm(server.display)
  server.compositor = wlrCompositorCreate(server.display, 5, server.renderer)
  discard wlrSubcompositorCreate(server.display)
  discard wlrDataDeviceManagerCreate(server.display)

  server.outputLayout = wlrOutputLayoutCreate(server.display)
  server.scene = wlrSceneCreate()
  server.sceneLayout = wlrSceneAttachOutputLayout(server.scene, server.outputLayout)

  server.xdgShell = wlrXdgShellCreate(server.display, 3)
  zdeSignalAdd(addr xdgShellEvents(server.xdgShell).newSurface, addr server.newXdgSurfaceL, onNewXdgSurface)

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

  zdeSignalAdd(addr backendEvents(server.backend).newOutput, addr server.newOutputL, onNewOutput)
  zdeSignalAdd(addr backendEvents(server.backend).newInput, addr server.newInputL, onNewInput)

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
  wlDisplayRun(server.display)

  wlDisplayDestroyClients(server.display)
  if server.xwayland != nil:
    wlrXwaylandDestroy(server.xwayland)
  wlDisplayDestroy(server.display)

when isMainModule:
  main()
