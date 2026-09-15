import std/sequtils
import wlroots
import types
import popup

## Rozbudowa v0.1 ("Aurora"/XWayland): te dwie funkcje są punktem, w którym
## reszta kompozytora przestaje musieć wiedzieć, czy dany `Toplevel` to
## okno xdg-shell czy okno X11 (Xwayland) -- patrz duży komentarz przy
## `ToplevelObj` w `types.nim`.
proc surfaceOf*(t: Toplevel): ptr WlrSurface =
  if t.xdgSurface != nil: t.xdgSurface.surface
  elif t.xwaylandSurface != nil: t.xwaylandSurface.surface
  else: nil

proc geometryOf*(t: Toplevel): WlrBox =
  if t.xdgSurface != nil:
    t.xdgSurface.geometry
  elif t.xwaylandSurface != nil:
    WlrBox(x: cint(t.xwaylandSurface.x), y: cint(t.xwaylandSurface.y),
           width: cint(t.xwaylandSurface.width), height: cint(t.xwaylandSurface.height))
  else:
    WlrBox(x: 0, y: 0, width: 0, height: 0)

proc focusToplevel*(t: Toplevel) =
  let server = t.server
  let surface = surfaceOf(t)
  if surface == nil: return
  wlrSceneNodeRaiseToTop(treeNode(t.sceneTree))
  server.toplevels.keepItIf(it != t)
  server.toplevels.add(t)
  if t.xdgSurface != nil:
    if t.xdgSurface.toplevel != nil:
      discard wlrXdgToplevelSetActivated(t.xdgSurface.toplevel, true)
  elif t.xwaylandSurface != nil:
    wlrXwaylandSurfaceActivate(t.xwaylandSurface, true)
  wlrSeatKeyboardNotifyEnter(server.seat, surface, nil, 0, nil)

## Rozbudowa v0.1 ("Aurora"): Alt+Tab -- pełna karuzela z podświetleniem.
##
## `server.toplevels` jest listą w kolejności "ostatnio użyte na końcu" --
## każde `focusToplevel` usuwa dany toplevel z listy i dokleja go na
## koniec (patrz wyżej), więc `toplevels[^1]` to zawsze aktualnie aktywne
## okno. Karuzela NIE zmienia fokusu od razu przy każdym Tab -- zamiast
## tego podświetla KOLEJNEGO kandydata cienką ramką w `overlayTree`
## (najwyższa warstwa sceny, ponad wszystkimi zwykłymi oknami -- ten sam
## mechanizm co wlr-layer-shell "overlay", patrz `types.nim`), a dopiero
## puszczenie Alt (`commitAltTab`, wołane z `onKeyboardModifiers` w
## `wlcomp/input.nim`, gdy bit ALT znika z maski modyfikatorów) faktycznie
## przełącza fokus na to, co było akurat podświetlone. To już NIE jest
## sam toggle do poprzedniego okna (poprzednia wersja tej funkcji) --
## powtarzane Tab przy trzymanym Alt przewija po WSZYSTKICH oknach.
var AltTabColor = [0.373'f32, 0.690'f32, 1.0'f32, 0.28'f32]  ## akcent "Aurora" z shellu (#5fb0ff), nisko nieprzezroczysty -- ma podświetlić, nie zasłonić treść okna
## `var` (nie `const`/`let`) CELOWO -- `const` tej tablicy Nim potrafi w
## pełni "spłaszczyć" (inline poszczególnych elementów jako literały w
## wygenerowanym C), przez co `addr` jednego elementu nie ma do czego się
## odnieść. Nawet moduł-poziomowy `let` bywa tu traktowany podobnie przez
## optymalizator przy `-d:release` -- tylko `var` gwarantuje w Nimie
## prawdziwe, adresowalne miejsce w pamięci przez cały czas życia procesu.
## Nikt tej tablicy nie modyfikuje w praktyce (żyje wyłącznie jako źródło
## `addr` dla `wlr_scene_rect_create`), ale musi być formalnie mutowalna,
## żeby branie jej adresu było w ogóle legalne.

proc hideAltTabHighlight(server: Server) =
  if server.altTabHighlight != nil:
    wlrSceneNodeDestroy(rectNode(server.altTabHighlight))
    server.altTabHighlight = nil

proc showAltTabHighlightAt(server: Server, index: int) =
  let t = server.toplevels[index]
  let box = geometryOf(t)
  ## Ramka -- 4 cienkie prostokąty na obwodzie okna, NIE jeden wypełniony
  ## prostokąt na całym oknie -- ta druga wersja zasłaniałaby treść okna
  ## pod spodem (grubość ramki tak dobrana, żeby było widać, ale
  ## dyskretnie, patrz `BorderPx`).
  hideAltTabHighlight(server)
  ## `wlr_scene_rect_create` woła się raz na CAŁĄ ramkę -- upraszczamy do
  ## JEDNEGO prostokąta obejmującego całe okno (nie 4 osobnych), ale
  ## rysowanego z niską-ale-widoczną nieprzezroczystością tła -- najprostsze
  ## API (`wlr_scene_rect`) nie ma natywnego pojęcia "tylko obrys", więc
  ## prawdziwa 4-częściowa ramka wymagałaby czterech osobnych węzłów sceny
  ## do zarządzania (utworzenie, pozycjonowanie, sprzątanie x4) -- dla
  ## podświetlenia "co jest następne" pojedynczy, półprzezroczysty
  ## prostokąt jest wystarczająco czytelny i dużo prostszy w utrzymaniu.
  server.altTabHighlight = wlrSceneRectCreate(server.overlayTree, cint(box.width), cint(box.height), addr AltTabColor[0])
  wlrSceneRectSetSize(server.altTabHighlight, cint(box.width), cint(box.height))
  wlrSceneNodeSetPosition(rectNode(server.altTabHighlight), box.x, box.y)

