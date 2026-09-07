import std/sequtils
import wlroots
import types

proc onPopupDestroy*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let p = containerOf(listener, PopupZde, PopupZdeObj, destroyL)
  zdeListRemove(addr p.destroyL.link)
  p.server.popups.keepItIf(it != p)

proc parentSceneTree(server: Server, parentSurface: ptr WlrSurface): ptr WlrSceneTree =
  ## Szuka drzewa sceny odpowiadającego powierzchni-rodzicowi popupu --
  ## rodzicem może być toplevel, panel (layer-shell) albo inny popup
  ## (zagnieżdżone menu). Jeśli nic nie pasuje (nie powinno się zdarzyć w
  ## normalnym użyciu), wracamy do drzewa toplevели jako rozsądny fallback
  ## -- lepiej żeby popup się pokazał w niewłaściwym miejscu niż wcale.
  if parentSurface == nil: return server.toplevelTree
  let parentXdg = wlrXdgSurfaceTryFromWlrSurface(parentSurface)
  if parentXdg != nil:
    for t in server.toplevels:
      if t.xdgSurface == parentXdg: return t.sceneTree
    for pp in server.popups:
      if pp.xdgSurface == parentXdg: return pp.sceneTree
  let parentLayer = wlrLayerSurfaceV1TryFromWlrSurface(parentSurface)
  if parentLayer != nil:
    for ls in server.layerSurfaces:
      if ls.wlrLayerSurface == parentLayer: return ls.sceneLayerSurface.tree
  server.toplevelTree

proc handleNewPopup*(server: Server, popupXdgSurface: ptr WlrXdgSurface) =
  let popup = xdgSurfacePopup(popupXdgSurface)
  if popup == nil: return
  let parentTree = parentSceneTree(server, popup.parent)

  let p = PopupZde(server: server, xdgSurface: popupXdgSurface)
  p.sceneTree = wlrSceneXdgSurfaceCreate(parentTree, popupXdgSurface)
  p.sceneTree.node.data = cast[pointer](p)
  zdeSignalAdd(addr xdgSurfaceEvents(popupXdgSurface).destroy, addr p.destroyL, onPopupDestroy)
  server.popups.add(p)
