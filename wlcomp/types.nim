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
    ## Rozbudowa v0.1 ("Aurora"/DRM) -- `nil`, gdy `zde-comp` działa
    ## zagnieżdżone pod X11/Wayland (nie ma czego przełączać); realny
    ## uchwyt sesji logind/seatd, gdy działa na prawdziwym DRM/TTY. Patrz
    ## `wlcomp/session.nim`.
    session*: ptr WlrSession
    sessionActiveL*: WlListener
    ## Rozbudowa v0.1 ("Aurora"/DPMS) -- patrz `wlcomp/idle.nim`.
    idleNotifier*: ptr WlrIdleNotifierV1
    lastInputActivity*: float   ## epochTime() ostatniego ruchu myszy/klawisza
    outputsBlanked*: bool       ## czy wyjścia są aktualnie wygaszone (DPMS off)
    dpmsTimerSource*: ptr WlEventSource
    ## Rozbudowa v0.1 ("Aurora"): karuzela Alt+Tab -- patrz `cycleAltTab`/
    ## `commitAltTab` w `wlcomp/toplevel.nim`.
    altTabActive*: bool
    altTabIndex*: int              ## indeks w `toplevels` aktualnie podświetlonego okna
    altTabHighlight*: ptr WlrSceneRect  ## ramka podświetlenia w `overlayTree`, nil gdy nieaktywna
    ## Rozbudowa v0.1 ("Aurora"/gesty) -- patrz `wlcomp/gestures.nim`.
    pointerGestures*: ptr WlrPointerGesturesV1
    swipeBeginL*, swipeUpdateL*, swipeEndL*: WlListener
    gestureFingers*: uint32     ## liczba palców bieżącego gestu (0 = żaden aktywny)
    gestureAccumDx*: float      ## suma przesunięcia w poziomie od swipe_begin
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
    ## Rozbudowa v0.1 ("Aurora"/XWayland) -- patrz `wlcomp/xwayland.nim`.
    newXwaylandSurfaceL*: WlListener
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
    ## Dokładnie JEDNO z poniższych dwóch jest nie-`nil` dla danego
    ## `Toplevel` -- `xdgSurface` dla zwykłych okien Wayland (xdg-shell),
    ## `xwaylandSurface` dla okien X11 uruchomionych przez Xwayland
    ## (rozbudowa v0.1, patrz `wlcomp/xwayland.nim`). Zamiast osobnego typu
    ## `XwaylandToplevel` cała reszta kompozytora (hit-testing w
    ## `toplevelAt`, fokus, przeciąganie/resize w `input.nim`) korzysta z
    ## JEDNEGO uogólnionego typu przez `surfaceOf`/`geometryOf`
    ## (`toplevel.nim`) -- dzięki temu okno X11 "po prostu działa" wszędzie
    ## tam, gdzie do tej pory działały tylko okna xdg-shell, bez
    ## duplikowania całej logiki fokusu/przeciągania/hit-testu.
    xdgSurface*: ptr WlrXdgSurface
    xwaylandSurface*: ptr WlrXwaylandSurface
    sceneTree*: ptr WlrSceneTree
    mapL*, unmapL*, destroyL*: WlListener
    requestMoveL*, requestResizeL*: WlListener
    newPopupL*: WlListener
    ## Tylko dla `xwaylandSurface != nil` -- patrz komentarz przy typie
    ## `WlrXwaylandSurface` w `wlroots.nim` o tym, dlaczego X11 potrzebuje
    ## dodatkowych `associate`/`dissociate` obok zwykłego `map`/`unmap`.
    associateL*, dissociateL*, requestConfigureL*: WlListener
    ## `true` dokładnie wtedy, gdy `mapL`/`unmapL` są AKTUALNIE podłączone
    ## (między `associate` a `dissociate`/`destroy`) -- w odróżnieniu od
    ## xdg-shell, gdzie te dwa listenery są podłączane RAZ i zawsze
    ## bezpiecznie odpinalne, dla X11 mogą nigdy nie zostać podłączone
    ## (okno zniszczone zanim serwer X zdążył je skojarzyć z powierzchnią)
    ## -- bez tej flagi `onXwaylandSurfaceDestroy` mogłoby wywołać
    ## `wl_list_remove` na nigdy-niezainicjalizowanym listenerze (realny
    ## crash, patrz komentarz w `wlcomp/xwayland.nim`).
    xwaylandAssociated*: bool
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