proc cycleAltTab*(server: Server, reverse: bool) =
  ## Wołane z `wlcomp/input.nim` przy KAŻDYM Tab wciśniętym z Alt (Shift
  ## dodatkowo = `reverse`). Pierwsze wywołanie w danej "sesji" Alt+Tab
  ## (czyli gdy `not server.altTabActive`) startuje od DRUGIEGO od końca
  ## (poprzednio aktywne okno) -- naturalny punkt startu, tak samo jak
  ## poprzednia (uproszczona) wersja tej funkcji.
  if server.toplevels.len < 2: return
  if not server.altTabActive:
    server.altTabActive = true
    server.altTabIndex = server.toplevels.len - 2
  else:
    let delta = if reverse: -1 else: 1
    server.altTabIndex = ((server.altTabIndex + delta) mod server.toplevels.len + server.toplevels.len) mod server.toplevels.len
  showAltTabHighlightAt(server, server.altTabIndex)

proc commitAltTab*(server: Server) =
  ## Wołane, gdy Alt zostaje puszczony (bit `WlrModifierAlt` znika z
  ## maski modyfikatorów, patrz `onKeyboardModifiers` w `input.nim`) --
  ## zatwierdza wybór z karuzeli, faktycznie przełączając fokus.
  if not server.altTabActive: return
  server.altTabActive = false
  hideAltTabHighlight(server)
  if server.altTabIndex >= 0 and server.altTabIndex < server.toplevels.len:
    focusToplevel(server.toplevels[server.altTabIndex])

proc cycleFocusBy*(server: Server, delta: int) =
  ## Natychmiastowe przełączenie o `delta` miejsc w liście `toplevels`
  ## (MRU -- patrz komentarz przy karuzeli Alt+Tab wyżej), BEZ podglądu i
  ## BEZ czekania na "zatwierdzenie" -- w odróżnieniu od `cycleAltTab`,
  ## używane tam, gdzie sama akcja jest już decyzją (np. gest 3-palcowy w
  ## `wlcomp/gestures.nim`), nie czymś przytrzymywanym jak Alt.
  if server.toplevels.len < 2: return
  let idx = ((server.toplevels.len - 1 + delta) mod server.toplevels.len + server.toplevels.len) mod server.toplevels.len
  focusToplevel(server.toplevels[idx])

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

proc onToplevelNewPopup*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let t = containerOf(listener, Toplevel, ToplevelObj, newPopupL)
  let popup = cast[ptr WlrXdgPopup](data)
  handleNewPopup(t.server, popup.base)

proc onNewXdgSurface*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, newXdgSurfaceL)
  let xdgSurface = cast[ptr WlrXdgSurface](data)

  if xdgSurface.role == WlrXdgSurfaceRolePopup:
    handleNewPopup(server, xdgSurface)
    return
  if xdgSurface.role != WlrXdgSurfaceRoleToplevel:
    return

  let t = Toplevel(server: server, xdgSurface: xdgSurface)
  t.sceneTree = wlrSceneXdgSurfaceCreate(server.toplevelTree, xdgSurface)
  t.sceneTree.node.data = cast[pointer](t)

  zdeSignalAdd(addr surfaceEvents(xdgSurface.surface).map, addr t.mapL, onToplevelMap)
  zdeSignalAdd(addr surfaceEvents(xdgSurface.surface).unmap, addr t.unmapL, onToplevelUnmap)
  zdeSignalAdd(addr xdgSurfaceEvents(xdgSurface).destroy, addr t.destroyL, onToplevelDestroy)
  if xdgSurface.toplevel != nil:
    zdeSignalAdd(addr xdgToplevelEvents(xdgSurface.toplevel).requestMove, addr t.requestMoveL, onToplevelRequestMove)
    zdeSignalAdd(addr xdgToplevelEvents(xdgSurface.toplevel).requestResize, addr t.requestResizeL, onToplevelRequestResize)
  ## NAPRAWIONY BRAK: okna xdg-shell mogą tworzyć popupy (menu, podpowiedzi)
  ## zaczepione o SIEBIE, nie tylko o powierzchnie najwyższego poziomu --
  ## `new_popup` na `xdg_surface` samego toplevelu to sygnał na te
  ## przypadki (patrz popup.nim -- ten sam handler obsługuje oba źródła).
  zdeSignalAdd(addr xdgSurfaceNewPopupEvents(xdgSurface).newPopup, addr t.newPopupL, onToplevelNewPopup)

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
