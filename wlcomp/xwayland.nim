import std/sequtils
import wlroots
import types
import toplevel

## Rozbudowa v0.1 ("Aurora"/XWayland) -- patrz obszerny komentarz nad
## definicją `WlrXwayland`/`WlrXwaylandSurface` w `wlroots.nim` (w tym
## zastrzeżenie o braku możliwości skompilowania tego w tej piaskownicy).
##
## Cykl życia okna X11 różni się od xdg-shell w jednym istotnym punkcie:
## `wlr_xwayland_surface` powstaje (`new_surface`) ZANIM ma faktyczną
## `wlr_surface` do narysowania -- serwer X kojarzy je dopiero po chwili
## (`associate`). Dopiero wtedy mamy czego dotknąć w scenie, i dopiero
## wtedy dana `surface` może się "zmapować" (`map`/`unmap`, dokładnie jak
## dla xdg-shell -- stąd `onToplevelMap`/`onToplevelUnmap` z `toplevel.nim`
## są w 100% reużywalne, patrz `onXwaylandAssociate` niżej).

proc onXwaylandSurfaceDestroy*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  ## Odpowiednik `onToplevelDestroy`, ale dla okien X11 -- CELOWO osobna
  ## funkcja, nie reużycie `onToplevelDestroy`: ta druga bezwarunkowo
  ## odpina `newPopupL`, którego dla okien X11 nigdy nie podłączamy
  ## (X11/Xwayland nie ma odpowiednika xdg-popup -- menu w aplikacjach X11
  ## to zwykłe, osobne override-redirect okna X11, obsłużone przez ten sam
  ## `onNewXwaylandSurface` co zwykłe okna). Odpięcie nigdy niepodłączonego
  ## listenera (`wl_list` o zerowych prev/next, bo Nim zeruje pamięć nowego
  ## `ref object` przy alokacji) byłoby użyciem null-pointera w
  ## `wl_list_remove` -- realny crash, nie tylko teoretyczne ryzyko.
  let t = containerOf(listener, Toplevel, ToplevelObj, destroyL)
  zdeListRemove(addr t.destroyL.link)
  zdeListRemove(addr t.requestMoveL.link)
  zdeListRemove(addr t.requestResizeL.link)
  zdeListRemove(addr t.requestConfigureL.link)
  zdeListRemove(addr t.associateL.link)
  zdeListRemove(addr t.dissociateL.link)
  ## `mapL`/`unmapL` są podłączane/odpinane dynamicznie w
  ## `onXwaylandAssociate`/`onXwaylandDissociate` (poniżej) i mogą nigdy
  ## nie zostać podłączone (okno zniszczone zanim serwer X zdążył je
  ## skojarzyć z powierzchnią) -- `xwaylandAssociated` mówi, czy w tej
  ## chwili SĄ podłączone, więc czy w ogóle wolno je odpinać (patrz
  ## komentarz przy tym polu w `types.nim`).
  if t.xwaylandAssociated:
    zdeListRemove(addr t.mapL.link)
    zdeListRemove(addr t.unmapL.link)
    t.xwaylandAssociated = false

proc onXwaylandRequestMove*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let t = containerOf(listener, Toplevel, ToplevelObj, requestMoveL)
  t.server.cursorMode = cmMove
  t.server.grabbed = t

proc onXwaylandRequestResize*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let t = containerOf(listener, Toplevel, ToplevelObj, requestResizeL)
  t.server.cursorMode = cmResize
  t.server.grabbed = t

proc onXwaylandRequestConfigure*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  ## Klient X11 sam prosi o konkretną geometrię (typowe dla okien
  ## dialogowych, które chcą się wyśrodkować względem rodzica, albo gier
  ## ustawiających swoją rozdzielczość) -- w większości honorujemy to
  ## wprost, tak jak robi to większość minimalnych kompozytorów wlroots
  ## (np. tinywl). JEDYNY wyjątek (rozbudowa v0.1): klamrujemy żądaną
  ## pozycję/rozmiar do granic całego układu monitorów (`wlrOutputLayoutGetBox`
  ## z `reference: nil` -- suma wszystkich wyjść), żeby okno nie mogło
  ## poprosić o umieszczenie się całkowicie poza widocznym ekranem (co
  ## zdarza się realnie -- np. starsze aplikacje pamiętające pozycję
  ## sprzed zmiany rozdzielczości/odłączenia monitora). Rozmiar NIE jest
  ## przycinany w dół poza to, co trzeba, żeby zmieścić się w layoucie --
  ## to polityka pozycji, nie wymuszanie konkretnych rozmiarów okien.
  let t = containerOf(listener, Toplevel, ToplevelObj, requestConfigureL)
  let ev = cast[ptr WlrXwaylandConfigureEvent](data)

  var layoutBox: WlrBox
  wlrOutputLayoutGetBox(t.server.outputLayout, nil, addr layoutBox)

  var x = ev.x
  var y = ev.y
  let width = ev.width
  let height = ev.height

  if layoutBox.width > 0 and layoutBox.height > 0:
    let maxX = layoutBox.x + layoutBox.width - cint(width)
    let maxY = layoutBox.y + layoutBox.height - cint(height)
    ## `clamp` z `std/math`/`system` oczekuje `lo <= hi` -- gdy okno jest
    ## szersze/wyższe niż cały layout (maxX < layoutBox.x), zamiast
    ## crashować na złym zakresie, po prostu przyklejamy do lewej/góry.
    x = if maxX >= layoutBox.x: int16(max(int(layoutBox.x), min(int(x), int(maxX))))
        else: int16(layoutBox.x)
    y = if maxY >= layoutBox.y: int16(max(int(layoutBox.y), min(int(y), int(maxY))))
        else: int16(layoutBox.y)

  wlrXwaylandSurfaceConfigure(t.xwaylandSurface, x, y, width, height)

