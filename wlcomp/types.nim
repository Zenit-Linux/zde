import wlroots

const
  SeatName* = "seat0"
  CursorSizePx* = 24'u32
  WL_SEAT_CAPABILITY_POINTER* = 1'u32
  WL_SEAT_CAPABILITY_KEYBOARD* = 2'u32
  WL_KEYBOARD_KEY_STATE_PRESSED* = 1'u32

type
  CursorMode* = enum
    cmPassthrough, cmMove, cmResize

  ServerObj* = object
    display*: ptr WlDisplay
    backend*: ptr WlrBackend
    renderer*: ptr WlrRenderer
    allocator*: ptr WlrAllocator
    compositor*: ptr WlrCompositor
    scene*: ptr WlrScene
    sceneLayout*: ptr WlrSceneOutputLayout
    outputLayout*: ptr WlrOutputLayout
    xdgShell*: ptr WlrXdgShell
    cursor*: ptr WlrCursor
    xcursorMgr*: ptr WlrXcursorManager
    seat*: ptr WlrSeat
    xwayland*: ptr WlrXwayland

    outputs*: seq[Output]
    toplevels*: seq[Toplevel]
    keyboards*: seq[Keyboard]

    cursorMode*: CursorMode
    grabbed*: Toplevel
    grabX*, grabY*: cdouble        ## offset kursora względem lewego-górnego rogu okna w chwili chwycenia
    grabW*, grabH*: cint           ## rozmiar okna w chwili rozpoczęcia resize

    newOutputL*: WlListener
    newXdgSurfaceL*: WlListener
    newInputL*: WlListener
    cursorMotionL*, cursorMotionAbsL*, cursorButtonL*, cursorAxisL*, cursorFrameL*: WlListener

  Server* = ref ServerObj

  OutputObj* = object
    server*: Server
    wlrOutput*: ptr WlrOutput
    sceneOutput*: ptr WlrSceneOutput
    frameL*, destroyL*: WlListener
  Output* = ref OutputObj

  ToplevelObj* = object
    server*: Server
    xdgSurface*: ptr WlrXdgSurface
    sceneTree*: ptr WlrSceneTree
    mapL*, unmapL*, destroyL*: WlListener
    requestMoveL*, requestResizeL*: WlListener
  Toplevel* = ref ToplevelObj

  KeyboardObj* = object
    server*: Server
    wlrKeyboard*: ptr WlrKeyboard
    keyL*, modifiersL*, destroyL*: WlListener
  Keyboard* = ref KeyboardObj

## Odzyskanie obiektu-właściciela z surowego `ptr WlListener`, który dostajemy
## w callbacku z C -- klasyczny "container_of" znany z jądra Linuksa/wlroots,
## tu wyrażony przez Nimowy `offsetof`. Podajemy zarówno typ referencyjny
## (Output), jak i jego "goły" typ obiektowy (OutputObj), bo offsetof
## potrzebuje tego drugiego, a cast -- tego pierwszego.
template containerOf*(listener: ptr WlListener, T, ObjT: typedesc, field: untyped): untyped =
  cast[T](cast[int](listener) - offsetof(ObjT, field))
