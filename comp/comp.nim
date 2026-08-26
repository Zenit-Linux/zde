import std/[algorithm, sequtils]
import vmath

type
  WindowKind* = enum
    wkTerminal
    wkFileManager
    wkAbout
    wkGeneric

  ResizeEdge* = enum
    reNone
    reLeft, reRight, reTop, reBottom
    reTopLeft, reTopRight, reBottomLeft, reBottomRight

  DrawBodyProc* = proc(win: ZdeWindow) {.closure.}

  ZdeWindow* = ref object
    id*: int
    title*: string
    kind*: WindowKind
    pos*: Vec2
    size*: Vec2
    minSize*: Vec2
    savedPos*: Vec2       ## pozycja sprzed maximize, do przywrócenia
    savedSize*: Vec2      ## rozmiar sprzed maximize
    zIndex*: int
    minimized*: bool
    maximized*: bool
    closable*: bool
    resizable*: bool
    drawBody*: DrawBodyProc
    onClose*: proc(win: ZdeWindow) {.closure.}
    userData*: RootRef     ## uchwyt na stan konkretnej appki (TerminalState, FilesState, ...)

  DragKind = enum
    dkNone, dkMove, dkResize

  DragState = object
    kind: DragKind
    windowId: int
    edge: ResizeEdge
    grabOffset: Vec2       ## offset kursora względem lewego-górnego rogu okna
    startPos: Vec2
    startSize: Vec2

  Compositor* = ref object
    windows*: seq[ZdeWindow]
    nextId: int
    focusedId*: int
    screenSize*: Vec2
    drag: DragState
    launcherOpen*: bool

const
  DefaultMinSize* = vec2(280, 180)
  TaskbarHeight* = 40.0'f32
  SnapMargin = 12.0'f32

proc newCompositor*(screenSize: Vec2): Compositor =
  result = Compositor(
    windows: @[],
    nextId: 1,
    focusedId: 0,
    screenSize: screenSize,
    launcherOpen: false,
  )

proc findWindow*(comp: Compositor, id: int): ZdeWindow =
  for w in comp.windows:
    if w.id == id:
      return w
  return nil

proc focusedWindow*(comp: Compositor): ZdeWindow =
  comp.findWindow(comp.focusedId)

proc topZ(comp: Compositor): int =
  result = 0
  for w in comp.windows:
    if w.zIndex > result:
      result = w.zIndex

proc focus*(comp: Compositor, id: int) =
  let w = comp.findWindow(id)
  if w.isNil: return
  w.minimized = false
  w.zIndex = comp.topZ() + 1
  comp.focusedId = id

