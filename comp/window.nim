import std/[algorithm, sequtils]
import vmath
import types

const WorkspaceCount* = 4  ## liczba pulpitów wirtualnych -- patrz `ZdeWindow.workspace`/`Compositor.currentWorkspace` w `types.nim`

proc newCompositor*(screenSize: Vec2): Compositor =
  result = Compositor(
    windows: @[],
    nextId: 1,
    focusedId: 0,
    screenSize: screenSize,
    launcherOpen: false,
    currentWorkspace: 0,
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

proc clampToScreen*(comp: Compositor, win: ZdeWindow) =
  ## Nie pozwala oknu całkowicie "uciec" poza ekran -- pasek tytułu musi
  ## zawsze zostać choć trochę widoczny i klikalny. Eksportowane -- używane
  ## też przez drag.nim przy przeciąganiu.
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
    workspace: comp.currentWorkspace,
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
    # oddaj focus najwyżej ułożonemu z pozostałych okien NA TYM SAMYM
    # pulpicie -- okno na innym, niewidocznym pulpicie i tak nie powinno
    # dostać fokusu (patrz rozbudowa v0.1 "Aurora" -- pulpity wirtualne)
    var best: ZdeWindow = nil
    for win in comp.windows:
      if win.minimized or win.workspace != w.workspace: continue
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
  ## Zwykła maksymalizacja (przycisk w tytule, nie Super+Left/Right) nie
  ## jest przyciągnięciem do krawędzi -- zeruje `snapEdge`, żeby kolejne
  ## Super+Left poprawnie rozpoznało "jeszcze nie przyciągnięte", a nie
  ## trafiło na nieaktualną wartość sprzed poprzedniego snapu.
  w.snapEdge = seNone
  comp.focus(id)

## `SnapEdge` zdefiniowane w `comp/types.nim` (obok pola `snapEdge` w
## `ZdeWindow`, które go używa) -- nie tutaj.
proc snapWindow*(comp: Compositor, id: int, edge: SnapEdge) =
  ## Rozbudowa v0.1 ("Aurora"): przyciąganie okna do połowy ekranu skrótem
  ## klawiszowym (Super+Left/Right, patrz `shell/shortcuts.nim` i
  ## `dispatchShortcut` w `shell.nim`) -- ten sam mechanizm
  ## zapamiętywania/przywracania geometrii co `toggleMaximize` powyżej
  ## (`savedPos`/`savedSize`), więc Super+Left, a potem zwykłe
  ## odmaksymalizowanie (przycisk w tytule albo Super+Left ponownie)
  ## poprawnie wraca do rozmiaru okna sprzed przyciągnięcia -- nie do
  ## jakiegoś domyślnego rozmiaru.
  let w = comp.findWindow(id)
  if w.isNil or not w.resizable: return
  ## Jeśli okno JUŻ jest przyciągnięte do TEJ SAMEJ krawędzi, drugie
  ## naciśnięcie tego samego skrótu przywraca oryginalny rozmiar (toggle),
  ## zamiast bezczynnie przyciągać "od nowa" do tego samego miejsca --
  ## intuicyjne zachowanie, którego użytkownik oczekuje po Super+Left,
  ## Super+Left.
  if w.maximized and w.snapEdge == edge:
    w.pos = w.savedPos
    w.size = w.savedSize
    w.maximized = false
    w.snapEdge = seNone
    comp.focus(id)
    return
  if not w.maximized:
    w.savedPos = w.pos
    w.savedSize = w.size
  let halfW = comp.screenSize.x / 2
  let fullH = comp.screenSize.y - TaskbarHeight
  case edge
  of seLeft: w.pos = vec2(0, 0)
  of seRight: w.pos = vec2(halfW, 0)
  of seNone: return  ## nie powinno się zdarzyć (wywołujący zawsze przekazuje seLeft/seRight), ale Nim wymaga wyczerpania wszystkich wartości enuma
  w.size = vec2(halfW, fullH)
  w.maximized = true
  w.snapEdge = edge
  comp.focus(id)

proc cycleFocus*(comp: Compositor) =
  ## Alt+Tab: przełącza focus na kolejne okno w kolejności z-order, TYLKO
  ## na aktualnym pulpicie (rozbudowa v0.1 "Aurora" -- pulpity wirtualne).
  var visible = comp.windows.filterIt(not it.minimized and it.workspace == comp.currentWorkspace)
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
  ## Zwraca widoczne okna NA AKTUALNYM PULPICIE, posortowane rosnąco po
  ## z-index (rysować w tej kolejności, żeby ostatnie -- najwyżej ułożone
  ## -- trafiło na wierzch). Okna z innych pulpitów (rozbudowa v0.1
  ## "Aurora") są tak samo "niewidoczne" jak zminimalizowane -- to ten
  ## sam mechanizm ukrywania, tylko z innego powodu.
  result = comp.windows.filterIt(not it.minimized and it.workspace == comp.currentWorkspace)
  result.sort(proc(a, b: ZdeWindow): int = cmp(a.zIndex, b.zIndex))

proc switchWorkspace*(comp: Compositor, ws: int) =
  ## Rozbudowa v0.1 ("Aurora" -- pulpity wirtualne). `ws` jest
  ## przycinane do `[0, WorkspaceCount-1]` zamiast ignorowane poza
  ## zakresem -- skróty klawiszowe (Ctrl+Alt+Left/Right,
  ## `shell/shortcuts.nim`) liczą względem bieżącego pulpitu i mogłyby
  ## łatwo wyjść poza zakres na skrajnych pulpitach bez tego zabezpieczenia.
  comp.currentWorkspace = clamp(ws, 0, WorkspaceCount - 1)
  ## Fokus musi przeskoczyć na coś widocznego na NOWYM pulpicie -- inaczej
  ## klawiatura "celowałaby" w okno, którego użytkownik akurat nie widzi.
  var best: ZdeWindow = nil
  for win in comp.windows:
    if win.minimized or win.workspace != comp.currentWorkspace: continue
    if best.isNil or win.zIndex > best.zIndex:
      best = win
  comp.focusedId = (if best.isNil: 0 else: best.id)

proc moveWindowToWorkspace*(comp: Compositor, id: int, ws: int) =
  ## Przenosi okno na inny pulpit i OD RAZU przełącza na ten pulpit --
  ## tak, żeby użytkownik zobaczył efekt swojego skrótu (Ctrl+Alt+Shift+
  ## Left/Right), zamiast okno "znikało" mu z ekranu bez wyjaśnienia.
  let w = comp.findWindow(id)
  if w.isNil: return
  w.workspace = clamp(ws, 0, WorkspaceCount - 1)
  comp.switchWorkspace(w.workspace)
  comp.focusedId = id

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
