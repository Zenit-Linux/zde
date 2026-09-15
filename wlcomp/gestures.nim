import wlroots
import types
import toplevel

## Rozbudowa v0.1 ("Aurora"/gesty). Obsługujemy tylko SWIPE (przesunięcie
## kilkoma palcami po touchpadzie) -- nie pinch (zbliżanie/oddalanie) ani
## hold, patrz duży komentarz nad `WlrCursorEvents`/sekcją "Gesty
## touchpada" w `wlroots.nim`.
##
## Działanie: 3-palcowy swipe w lewo/prawo przełącza aktywne okno --
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

proc hookGestures*(server: Server) =
  server.pointerGestures = wlrPointerGesturesV1Create(server.display)
  zdeSignalAdd(addr cursorEvents(server.cursor).swipeBegin, addr server.swipeBeginL, onCursorSwipeBegin)
  zdeSignalAdd(addr cursorEvents(server.cursor).swipeUpdate, addr server.swipeUpdateL, onCursorSwipeUpdate)
  zdeSignalAdd(addr cursorEvents(server.cursor).swipeEnd, addr server.swipeEndL, onCursorSwipeEnd)