proc clampToScreen(comp: Compositor, win: ZdeWindow) =
  ## Nie pozwala oknu całkowicie "uciec" poza ekran -- pasek tytułu musi
  ## zawsze zostać choć trochę widoczny i klikalny.
  let minVisible = 60.0'f32
  win.pos.x = clamp(win.pos.x, minVisible - win.size.x, comp.screenSize.x - minVisible)
  win.pos.y = clamp(win.pos.y, 0.0'f32, comp.screenSize.y - TaskbarHeight - minVisible)

proc openWindow*(
  comp: Compositor,
  title: string,
  kind: WindowKind,
  size: Vec2 = vec2(640, 420),
  drawBody: DrawBodyProc = nil,
  minSize: Vec2 = DefaultMinSize,
  closable = true,
  resizable = true,
): ZdeWindow =
  ## Otwiera nowe okno, kaskadując pozycję startową, żeby kolejne okna nie
  ## nakładały się idealnie jedno na drugim.
  let id = comp.nextId
  inc comp.nextId

  let openCount = comp.windows.len
  let cascade = vec2(float32(openCount mod 8) * 28.0'f32, float32(openCount mod 8) * 28.0'f32)
  var pos = vec2(
    (comp.screenSize.x - size.x) / 2.0'f32 + cascade.x - 100.0'f32,
    (comp.screenSize.y - TaskbarHeight - size.y) / 2.0'f32 + cascade.y - 60.0'f32,
  )
  pos.x = max(pos.x, 20.0'f32)
  pos.y = max(pos.y, 20.0'f32)

  result = ZdeWindow(
    id: id,
    title: title,
    kind: kind,
    pos: pos,
    size: size,
    minSize: minSize,
    savedPos: pos,
    savedSize: size,
    zIndex: comp.topZ() + 1,
    minimized: false,
    maximized: false,
    closable: closable,
    resizable: resizable,
    drawBody: drawBody,
  )
  comp.windows.add(result)
  comp.focusedId = id

proc closeWindow*(comp: Compositor, id: int) =
  let w = comp.findWindow(id)
  if w.isNil: return
  if not w.onClose.isNil:
    w.onClose(w)
  comp.windows.keepItIf(it.id != id)
  if comp.focusedId == id:
    comp.focusedId = 0
    # oddaj focus najwyżej ułożonemu z pozostałych okien
    var best: ZdeWindow = nil
    for win in comp.windows:
      if win.minimized: continue
      if best.isNil or win.zIndex > best.zIndex:
        best = win
    if not best.isNil:
      comp.focusedId = best.id

proc minimizeWindow*(comp: Compositor, id: int) =
  let w = comp.findWindow(id)
  if w.isNil: return
  w.minimized = true
  if comp.focusedId == id:
    comp.focusedId = 0

proc restoreWindow*(comp: Compositor, id: int) =
  comp.focus(id)  # focus() już czyści `minimized`

proc toggleMaximize*(comp: Compositor, id: int) =
  let w = comp.findWindow(id)
  if w.isNil or not w.resizable: return
  if w.maximized:
    w.pos = w.savedPos
    w.size = w.savedSize
    w.maximized = false
  else:
    w.savedPos = w.pos
    w.savedSize = w.size
    w.pos = vec2(0, 0)
    w.size = vec2(comp.screenSize.x, comp.screenSize.y - TaskbarHeight)
    w.maximized = true
  comp.focus(id)

proc cycleFocus*(comp: Compositor) =
  ## Alt+Tab: przełącza focus na kolejne okno w kolejności z-order.
  var visible = comp.windows.filterIt(not it.minimized)
  if visible.len == 0: return
  visible.sort(proc(a, b: ZdeWindow): int = cmp(a.zIndex, b.zIndex))
  var idx = -1
  for i, w in visible:
    if w.id == comp.focusedId:
      idx = i
      break
  let nextIdx = (idx + 1) mod visible.len  # (idx=-1) -> 0, czyli najstarsze okno
  comp.focus(visible[nextIdx].id)

proc windowsInZOrder*(comp: Compositor): seq[ZdeWindow] =
  ## Zwraca widoczne okna posortowane rosnąco po z-index (rysować w tej
  ## kolejności, żeby ostatnie -- najwyżej ułożone -- trafiło na wierzch).
  result = comp.windows.filterIt(not it.minimized)
  result.sort(proc(a, b: ZdeWindow): int = cmp(a.zIndex, b.zIndex))

# --- Przeciąganie / zmiana rozmiaru --------------------------------------

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

proc setScreenSize*(comp: Compositor, size: Vec2) =
  comp.screenSize = size
  for w in comp.windows:
    if w.maximized:
      w.size = vec2(size.x, size.y - TaskbarHeight)
    comp.clampToScreen(w)

proc hitTestEdge*(win: ZdeWindow, cursorPos: Vec2, border = 6.0'f32): ResizeEdge =
  ## Sprawdza, czy kursor jest nad krawędzią/rogiem okna (do zmiany rozmiaru).
  let local = cursorPos - win.pos
  let onLeft = local.x >= -border and local.x <= border
  let onRight = local.x >= win.size.x - border and local.x <= win.size.x + border
  let onTop = local.y >= -border and local.y <= border
  let onBottom = local.y >= win.size.y - border and local.y <= win.size.y + border

  if onTop and onLeft: return reTopLeft
  if onTop and onRight: return reTopRight
  if onBottom and onLeft: return reBottomLeft
  if onBottom and onRight: return reBottomRight
  if onLeft: return reLeft
  if onRight: return reRight
  if onTop: return reTop
  if onBottom: return reBottom
  return reNone
