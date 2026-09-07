import std/sequtils
import wlroots
import types

proc treeForLayer(server: Server, layer: cint): ptr WlrSceneTree =
  case layer
  of ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND: server.bgTree
  of ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM: server.bottomTree
  of ZWLR_LAYER_SHELL_V1_LAYER_TOP: server.topTree
  of ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY: server.overlayTree
  else: server.topTree

proc arrange(ls: LayerSurfaceZde) =
  ## Przelicza rozmiar/pozycję na podstawie kotwic + `desired_width/height`
  ## + `exclusive_zone`, i wysyła `configure` do klienta. Wołane przy
  ## pierwszym mapowaniu i za każdym razem, gdy klient zmieni swój stan
  ## (commit z nowym `pending`).
  let wlrLs = ls.wlrLayerSurface
  if wlrLs.output == nil: return
  var outputW, outputH: cint
  wlrOutputEffectiveResolution(wlrLs.output, addr outputW, addr outputH)
  var fullArea = WlrBox(x: 0, y: 0, width: outputW, height: outputH)
  var usableArea = fullArea
  wlrSceneLayerSurfaceV1Configure(ls.sceneLayerSurface, addr fullArea, addr usableArea)

proc onLayerSurfaceCommit*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  ## NAPRAWIONY BRAK (znaleziony realnym testem end-to-end z minimalnym
  ## klientem `wl_shm`, patrz NAPRAWY.md): `arrange()` było wołane tylko na
  ## sygnale `map` powierzchni -- ale `wl_surface` "mapuje się" (w sensie
  ## wlroots) dopiero PO dołączeniu bufora, a klient potrzebuje PIERWSZEGO
  ## `configure`, żeby w ogóle wiedzieć, jakiego rozmiaru bufor przygotować
  ## (dokładnie tak samo jak przy xdg-surface). Nasłuchując `map`
  ## zamiast `commit`, kompozytor nigdy nie wysyłał tego pierwszego
  ## `configure` -- klient czekał w nieskończoność. `commit` odpala się
  ## przy KAŻDYM zatwierdzeniu stanu powierzchni (także tym pierwszym, bez
  ## bufora), więc to właściwe miejsce -- dokładnie tak, jak robią to
  ## realne kompozytory oparte o wlroots (sway/dwl: `arrange_layers()`
  ## wołane przy każdym commicie warstwy).
  let ls = containerOf(listener, LayerSurfaceZde, LayerSurfaceZdeObj, commitL)
  arrange(ls)

proc onLayerSurfaceMap*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let ls = containerOf(listener, LayerSurfaceZde, LayerSurfaceZdeObj, mapL)
  arrange(ls)

proc onLayerSurfaceUnmap*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  discard  # węzeł sceny sam się chowa (helper wlroots), nic dodatkowego do zrobienia

proc onLayerSurfaceDestroy*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let ls = containerOf(listener, LayerSurfaceZde, LayerSurfaceZdeObj, destroyL)
  zdeListRemove(addr ls.mapL.link)
  zdeListRemove(addr ls.unmapL.link)
  zdeListRemove(addr ls.commitL.link)
  zdeListRemove(addr ls.destroyL.link)
  ls.server.layerSurfaces.keepItIf(it != ls)

proc onNewLayerSurface*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, newLayerSurfaceL)
  let wlrLs = cast[ptr WlrLayerSurfaceV1](data)

  ## Klient może zostawić `output` puste -- protokół mówi wprost, że wtedy
  ## to NASZA odpowiedzialność, żeby coś przydzielić (patrz komentarz w
  ## nagłówku). Bierzemy pierwsze dostępne wyjście; wybór "właściwego"
  ## monitora (np. tego z `primary: true` w Ustawieniach) to rozsądne
  ## rozszerzenie na później.
  if wlrLs.output == nil:
    if server.outputs.len == 0:
      stderr.writeLine("zde-comp: nowa warstwa (layer-shell) bez dostępnego wyjścia -- odrzucam")
      wlrLayerSurfaceV1Destroy(wlrLs)
      return
    wlrLs.output = server.outputs[0].wlrOutput

  let parentTree = treeForLayer(server, wlrLs.pending.layer)
  let ls = LayerSurfaceZde(server: server, wlrLayerSurface: wlrLs)
  ls.sceneLayerSurface = wlrSceneLayerSurfaceV1Create(parentTree, wlrLs)
  ls.sceneLayerSurface.tree.node.data = cast[pointer](ls)

  zdeSignalAdd(addr surfaceEvents(wlrLs.surface).map, addr ls.mapL, onLayerSurfaceMap)
  zdeSignalAdd(addr surfaceEvents(wlrLs.surface).unmap, addr ls.unmapL, onLayerSurfaceUnmap)
  zdeSignalAdd(addr surfaceEvents(wlrLs.surface).commit, addr ls.commitL, onLayerSurfaceCommit)
  zdeSignalAdd(addr layerSurfaceEvents(wlrLs).destroy, addr ls.destroyL, onLayerSurfaceDestroy)

  server.layerSurfaces.add(ls)
  stderr.writeLine("zde-comp: nowa warstwa layer-shell, namespace=\"" & layerNamespace(wlrLs) & "\"")
