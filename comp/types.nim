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

  DragKind* = enum
    dkNone, dkMove, dkResize

  DragState* = object
    kind*: DragKind
    windowId*: int
    edge*: ResizeEdge
    grabOffset*: Vec2       ## offset kursora względem lewego-górnego rogu okna
    startPos*: Vec2
    startSize*: Vec2

  Compositor* = ref object
    windows*: seq[ZdeWindow]
    nextId*: int
    focusedId*: int
    screenSize*: Vec2
    drag*: DragState
    launcherOpen*: bool

const
  DefaultMinSize* = vec2(280, 180)
  TaskbarHeight* = 40.0'f32
  SnapMargin* = 12.0'f32
