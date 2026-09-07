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
    layerShell*: ptr WlrLayerShellV1
    dataDeviceMgr*: ptr WlrDataDeviceManager
    cursor*: ptr WlrCursor
    xcursorMgr*: ptr WlrXcursorManager
    seat*: ptr WlrSeat
    xwayland*: ptr WlrXwayland

    ## Cztery stałe pod-drzewa sceny, utworzone RAZ przy starcie, w tej
    ## kolejności (wlroots domyślnie stackuje węzły w kolejności DODANIA --
    ## później dodany = wyżej -- stąd kolejność poniższych pól ma
    ## bezpośrednie znaczenie dla z-order). Wszystkie toplevele xdg-shell
    ## lądują w `toplevelTree`, więc `wlrSceneNodeRaiseToTop` przy fokusie
    ## okna (patrz toplevel.nim) tasuje je tylko WEWNĄTRZ tego kontenera --
    ## nigdy nie może "uciec" ponad `topTree`/`overlayTree`. To standardowy
    ## wzorzec z kompozytorów opartych o wlroots (sway, dwl) do poprawnego
    ## łączenia wlr-layer-shell ze zwykłymi oknami.
    bgTree*, bottomTree*, toplevelTree*, topTree*, overlayTree*: ptr WlrSceneTree

    outputs*: seq[Output]
    toplevels*: seq[Toplevel]
    layerSurfaces*: seq[LayerSurfaceZde]
    popups*: seq[PopupZde]
    keyboards*: seq[Keyboard]

    cursorMode*: CursorMode
    grabbed*: Toplevel
    grabX*, grabY*: cdouble        ## offset kursora względem lewego-górnego rogu okna w chwili chwycenia
    grabW*, grabH*: cint           ## rozmiar okna w chwili rozpoczęcia resize
    ## Drag & drop: ikona aktualnie przeciąganej "rzeczy" (nil = brak).
    dragIconTree*: ptr WlrSceneTree

    newOutputL*: WlListener
    newXdgSurfaceL*: WlListener
    newLayerSurfaceL*: WlListener
    newInputL*: WlListener
    requestSetSelectionL*: WlListener
    requestStartDragL*: WlListener
    startDragL*: WlListener
    dragIconDestroyL*: WlListener
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
    newPopupL*: WlListener
  Toplevel* = ref ToplevelObj

  ## Nazwa `LayerSurfaceZde` (nie `LayerSurface`) celowo, żeby nie kolidować
  ## z `WlrLayerSurfaceV1` (surowy typ C) w tym samym module przy imporcie
  ## przez `types` -- podobnie `PopupZde` niżej.
  LayerSurfaceZdeObj* = object
    server*: Server
    wlrLayerSurface*: ptr WlrLayerSurfaceV1
    sceneLayerSurface*: ptr WlrSceneLayerSurfaceV1
    mapL*, unmapL*, destroyL*, commitL*: WlListener
    newPopupL*: WlListener
  LayerSurfaceZde* = ref LayerSurfaceZdeObj

  PopupZdeObj* = object
    server*: Server
    xdgSurface*: ptr WlrXdgSurface  ## popup.base
    sceneTree*: ptr WlrSceneTree
    destroyL*: WlListener
  PopupZde* = ref PopupZdeObj

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
