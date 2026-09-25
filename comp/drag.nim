import vmath
import types
import window

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
    ## Rozbudowa (runda 22, "Aero Snap" myszą): wykrywa TYLKO, czy
    ## kursor jest w strefie aktywacji -- NIE zmienia tu jeszcze
    ## rozmiaru/pozycji okna (patrz duży komentarz przy
    ## `pendingSnapEdge`/`pendingMaximize` w `types.nim`, dlaczego sam
    ## snap czeka do puszczenia przycisku myszy, w `endDrag` niżej).
    ## Świadomie liczone na `cursorPos` (pozycja MYSZY), nie `w.pos`
    ## (pozycja OKNA) -- to zachowanie użytkownika chcemy wykryć ("czy
    ## PODJECHAŁEM kursorem pod krawędź"), nie geometrię samego okna,
    ## które przez powyższą magnetyczną korektę pozycji i tak już może
    ## być blisko 0.
    comp.drag.pendingMaximize = cursorPos.y <= TopDragSnapZone
    if not comp.drag.pendingMaximize:
      if cursorPos.x <= SnapMargin:
        comp.drag.pendingSnapEdge = seLeft
      elif cursorPos.x >= comp.screenSize.x - SnapMargin:
        comp.drag.pendingSnapEdge = seRight
      else:
        comp.drag.pendingSnapEdge = seNone
    else:
      comp.drag.pendingSnapEdge = seNone  ## góra ma pierwszeństwo nad bokami -- róg ekranu maksymalizuje, nie przyciąga do połowy

  of dkResize:
    let delta = cursorPos - comp.drag.grabOffset
    var newPos = comp.drag.startPos
    var newSize = comp.drag.startSize
    ## Rozbudowa (runda 26): NAPRAWIONY BŁĄD, znaleziony przez
    ## uruchomienie kodu -- `applyLeft`/`applyTop` liczyły `newPos` z
    ## NIEPRZYCIĘTEGO `delta`, a przycinanie do `minSize` działo się
    ## DOPIERO PO ustaleniu `newPos` (patrz `newSize.x = max(...)` niżej,
    ## bez odpowiadającej korekty `newPos`). W praktyce: przeciągnięcie
    ## LEWEJ (albo GÓRNEJ) krawędzi POZA punkt, w którym rozmiar
    ## osiągnąłby `minSize`, powodowało, że PRZECIWLEGŁA krawędź (prawa/
    ## dolna -- ta, której użytkownik W OGÓLE nie dotykał) NAGLE
    ## PRZESKAKIWAŁA w bok, zamiast zostać na miejscu. Potwierdzone
    ## bezpośrednim uruchomieniem PRZED naprawą: okno 200x150 na pozycji
    ## (100,100) (prawa krawędź = 300), przeciągnięcie lewej krawędzi o
    ## +150px (poza `minSize.x = 100`) dawało `pos.x=250, size.x=100` --
    ## prawa krawędź wychodziła na 350, nie zostawała na 300.
    ##
    ## Naprawa: licz `newSize` NAJPIERW (surowo, bez przycinania), a
    ## `newPos` dla lewej/górnej krawędzi ustalaj na podstawie TEGO, o
    ## ILE rozmiar FAKTYCZNIE się zmienił WZGLĘDEM przyciętego minimum --
    ## nie wprost z `delta` kursora. Dla `applyRight`/`applyBottom`
    ## (prawa/dolna krawędź) `newPos` się w ogóle nie zmienia, więc tam
    ## przycinanie rozmiaru do `minSize` już samo w sobie było zawsze
    ## poprawne (stąd błąd dotyczył WYŁĄCZNIE lewej/górnej, nigdy
    ## prawej/dolnej -- test regresyjny to potwierdza osobno).
    template applyRight() = newSize.x = comp.drag.startSize.x + delta.x
    template applyBottom() = newSize.y = comp.drag.startSize.y + delta.y
    template applyLeft() =
      let rawW = comp.drag.startSize.x - delta.x
      newSize.x = max(rawW, w.minSize.x)
      ## Prawa krawędź (`startPos.x + startSize.x`) MUSI zostać
      ## nieruchoma -- lewa krawędź to jedyna, którą użytkownik
      ## faktycznie przeciąga. `newPos.x` dobrany tak, żeby
      ## `newPos.x + newSize.x` zawsze równało się nieruchomej prawej
      ## krawędzi, NIEZALEŻNIE od tego, czy `rawW` zostało przycięte do
      ## `minSize`, czy nie.
      newPos.x = comp.drag.startPos.x + comp.drag.startSize.x - newSize.x
    template applyTop() =
      let rawH = comp.drag.startSize.y - delta.y
      newSize.y = max(rawH, w.minSize.y)
      newPos.y = comp.drag.startPos.y + comp.drag.startSize.y - newSize.y

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

    ## `applyRight`/`applyBottom` same NIE przycinają do `minSize` (nie
    ## muszą korygować `newPos`, patrz komentarz wyżej) -- to przycięcie
    ## wciąż potrzebne TUTAJ, jako ostatnia siatka bezpieczeństwa dla ich
    ## przypadku (i nieszkodliwe dla lewej/górnej, które są już
    ## przycięte wyżej -- `max` z już-przyciętą wartością to no-op).
    newSize.x = max(newSize.x, w.minSize.x)
    newSize.y = max(newSize.y, w.minSize.y)
    w.pos = newPos
    w.size = newSize

  of dkNone: discard

proc endDrag*(comp: Compositor) =
  ## Rozbudowa (runda 22, "Aero Snap" myszą): jeśli przeciąganie było
  ## ruchem okna (`dkMove`) i w chwili puszczenia przycisku myszy kursor
  ## był w strefie aktywacji (patrz `updateDrag` wyżej), faktyczne
  ## przyciągnięcie następuje TERAZ -- nie wcześniej. `comp.snapWindow`
  ## samo zapisuje BIEŻĄCĄ (właśnie przeciągniętą) pozycję/rozmiar okna
  ## do `savedPos`/`savedSize` (skoro okno nie jest jeszcze
  ## zmaksymalizowane -- `beginMove` w ogóle nie pozwala zacząć
  ## przeciągania zmaksymalizowanego okna), więc "cofnięcie" przyciągnięcia
  ## (Super+Left ponownie, albo przycisk w tytule) poprawnie wraca do
  ## miejsca, w które użytkownik przeciągnął okno TUŻ PRZED puszczeniem
  ## myszy -- nie do jakiejś domyślnej pozycji sprzed całego ruchu.
  if comp.drag.kind == dkMove:
    let w = comp.findWindow(comp.drag.windowId)
    if not w.isNil and w.resizable:
      if comp.drag.pendingMaximize:
        comp.doMaximize(w)
        comp.focus(w.id)
      elif comp.drag.pendingSnapEdge != seNone:
        comp.snapWindow(w.id, comp.drag.pendingSnapEdge)
  comp.drag = DragState(kind: dkNone)
