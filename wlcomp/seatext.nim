import wlroots
import types

proc onRequestSetSelection*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  ## Klient prosi "chcę być teraz właścicielem schowka" (typowo: użytkownik
  ## nacisnął Ctrl+C / zaznaczył tekst). Ufamy każdemu takiemu żądaniu --
  ## tak samo jak większość prostych kompozytorów wlroots (brak tu żadnej
  ## "polityki" do wymuszenia: to seat pilnuje, że tylko klient z aktualnym
  ## fokusem klawiatury może to zrobić, patrz implementacja wlroots).
  let server = containerOf(listener, Server, ServerObj, requestSetSelectionL)
  let event = cast[ptr WlrSeatRequestSetSelectionEvent](data)
  wlrSeatSetSelection(server.seat, event.source, event.serial)

proc onDragIconDestroy*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, dragIconDestroyL)
  zdeListRemove(addr server.dragIconDestroyL.link)
  server.dragIconTree = nil  ## węzeł sceny sam się usuwa razem z drag (jest jego dzieckiem) --
                             ## tu tylko zapominamy wskaźnik, żeby processCursorMotion przestało go ruszać

proc onStartDrag*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  ## Przeciąganie faktycznie się zaczęło (po `request_start_drag`, jeśli
  ## seat je zaakceptował). Jeśli klient dołączył ikonkę (`drag.icon` --
  ## opcjonalne, np. przy przeciąganiu czystego tekstu może jej nie być),
  ## tworzymy dla niej węzeł sceny w warstwie overlay (zawsze na wierzchu,
  ## niezależnie od okien) i będziemy go przesuwać razem z kursorem
  ## (patrz `processCursorMotion` w input.nim).
  let server = containerOf(listener, Server, ServerObj, startDragL)
  let drag = cast[ptr WlrDrag](data)
  if drag.icon == nil: return
  server.dragIconTree = wlrSceneDragIconCreate(server.overlayTree, drag.icon)
  zdeSignalAdd(addr dragEvents(drag).destroy, addr server.dragIconDestroyL, onDragIconDestroy)

proc onRequestStartDrag*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  ## Klient prosi o rozpoczęcie drag&drop. Prosta polityka -- tak jak przy
  ## selection, akceptujemy każde żądanie i zostawiamy seatowi pilnowanie
  ## poprawności (np. że towarzyszy mu wciśnięty przycisk myszy). Realne
  ## `wlr_seat_start_pointer_drag` samo wywoła `events.start_drag`
  ## (obsłużone wyżej), jeśli się powiedzie.
  let server = containerOf(listener, Server, ServerObj, requestStartDragL)
  let event = cast[ptr WlrSeatRequestStartDragEvent](data)
  wlrSeatStartPointerDrag(server.seat, event.drag, event.serial)
