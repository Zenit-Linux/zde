import vmath
import types
import window

proc beginMove*(comp: Compositor, id: int, cursorPos: Vec2) =
  let w = comp.findWindow(id)
  if w.isNil: return
  if w.maximized: return
  comp.focus(id)
  comp.drag = DragState(
    kind: dkMove,
    windowId: id,
    grabOffset: cursorPos - w.pos,
  )

proc beginResize*(comp: Compositor, id: int, cursorPos: Vec2, edge: ResizeEdge) =
  let w = comp.findWindow(id)
  if w.isNil or not w.resizable or w.maximized: return
  comp.focus(id)
  comp.drag = DragState(
    kind: dkResize,
    windowId: id,
    edge: edge,
    grabOffset: cursorPos,
    startPos: w.pos,
    startSize: w.size,
  )

proc isDragging*(comp: Compositor): bool = comp.drag.kind != dkNone

proc updateDrag*(comp: Compositor, cursorPos: Vec2) =
  if comp.drag.kind == dkNone: return
  let w = comp.findWindow(comp.drag.windowId)
  if w.isNil:
    comp.drag = DragState(kind: dkNone)
    return

  case comp.drag.kind
  of dkMove:
    w.pos = cursorPos - comp.drag.grabOffset
    # snapowanie do krawędzi ekranu, tak jak w "prawdziwych" DE
    if abs(w.pos.x) < SnapMargin: w.pos.x = 0
    if abs(w.pos.y) < SnapMargin: w.pos.y = 0
    if abs((w.pos.x + w.size.x) - comp.screenSize.x) < SnapMargin:
      w.pos.x = comp.screenSize.x - w.size.x
    comp.clampToScreen(w)

  of dkResize:
    let delta = cursorPos - comp.drag.grabOffset
    var newPos = comp.drag.startPos
    var newSize = comp.drag.startSize
    template applyRight() = newSize.x = comp.drag.startSize.x + delta.x
    template applyBottom() = newSize.y = comp.drag.startSize.y + delta.y
    template applyLeft() =
      newSize.x = comp.drag.startSize.x - delta.x
      newPos.x = comp.drag.startPos.x + delta.x
    template applyTop() =
      newSize.y = comp.drag.startSize.y - delta.y
      newPos.y = comp.drag.startPos.y + delta.y

    case comp.drag.edge
    of reRight: applyRight()
    of reBottom: applyBottom()
    of reLeft: applyLeft()
    of reTop: applyTop()
    of reBottomRight: applyRight(); applyBottom()
    of reBottomLeft: applyLeft(); applyBottom()
    of reTopRight: applyRight(); applyTop()
    of reTopLeft: applyLeft(); applyTop()
    of reNone: discard

    newSize.x = max(newSize.x, w.minSize.x)
    newSize.y = max(newSize.y, w.minSize.y)
    w.pos = newPos
    w.size = newSize

  of dkNone: discard

proc endDrag*(comp: Compositor) =
  comp.drag = DragState(kind: dkNone)
