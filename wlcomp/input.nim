import std/sequtils
import wlroots
import types
import toplevel

proc processCursorMotion*(server: Server, timeMsec: uint32) =
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
  let server = containerOf(listener, Server, ServerObj, cursorAxisL)
  let event = cast[ptr WlrPointerAxisEvent](data)
  discard event  # TODO: przewijanie (scroll) w aplikacjach -- v2

proc onCursorFrame*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, cursorFrameL)
  wlrSeatPointerNotifyFrame(server.seat)

# ---------------------------------------------------------------------------
# Klawiatura
# ---------------------------------------------------------------------------

proc onKeyboardKey*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let kb = containerOf(listener, Keyboard, KeyboardObj, keyL)
  let event = cast[ptr WlrKeyboardKeyEvent](data)
  wlrSeatKeyboardNotifyKey(kb.server.seat, event.timeMsec, event.keycode, uint32(event.state))

proc onKeyboardModifiers*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let kb = containerOf(listener, Keyboard, KeyboardObj, modifiersL)
  wlrSeatSetKeyboard(kb.server.seat, kb.wlrKeyboard)
  wlrSeatKeyboardNotifyModifiers(kb.server.seat, nil)

proc onKeyboardDestroy*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let kb = containerOf(listener, Keyboard, KeyboardObj, destroyL)
  zdeListRemove(addr kb.keyL.link)
  zdeListRemove(addr kb.modifiersL.link)
  zdeListRemove(addr kb.destroyL.link)
  kb.server.keyboards.keepItIf(it != kb)

proc setupKeyboard*(server: Server, dev: ptr WlrInputDevice) =
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