proc onXwaylandDissociate*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  ## `surface` przestaje być ważna (ale `wlr_xwayland_surface` sam może
  ## jeszcze przeżyć, np. przy przełączeniu roli) -- odpinamy map/unmap
  ## podłączone w `onXwaylandAssociate` i sprzątamy węzeł sceny, żeby nie
  ## renderować martwej powierzchni.
  let t = containerOf(listener, Toplevel, ToplevelObj, dissociateL)
  if t.xwaylandAssociated:
    zdeListRemove(addr t.mapL.link)
    zdeListRemove(addr t.unmapL.link)
    t.xwaylandAssociated = false
  if t.server.grabbed == t:
    t.server.cursorMode = cmPassthrough
    t.server.grabbed = nil
  t.server.toplevels.keepItIf(it != t)
  if t.sceneTree != nil:
    wlrSceneNodeDestroy(treeNode(t.sceneTree))
    t.sceneTree = nil

proc onXwaylandAssociate*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  ## Dopiero teraz `t.xwaylandSurface.surface` jest ważna -- tworzymy
  ## węzeł sceny i podpinamy się pod TE SAME `onToplevelMap`/
  ## `onToplevelUnmap` z `toplevel.nim`, których używa xdg-shell (są w
  ## 100% generyczne -- patrz ich treść: tylko `t.server.toplevels` i
  ## `focusToplevel(t)`/`cursorMode`, zero odwołań do `xdgSurface`).
  let t = containerOf(listener, Toplevel, ToplevelObj, associateL)
  let surface = t.xwaylandSurface.surface
  if surface == nil: return
  t.sceneTree = wlrSceneSubsurfaceTreeCreate(t.server.toplevelTree, surface)
  t.sceneTree.node.data = cast[pointer](t)
  zdeSignalAdd(addr surfaceEvents(surface).map, addr t.mapL, onToplevelMap)
  zdeSignalAdd(addr surfaceEvents(surface).unmap, addr t.unmapL, onToplevelUnmap)
  t.xwaylandAssociated = true
  stderr.writeLine("zde-comp: okno X11 skojarzone z powierzchnia (associate) -- tytul: " &
    (if t.xwaylandSurface.title != nil: $t.xwaylandSurface.title else: "(bez tytulu)"))

proc onNewXwaylandSurface*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, newXwaylandSurfaceL)
  let xwaylandSurface = cast[ptr WlrXwaylandSurface](data)
  stderr.writeLine("zde-comp: nowe okno X11 (Xwayland) -- czekam na associate")

  let t = Toplevel(server: server, xwaylandSurface: xwaylandSurface)
  ## `sceneTree` zostaje `nil` aż do `associate` (patrz wyżej) -- w
  ## odróżnieniu od xdg-shell, gdzie scena powstaje natychmiast w
  ## `onNewXdgSurface`, bo tam `.surface` jest ważna od razu.

  zdeSignalAdd(addr xwaylandSurfaceEvents(xwaylandSurface).destroy, addr t.destroyL, onXwaylandSurfaceDestroy)
  zdeSignalAdd(addr xwaylandSurfaceEvents(xwaylandSurface).requestMove, addr t.requestMoveL, onXwaylandRequestMove)
  zdeSignalAdd(addr xwaylandSurfaceEvents(xwaylandSurface).requestResize, addr t.requestResizeL, onXwaylandRequestResize)
  zdeSignalAdd(addr xwaylandSurfaceEvents(xwaylandSurface).requestConfigure, addr t.requestConfigureL, onXwaylandRequestConfigure)
  zdeSignalAdd(addr xwaylandSurfaceEvents(xwaylandSurface).associate, addr t.associateL, onXwaylandAssociate)
  zdeSignalAdd(addr xwaylandSurfaceEvents(xwaylandSurface).dissociate, addr t.dissociateL, onXwaylandDissociate)
