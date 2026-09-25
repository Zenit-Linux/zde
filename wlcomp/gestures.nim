import wlroots
import types
import toplevel

## Rozbudowa v0.1 ("Aurora"/gesty) + runda 34 (pinch/hold).
##
## Działanie SWIPE: 3-palcowy swipe w lewo/prawo przełącza aktywne okno --
## natychmiast, po zakończeniu gestu (`swipe_end`), na podstawie
## SUMARYCZNEGO przesunięcia w poziomie od `swipe_begin` (nie każdego
## pojedynczego `swipe_update` -- inaczej drobne drżenie palca w trakcie
## gestu mogłoby przełączyć kilka okien naraz). Próg (`SwipeThresholdPx`)
## musi być przekroczony, żeby odróżnić celowy gest od przypadkowego
## musnięcia touchpada.
##
## Niezależnie od własnej reakcji kompozytora, KAŻDY gest jest też
## przekazywany dalej do klientów przez `wlr_pointer_gestures_v1` (jeśli
## akurat słuchają protokołu) -- patrz komentarz nad
## `WlrPointerGesturesV1` w `wlroots.nim` o tym, że to osobna, niezależna
## ścieżka.
##
## **Runda 34 -- domknięcie punktu z listy ograniczeń ("gesty touchpada:
## tylko swipe").** Pinch i hold są teraz podłączone i re-broadcastowane
## do klientów DOKŁADNIE tym samym wzorcem co swipe. Kompozytor CELOWO
## nie wiąże ich z żadną WŁASNĄ akcją (w odróżnieniu od swipe, które
## przełącza okna) -- ZDE wciąż nie ma osobnego okna z natywnym zoomem
## (przeglądarki obrazów/plików), więc "co dokładnie miałby robić pinch
## na poziomie kompozytora" nie ma dziś jednoznacznej odpowiedzi;
## zgadywanie tego byłoby gorsze niż uczciwe ograniczenie do
## re-broadcastu. Aplikacje, które same obsługują `wlr_pointer_gestures_v1`
## (np. przeglądarka WWW), już teraz dostają prawdziwe zdarzenia
## pinch/hold z tego kompozytora -- to nie jest "brak" tego protokołu,
## tylko brak WŁASNEJ, dodatkowej reakcji ZDE na niego.
##
## **Uczciwa notatka o weryfikacji**: tak jak reszta `wlcomp/` w tej
## sesji, ten kod nie został skompilowany wobec prawdziwych nagłówków
## wlroots (brak `libwlroots-dev` w tej konkretnej sandboxie tej rundy) --
## nazwy pól/sygnałów (`events.pinch_begin` itd., `struct
## wlr_pointer_pinch_*_event`) zostały odtworzone z pamięci API wlroots
## 0.18, tym samym stylem co reszta już wcześniej zweryfikowanych
## rund (patrz np. runda 4 o primary selection) -- ale BEZ tamtej
## rundy realnej, kompilacyjnej weryfikacji. Do potwierdzenia w
## przyszłej sesji z dostępem do nagłówków wlroots.

const
  GestureFingers = 3'u32      ## tylko gesty 3-palcowe przełączają okna (2 palce to zwykły scroll)
  SwipeThresholdPx = 60.0     ## minimalne sumaryczne przesunięcie w poziomie, żeby "policzyć się"

proc onCursorSwipeBegin(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, swipeBeginL)
  let ev = cast[ptr WlrPointerSwipeBeginEvent](data)
  server.gestureFingers = ev.fingers
  server.gestureAccumDx = 0.0
  if server.pointerGestures != nil:
    wlrPointerGesturesV1SendSwipeBegin(server.pointerGestures, server.seat, ev.timeMsec, ev.fingers)

proc onCursorSwipeUpdate(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, swipeUpdateL)
  let ev = cast[ptr WlrPointerSwipeUpdateEvent](data)
  server.gestureAccumDx += ev.dx
  if server.pointerGestures != nil:
    wlrPointerGesturesV1SendSwipeUpdate(server.pointerGestures, server.seat, ev.timeMsec, ev.dx, ev.dy)

