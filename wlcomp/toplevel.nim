import std/sequtils
import wlroots
import types

proc focusToplevel*(t: Toplevel) =
  let server = t.server
  let surface = t.xdgSurface.surface
  if surface == nil: return
  wlrSceneNodeRaiseToTop(treeNode(t.sceneTree))
  server.toplevels.keepItIf(it != t)
  server.toplevels.add(t)
  if t.xdgSurface.toplevel != nil:
    discard wlrXdgToplevelSetActivated(t.xdgSurface.toplevel, true)
  wlrSeatKeyboardNotifyEnter(server.seat, surface, nil, 0, nil)

proc onToplevelMap*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let t = containerOf(listener, Toplevel, ToplevelObj, mapL)
  t.server.toplevels.add(t)
  focusToplevel(t)

proc onToplevelUnmap*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let t = containerOf(listener, Toplevel, ToplevelObj, unmapL)
  if t.server.grabbed == t:
    t.server.cursorMode = cmPassthrough
    t.server.grabbed = nil
  t.server.toplevels.keepItIf(it != t)

proc onToplevelDestroy*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let t = containerOf(listener, Toplevel, ToplevelObj, destroyL)
  zdeListRemove(addr t.mapL.link)
  zdeListRemove(addr t.unmapL.link)
  zdeListRemove(addr t.destroyL.link)
  zdeListRemove(addr t.requestMoveL.link)
  zdeListRemove(addr t.requestResizeL.link)

proc onToplevelRequestMove*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let t = containerOf(listener, Toplevel, ToplevelObj, requestMoveL)
  let server = t.server
  server.cursorMode = cmMove
  server.grabbed = t
  # offset kursora względem lewego-górnego rogu okna, żeby nie "skakało"
  discard  # dokładna pozycja liczona w onCursorMotion na bazie server.cursor

proc onToplevelRequestResize*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let t = containerOf(listener, Toplevel, ToplevelObj, requestResizeL)
  let server = t.server
  server.cursorMode = cmResize
  server.grabbed = t

proc onNewXdgSurface*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, newXdgSurfaceL)
  let xdgSurface = cast[ptr WlrXdgSurface](data)
  if xdgSurface.role != WlrXdgSurfaceRoleToplevel:
    return  # popupy pomijamy w v1 (patrz komentarz o zakresie w main.nim)

  let t = Toplevel(server: server, xdgSurface: xdgSurface)
  t.sceneTree = wlrSceneXdgSurfaceCreate(cast[ptr WlrSceneTree](server.scene), xdgSurface)
  t.sceneTree.node.data = cast[pointer](t)

  zdeSignalAdd(addr surfaceEvents(xdgSurface.surface).map, addr t.mapL, onToplevelMap)
  zdeSignalAdd(addr surfaceEvents(xdgSurface.surface).unmap, addr t.unmapL, onToplevelUnmap)
  zdeSignalAdd(addr xdgSurfaceEvents(xdgSurface).destroy, addr t.destroyL, onToplevelDestroy)
  if xdgSurface.toplevel != nil:
    zdeSignalAdd(addr xdgToplevelEvents(xdgSurface.toplevel).requestMove, addr t.requestMoveL, onToplevelRequestMove)
    zdeSignalAdd(addr xdgToplevelEvents(xdgSurface.toplevel).requestResize, addr t.requestResizeL, onToplevelRequestResize)

proc toplevelAt*(server: Server, lx, ly: cdouble): Toplevel =
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