proc onCursorSwipeEnd(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, swipeEndL)
  let ev = cast[ptr WlrPointerSwipeEndEvent](data)
  if server.pointerGestures != nil:
    wlrPointerGesturesV1SendSwipeEnd(server.pointerGestures, server.seat, ev.timeMsec, ev.cancelled)

  if not ev.cancelled and server.gestureFingers == GestureFingers:
    if server.gestureAccumDx <= -SwipeThresholdPx:
      cycleFocusBy(server, -1)   ## swipe w lewo -- "wstecz" (jak przesuwanie kartek w lewo)
    elif server.gestureAccumDx >= SwipeThresholdPx:
      cycleFocusBy(server, 1)    ## swipe w prawo -- "do przodu"
  server.gestureFingers = 0
  server.gestureAccumDx = 0.0

## --- Pinch (runda 34) -- WYŁĄCZNIE re-broadcast, zero reakcji kompozytora,
## patrz duży komentarz na górze pliku po uzasadnienie tego zakresu.

proc onCursorPinchBegin(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, pinchBeginL)
  let ev = cast[ptr WlrPointerPinchBeginEvent](data)
  if server.pointerGestures != nil:
    wlrPointerGesturesV1SendPinchBegin(server.pointerGestures, server.seat, ev.timeMsec, ev.fingers)

proc onCursorPinchUpdate(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, pinchUpdateL)
  let ev = cast[ptr WlrPointerPinchUpdateEvent](data)
  if server.pointerGestures != nil:
    wlrPointerGesturesV1SendPinchUpdate(server.pointerGestures, server.seat, ev.timeMsec, ev.dx, ev.dy, ev.scale, ev.rotation)

proc onCursorPinchEnd(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, pinchEndL)
  let ev = cast[ptr WlrPointerPinchEndEvent](data)
  if server.pointerGestures != nil:
    wlrPointerGesturesV1SendPinchEnd(server.pointerGestures, server.seat, ev.timeMsec, ev.cancelled)

## --- Hold (runda 34) -- tak samo, czysty re-broadcast.

proc onCursorHoldBegin(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, holdBeginL)
  let ev = cast[ptr WlrPointerHoldBeginEvent](data)
  if server.pointerGestures != nil:
    wlrPointerGesturesV1SendHoldBegin(server.pointerGestures, server.seat, ev.timeMsec, ev.fingers)

proc onCursorHoldEnd(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, holdEndL)
  let ev = cast[ptr WlrPointerHoldEndEvent](data)
  if server.pointerGestures != nil:
    wlrPointerGesturesV1SendHoldEnd(server.pointerGestures, server.seat, ev.timeMsec, ev.cancelled)

proc hookGestures*(server: Server) =
  server.pointerGestures = wlrPointerGesturesV1Create(server.display)
  zdeSignalAdd(addr cursorEvents(server.cursor).swipeBegin, addr server.swipeBeginL, onCursorSwipeBegin)
  zdeSignalAdd(addr cursorEvents(server.cursor).swipeUpdate, addr server.swipeUpdateL, onCursorSwipeUpdate)
  zdeSignalAdd(addr cursorEvents(server.cursor).swipeEnd, addr server.swipeEndL, onCursorSwipeEnd)
  # Runda 34 -- pinch/hold, sam re-broadcast (patrz komentarz na górze pliku).
  zdeSignalAdd(addr cursorEvents(server.cursor).pinchBegin, addr server.pinchBeginL, onCursorPinchBegin)
  zdeSignalAdd(addr cursorEvents(server.cursor).pinchUpdate, addr server.pinchUpdateL, onCursorPinchUpdate)
  zdeSignalAdd(addr cursorEvents(server.cursor).pinchEnd, addr server.pinchEndL, onCursorPinchEnd)
  zdeSignalAdd(addr cursorEvents(server.cursor).holdBegin, addr server.holdBeginL, onCursorHoldBegin)
  zdeSignalAdd(addr cursorEvents(server.cursor).holdEnd, addr server.holdEndL, onCursorHoldEnd)
