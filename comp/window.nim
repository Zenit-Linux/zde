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

  ## Rozbudowa (runda 25): NAPRAWIONY BŁĄD, znaleziony przez uruchomienie
  ## kodu -- kaskada była dotąd kluczowana po `comp.windows.len` (liczba
  ## okien OTWARTYCH AKURAT TERAZ), nie po liczbie okien otwartych
  ## kiedykolwiek w tej sesji. W praktyce: zamknięcie okna W ŚRODKU
  ## sekwencji otwierania (bardzo zwyczajny scenariusz codziennego
  ## użytkowania, nie przypadek brzegowy) cofało licznik kaskady,
  ## powodując, że KOLEJNE nowo otwarte okno lądowało DOKŁADNIE na
  ## pozycji innego, wciąż otwartego okna -- dokładnie ten problem,
  ## który kaskadowanie miało w ogóle zapobiegać. Potwierdzone
  ## bezpośrednim uruchomieniem PRZED naprawą: otwórz W1/W2/W3, zamknij
  ## W2, otwórz W4 -- W4 lądowało DOKŁADNIE na W3 (identyczna pozycja).
  ## Naprawa: kaskada liczona wg `id` (unikalny, monotonicznie rosnący,
  ## NIGDY nie cofa się ani nie jest ponownie użyty, niezależnie od tego,
  ## ile okien zamknięto po drodze) zamiast `comp.windows.len`.
  let cascadeIdx = (id - 1) mod 8  ## `id` zaczyna się od 1, stąd `-1` dla indeksowania od zera
  let cascade = vec2(float32(cascadeIdx) * 28.0'f32, float32(cascadeIdx) * 28.0'f32)

  ## Rozbudowa (runda 31): NAPRAWIONA LUKA W KONTRAKCIE, znaleziona przez
  ## uruchomienie kodu -- `size` był dotąd wpisywany do konstruktora
  ## WPROST, bez sprawdzenia, czy w ogóle mieści się w `minSize` (tego
  ## samego okna!). Nic nie chroniło przed otwarciem okna, którego
  ## POCZĄTKOWY rozmiar jest MNIEJSZY niż jego własny, zadeklarowany
  ## minimalny rozmiar -- sprzeczność wewnętrzna w jednym i tym samym
  ## wywołaniu `openWindow`. Potwierdzone bezpośrednim uruchomieniem
  ## PRZED naprawą: `openWindow(..., size = vec2(100, 50), minSize =
  ## vec2(280, 180))` dawało okno `size = (100, 50)` -- mniejsze niż
  ## jego własne `minSize`.
  ##
  ## Uczciwa notatka o zasięgu (ten sam duch co runda 29): sprawdzone w
  ## `shell/launcher_apps.nim` -- WSZYSTKIE obecne w kodzie aplikacji
  ## wywołania `openWindow` przekazują `size` (najmniejsze: 300x420)
  ## bezpiecznie większy niż `DefaultMinSize` (280x180), ŻADNE nie
  ## przekazuje własnego `minSize` w ogóle. To NIE jest błąd widoczny w
  ## obecnym, codziennym działaniu ZDE -- to luka w kontrakcie, którą
  ## ugryzłaby PIERWSZA aplikacja (albo test, albo przyszła zmiana
  ## domyślnych rozmiarów), jaka przekazałaby oba parametry
  ## niespójnie. Naprawiona teraz przez przycięcie `size` do `minSize`
  ## w JEDNYM, autorytatywnym miejscu -- tym samym duchu co przycinanie
  ## w `dkResize` z rundy 26, tylko zastosowane też przy SAMYM
  ## OTWARCIU okna, nie tylko przy jego późniejszej zmianie rozmiaru.
  ## Liczone PRZED `pos` niżej (nie po), żeby kaskadowe wyśrodkowanie na
  ## ekranie też korzystało z FAKTYCZNEGO, przyciętego rozmiaru okna, nie
  ## z surowego, potencjalnie za małego `size`.
  let clampedSize = vec2(max(size.x, minSize.x), max(size.y, minSize.y))

  var pos = vec2(
    (comp.screenSize.x - clampedSize.x) / 2.0'f32 + cascade.x - 100.0'f32,
    (comp.screenSize.y - TaskbarHeight - clampedSize.y) / 2.0'f32 + cascade.y - 60.0'f32,
  )
  pos.x = max(pos.x, 20.0'f32)
  pos.y = max(pos.y, 20.0'f32)

  result = ZdeWindow(
    id: id,
    title: title,
    kind: kind,
    pos: pos,
    size: clampedSize,
    minSize: minSize,
    savedPos: pos,
    savedSize: clampedSize,
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

proc focusNextBestOnWorkspace(comp: Compositor, workspace: int) =
  ## Rozbudowa (runda 30): wydzielone z `closeWindow`/`minimizeWindow` --
  ## sama logika "znajdź i ogniskuj najwyżej ułożone z POZOSTAŁYCH
  ## widocznych okien na DANYM pulpicie" (albo nic, jeśli nie zostało
  ## żadne) -- wołane, gdy okno PRZESTAJE być widoczne (zamknięte albo
  ## zminimalizowane; oba to, z punktu widzenia użytkownika, ten sam
  ## rodzaj zdarzenia: "to okno znika z widoku, coś innego powinno
  ## przejąć fokus"). Wydzielenie eliminuje duplikację, która już raz w
  ## tej rundzie doprowadziła do rozjechania się dwóch miejsc robiących
  ## konceptualnie to samo (patrz duży komentarz przy `minimizeWindow`
  ## niżej po pełną historię).
  comp.focusedId = 0
  var best: ZdeWindow = nil
  for win in comp.windows:
    if win.minimized or win.workspace != workspace: continue
    if best.isNil or win.zIndex > best.zIndex:
      best = win
  if not best.isNil:
    comp.focusedId = best.id

proc closeWindow*(comp: Compositor, id: int) =
  let w = comp.findWindow(id)
  if w.isNil: return
  ## Rozbudowa (runda 29): NAPRAWIONA NIESPÓJNOŚĆ API, znaleziona przez
  ## uruchomienie kodu -- `closable` (parametr `openWindow`, sprawdzany
  ## DOTĄD wyłącznie w `shell/chrome.nim` przy decyzji, czy w ogóle
  ## POKAZAĆ przycisk "X" na pasku tytułu) był CAŁKOWICIE ignorowany
  ## przez samo `closeWindow`. W praktyce oznaczało to, że ukrycie
  ## przycisku "X" było jedynie KOSMETYCZNE -- skrót klawiszowy
  ## (Ctrl+Alt+Q, `actCloseWindow` w `shell/shell.nim`) albo jakiekolwiek
  ## inne, przyszłe wywołanie `closeWindow` wprost (nie przez kliknięcie
  ## "X") wciąż zamykało okno, mimo `closable = false`. Potwierdzone
  ## bezpośrednim uruchomieniem PRZED naprawą: okno otwarte z
  ## `closable = false`, wywołanie `closeWindow` na nim -- zniknęło z
  ## `comp.windows` mimo wszystko.
  ##
  ## Uczciwa notatka o zasięgu: w CAŁYM obecnym kodzie aplikacji żadne
  ## okno nie jest dziś otwierane z `closable = false` (sprawdzone przez
  ## `grep` po repo) -- więc to NIE jest błąd widoczny w obecnym,
  ## codziennym działaniu ZDE, tylko luka w egzekwowaniu udokumentowanego
  ## kontraktu publicznego parametru `openWindow`, która ugryzłaby
  ## PIERWSZĄ aplikację, jaka kiedykolwiek by z niego skorzystała.
  ## Naprawiona teraz, na zapas, żeby ten kontrakt faktycznie znaczył to,
  ## co obiecuje -- egzekwowanie w JEDNYM, autorytatywnym miejscu
  ## (`closeWindow` samo), zamiast polegać na tym, że KAŻDY wywołujący
  ## (skrót klawiszowy, dok, przyciski w UI, przyszły kod) osobno o tym
  ## pamięta.
  if not w.closable: return
  if not w.onClose.isNil:
    w.onClose(w)
  comp.windows.keepItIf(it.id != id)
  if comp.focusedId == id:
    comp.focusNextBestOnWorkspace(w.workspace)

proc minimizeWindow*(comp: Compositor, id: int) =
  let w = comp.findWindow(id)
  if w.isNil: return
  w.minimized = true
  ## Rozbudowa (runda 30): NAPRAWIONA ASYMETRIA, znaleziona przez
  ## uruchomienie kodu -- `closeWindow` (wyżej) po usunięciu okna zawsze
  ## oddawał fokus najwyżej ułożonemu z pozostałych widocznych okien NA
  ## TYM SAMYM pulpicie. `minimizeWindow` (ten sam rodzaj operacji z
  ## punktu widzenia użytkownika -- "to okno znika z widoku") dotąd tego
  ## NIE robiło -- po prostu zerowało `comp.focusedId` na `0` i kończyło,
  ## nawet gdy na ekranie zostawały INNE, widoczne okna, które mogłyby
  ## (i powinny) przejąć fokus. Potwierdzone bezpośrednim uruchomieniem
  ## PRZED naprawą: dwa okna, w2 ma fokus, `minimizeWindow(w2)` --
  ## `windowsInZOrder()` nadal zwracało w1 (widoczne), ale `focusedId`
  ## zostawało `0`, jakby nic w ogóle nie było widoczne. Naprawa: reużycie
  ## DOKŁADNIE tej samej logiki co `closeWindow`, teraz wydzielonej do
  ## `focusNextBestOnWorkspace` powyżej -- oba miejsca robią konceptualnie
  ## to samo ("to okno przestaje być widoczne, oddaj fokus czemuś
  ## innemu"), więc powinny (i teraz dosłownie DZIELĄ) tę samą logikę,
  ## zamiast ryzykować, że kiedyś znów się rozjadą.
  if comp.focusedId == id:
    comp.focusNextBestOnWorkspace(w.workspace)

proc restoreWindow*(comp: Compositor, id: int) =
  comp.focus(id)  # focus() już czyści `minimized`

proc doMaximize*(comp: Compositor, w: ZdeWindow) =
  ## Rozbudowa (runda 22): wydzielone z `toggleMaximize` niżej -- sama
  ## logika "przejdź do stanu zmaksymalizowanego" (zapamiętaj obecną
  ## geometrię do `savedPos`/`savedSize`, rozciągnij na cały dostępny
  ## ekran), teraz używana w DWÓCH miejscach: `toggleMaximize` (przycisk
  ## w tytule okna) i `comp/drag.nim`'s `endDrag` (przeciągnięcie okna
  ## do samej góry ekranu myszą, "Aero Snap", patrz `pendingMaximize` w
  ## `types.nim`) -- bez tego wydzielenia druga ścieżka musiałaby
  ## duplikować dokładnie tę samą geometrię, z realnym ryzykiem, że
  ## kiedyś rozjadą się przy przyszłej zmianie (np. inny sposób liczenia
  ## `TaskbarHeight`).
  w.savedPos = w.pos
  w.savedSize = w.size
  w.pos = vec2(0, 0)
  w.size = vec2(comp.screenSize.x, comp.screenSize.y - TaskbarHeight)
  w.maximized = true
  w.snapEdge = seNone

proc toggleMaximize*(comp: Compositor, id: int) =
  let w = comp.findWindow(id)
  if w.isNil or not w.resizable: return
  if w.maximized:
    w.pos = w.savedPos
    w.size = w.savedSize
    w.maximized = false
  else:
    comp.doMaximize(w)
  ## Zwykła maksymalizacja (przycisk w tytule, nie Super+Left/Right) nie
  ## jest przyciągnięciem do krawędzi -- zeruje `snapEdge`, żeby kolejne
  ## Super+Left poprawnie rozpoznało "jeszcze nie przyciągnięte", a nie
  ## trafiło na nieaktualną wartość sprzed poprzedniego snapu.
  w.snapEdge = seNone
  comp.focus(id)

## `SnapEdge` zdefiniowane w `comp/types.nim` (obok pola `snapEdge` w
## `ZdeWindow`, które go używa) -- nie tutaj.

proc snapGeometry(comp: Compositor, edge: SnapEdge): tuple[pos, size: Vec2] =
  ## Rozbudowa (runda 21): geometria dla WSZYSTKICH ośmiu wariantów
  ## przyciągnięcia -- wydzielona z `snapWindow` do osobnej, czystej
  ## funkcji (bez skutków ubocznych, łatwej do przetestowania osobno od
  ## reszty logiki fokusu/zapamiętywania rozmiaru).
  let halfW = comp.screenSize.x / 2
  let fullW = comp.screenSize.x
  let fullH = comp.screenSize.y - TaskbarHeight
  let halfH = fullH / 2
  case edge
  of seLeft: (vec2(0, 0), vec2(halfW, fullH))
  of seRight: (vec2(halfW, 0), vec2(halfW, fullH))
  of seTop: (vec2(0, 0), vec2(fullW, halfH))
  of seBottom: (vec2(0, halfH), vec2(fullW, halfH))
  of seTopLeft: (vec2(0, 0), vec2(halfW, halfH))
  of seTopRight: (vec2(halfW, 0), vec2(halfW, halfH))
  of seBottomLeft: (vec2(0, halfH), vec2(halfW, halfH))
  of seBottomRight: (vec2(halfW, halfH), vec2(halfW, halfH))
  of seNone: (vec2(0, 0), vec2(0, 0))  ## nie powinno się zdarzyć -- wywołujący zawsze przekazuje realną krawędź

proc combinedEdge*(current, pressed: SnapEdge): SnapEdge =
  ## Rozbudowa (runda 21): "doprecyzowanie" w stylu Windows 11 Snap --
  ## naciśnięcie kierunku PIONOWEGO (Top/Bottom), gdy okno jest już
  ## przyciągnięte do kierunku POZIOMEGO (Left/Right) -- albo odwrotnie --
  ## łączy oba w ĆWIARTKĘ ekranu, zamiast po prostu ZASTĄPIĆ poprzednie
  ## przyciągnięcie nowym (co dałoby górną/dolną połowę CAŁEGO ekranu,
  ## gubiąc informację "ale użytkownik był już przyciągnięty do lewej").
  ## Eksportowana głównie do testów -- `snapWindow` niżej jest jedynym
  ## wywołującym w produkcyjnym kodzie.
  if pressed == seLeft:
    if current in {seTop, seTopLeft, seTopRight}: return seTopLeft
    if current in {seBottom, seBottomLeft, seBottomRight}: return seBottomLeft
    return seLeft
  if pressed == seRight:
    if current in {seTop, seTopLeft, seTopRight}: return seTopRight
    if current in {seBottom, seBottomLeft, seBottomRight}: return seBottomRight
    return seRight
  if pressed == seTop:
    if current in {seLeft, seTopLeft, seBottomLeft}: return seTopLeft
    if current in {seRight, seTopRight, seBottomRight}: return seTopRight
    return seTop
  if pressed == seBottom:
    if current in {seLeft, seTopLeft, seBottomLeft}: return seBottomLeft
    if current in {seRight, seTopRight, seBottomRight}: return seBottomRight
    return seBottom
  pressed  ## `pressed` to już ćwiartka albo `seNone` -- nic do łączenia

proc snapWindow*(comp: Compositor, id: int, edge: SnapEdge) =
  ## Rozbudowa v0.1 ("Aurora"): przyciąganie okna do połowy ekranu skrótem
  ## klawiszowym (Super+Left/Right, patrz `shell/shortcuts.nim` i
  ## `dispatchShortcut` w `shell.nim`) -- ten sam mechanizm
  ## zapamiętywania/przywracania geometrii co `toggleMaximize` powyżej
  ## (`savedPos`/`savedSize`), więc Super+Left, a potem zwykłe
  ## odmaksymalizowanie (przycisk w tytule albo Super+Left ponownie)
  ## poprawnie wraca do rozmiaru okna sprzed przyciągnięcia -- nie do
  ## jakiegoś domyślnego rozmiaru.
  ##
  ## Rozbudowa (runda 21): `edge` może być teraz TEŻ górą/dołem/ćwiartką
  ## (patrz `SnapEdge` w `types.nim`) -- a naciśnięcie kierunku
  ## PROSTOPADŁEGO do już aktywnego przyciągnięcia DOPRECYZOWUJE je do
  ## ćwiartki zamiast zastępować (patrz `combinedEdge` wyżej).
  let w = comp.findWindow(id)
  if w.isNil or not w.resizable: return
  ## Jeśli okno JUŻ jest przyciągnięte do DOKŁADNIE TEJ SAMEJ krawędzi,
  ## naciśnięcie TEGO SAMEGO skrótu przywraca oryginalny rozmiar (toggle),
  ## zamiast bezczynnie przyciągać "od nowa" do tego samego miejsca --
  ## intuicyjne zachowanie, którego użytkownik oczekuje po Super+Left,
  ## Super+Left. Naciśnięcie INNEGO kierunku (patrz `combinedEdge`) NIE
  ## jest traktowane jak "to samo" nawet jeśli finalna ćwiartka wychodzi
  ## identyczna z obecną -- to świadomy, bezpieczny wybór: nigdy nie
  ## cofa przypadkiem do niezaokrąglonego rozmiaru w reakcji na skrót,
  ## który wprost o to nie poprosił.
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
  let finalEdge = if w.maximized: combinedEdge(w.snapEdge, edge) else: edge
  let (pos, size) = comp.snapGeometry(finalEdge)
  w.pos = pos
  w.size = size
  w.maximized = true
  w.snapEdge = finalEdge
  comp.focus(id)

proc stepFocusForward(comp: Compositor, visible: seq[ZdeWindow]) =
  ## Wykonuje JEDEN krok Alt+Tab "w przód" na PRZEKAZANEJ, JUŻ
  ## POSORTOWANEJ liście widocznych okien (nie przelicza jej na nowo) --
  ## wydzielone z `cycleFocus` niżej właśnie po to, żeby dało się to
  ## wywołać WIELOKROTNIE na TEJ SAMEJ, stałej liście bez ponownego
  ## sortowania między wywołaniami -- patrz duży komentarz przy
  ## `cycleFocus` po to, dlaczego to jest kluczowe dla poprawności
  ## kierunku "wstecz".
  var idx = -1
  for i, w in visible:
    if w.id == comp.focusedId:
      idx = i
      break
  let nextIdx = (idx + 1) mod visible.len  # (idx=-1) -> 0, czyli najstarsze okno
  comp.focus(visible[nextIdx].id)

proc cycleFocus*(comp: Compositor, reverse = false) =
  ## Alt+Tab: przełącza focus na kolejne okno w kolejności z-order, TYLKO
  ## na aktualnym pulpicie (rozbudowa v0.1 "Aurora" -- pulpity wirtualne).
  ##
  ## Rozbudowa (runda 23): `reverse` (domyślnie `false`, więc KAŻDE
  ## dotychczasowe wywołanie `cycleFocus()` bez argumentu -- w tym
  ## wszystkie testy z rundy 21 -- zachowuje się DOKŁADNIE tak samo jak
  ## przed tą rundą) -- domyka realny brak: Shift+Alt+Tab (cykl WSTECZ)
  ## nie istniało w ogóle, mimo że to standard w praktycznie każdym
  ## menedżerze okien.
  ##
  ## PRAWDZIWY BŁĄD znaleziony podczas testowania (nie w tej wersji, w
  ## PIERWSZEJ próbie implementacji -- warto to tu zostawić jako
  ## ostrzeżenie dla przyszłych zmian w tym miejscu): naiwna
  ## implementacja "znajdź bieżący indeks ogniskowanego okna w
  ## POSORTOWANEJ liście, odejmij 1" WPADAŁA W PĘTLĘ między dwoma
  ## oknami i NIGDY nie docierała do pozostałych. Winny: `comp.focus()`
  ## PODNOSI zIndex ogniskowanego okna na wierzch -- więc "bieżący
  ## indeks" ogniskowanego okna jest PO KAŻDYM kroku, w PRZELICZONEJ NA
  ## NOWO liście, zawsze `len - 1` (ostatnia pozycja). Odejmowanie stałej
  ## "1" od stałej "len - 1" daje ZAWSZE tę samą docelową pozycję
  ## względną -- cofanie oscylowało w nieskończoność między tymi samymi
  ## dwoma oknami, nigdy nie docierając do reszty. Potwierdzone
  ## bezpośrednią obserwacją (`echo` po każdym kroku), nie domysłem.
  ##
  ## Poprawka wykorzystuje WŁASNOŚĆ MATEMATYCZNĄ cykli, zamiast łatać
  ## indeksowanie: "w przód" (`stepFocusForward` wyżej, sprawdzone
  ## osobnym testem regresyjnym) jest -- empirycznie potwierdzonym --
  ## STABILNYM cyklem o długości DOKŁADNIE `visible.len` (każde
  ## naciśnięcie odwiedza kolejne okno, wraca do punktu startowego
  ## dopiero po dokładnie tylu krokach, ile jest okien). Wykonanie kroku
  ## "w przód" `visible.len - 1` RAZY z rzędu, na TEJ SAMEJ, RAZ
  ## posortowanej liście (bez ponownego sortowania między krokami --
  ## stąd wydzielenie `stepFocusForward` powyżej), jest MATEMATYCZNIE
  ## RÓWNOWAŻNE jednemu krokowi w przeciwnym kierunku: N-1 kroków w
  ## cyklu o długości N zawsze ląduje dokładnie tam, gdzie wylądowałby
  ## jeden krok "wstecz". Nie trzeba osobnej logiki indeksowej dla
  ## kierunku wstecznego -- wystarczy reużyć logikę "w przód", której
  ## poprawność jest już ustalona, odpowiednią liczbę razy.
  var visible = comp.windows.filterIt(not it.minimized and it.workspace == comp.currentWorkspace)
  if visible.len == 0: return
  visible.sort(proc(a, b: ZdeWindow): int = cmp(a.zIndex, b.zIndex))
  if reverse:
    for _ in 0 ..< (visible.len - 1):
      comp.stepFocusForward(visible)
  else:
    comp.stepFocusForward(visible)

proc windowsInZOrder*(comp: Compositor): seq[ZdeWindow] =
  ## Zwraca widoczne okna NA AKTUALNYM PULPICIE, posortowane rosnąco po
  ## kolejności rysowania (rysować w tej kolejności, żeby ostatnie --
  ## najwyżej ułożone -- trafiło na wierzch). Okna z innych pulpitów
  ## (rozbudowa v0.1 "Aurora") są tak samo "niewidoczne" jak
  ## zminimalizowane -- to ten sam mechanizm ukrywania, tylko z innego
  ## powodu.
  ##
  ## Rozbudowa (runda 32, "przypnij na wierzchu"): sortowanie uwzględnia
  ## teraz DWA poziomy -- WSZYSTKIE nieprzypięte okna (posortowane
  ## między sobą po `zIndex`, jak zawsze), a PO NICH wszystkie przypięte
  ## (`alwaysOnTop`, też posortowane między sobą po `zIndex`) -- więc
  ## przypięte okno ZAWSZE ląduje na wierzchu listy (czyli rysuje się
  ## jako ostatnie/najwyższe), niezależnie od tego, jak duży `zIndex`
  ## zdążyło zebrać jakiekolwiek nieprzypięte okno. To WYŁĄCZNIE zmiana
  ## kolejności RYSOWANIA -- `zIndex` samych okien pozostaje nietknięty,
  ## więc `focus`/`cycleFocus`/`focusNextBestOnWorkspace` (patrz duży
  ## komentarz przy `alwaysOnTop` w `types.nim`) działają dokładnie tak
  ## samo jak przed tą rundą, bez żadnej wiedzy o przypinaniu.
  result = comp.windows.filterIt(not it.minimized and it.workspace == comp.currentWorkspace)
  result.sort(proc(a, b: ZdeWindow): int =
    if a.alwaysOnTop != b.alwaysOnTop:
      return cmp(a.alwaysOnTop, b.alwaysOnTop)  ## `false < true` -- nieprzypięte zawsze przed przypiętymi
    cmp(a.zIndex, b.zIndex))

proc toggleAlwaysOnTop*(comp: Compositor, id: int) =
  ## Rozbudowa (runda 32): przełącza przypięcie okna "na wierzchu".
  ## Świadomie NIE woła `comp.focus(id)` -- przypięcie/odpięcie okna nie
  ## powinno samo w sobie kraść fokusu innemu, akurat aktywnemu oknu
  ## (np. przypięcie odtwarzacza muzyki w tle, podczas pisania w innym
  ## oknie, nie powinno przenieść fokusu klawiatury na ten odtwarzacz).
  let w = comp.findWindow(id)
  if w.isNil: return
  w.alwaysOnTop = not w.alwaysOnTop

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

proc toggleShowDesktop*(comp: Compositor) =
  ## Rozbudowa (runda 28): "Pokaż pulpit" (konwencjonalnie Super+D) --
  ## domyka realny brak, obecny w praktycznie każdym DE. Minimalizuje
  ## WSZYSTKIE widoczne okna na BIEŻĄCYM pulpicie naraz; ponowne
  ## wywołanie przywraca DOKŁADNIE te same okna (i fokus sprzed
  ## wywołania) -- nie "wszystkie zminimalizowane okna", żeby okno, które
  ## użytkownik zminimalizował RĘCZNIE PRZED wywołaniem "Pokaż pulpit",
  ## zostało zminimalizowane -- to jest jedyny powód istnienia
  ## `showDesktopIds` (a nie po prostu "odminimalizuj wszystko").
  if comp.showDesktopActive:
    for id in comp.showDesktopIds:
      let w = comp.findWindow(id)
      if not w.isNil: w.minimized = false
    comp.showDesktopIds.setLen(0)
    comp.showDesktopActive = false
    ## Fokus wraca na to, co było ogniskowane PRZED "Pokaż pulpit" --
    ## ALE tylko jeśli to okno wciąż istnieje (mogło zostać zamknięte, w
    ## trakcie gdy pulpit był pokazany) i wciąż jest na TYM pulpicie
    ## (mogło zostać przeniesione gdzie indziej w międzyczasie) --
    ## `comp.focus` już samo w sobie jest bezpieczne na nieistniejące id
    ## (`findWindow` zwraca `nil`, `focus` po prostu nic wtedy nie robi),
    ## więc te dwa sprawdzenia to tylko dodatkowa jawność, nie wymóg
    ## bezpieczeństwa.
    let prev = comp.findWindow(comp.showDesktopPrevFocusedId)
    if not prev.isNil and not prev.minimized and prev.workspace == comp.currentWorkspace:
      comp.focus(prev.id)
  else:
    comp.showDesktopPrevFocusedId = comp.focusedId
    comp.showDesktopIds.setLen(0)
    for w in comp.windows:
      if not w.minimized and w.workspace == comp.currentWorkspace:
        comp.showDesktopIds.add(w.id)
        w.minimized = true
    comp.showDesktopActive = true
    comp.focusedId = 0  ## nic nie jest już widoczne na tym pulpicie -- fokus nie powinien "celować" w niewidoczne okno

proc moveWindowToWorkspace*(comp: Compositor, id: int, ws: int) =
  ## Przenosi okno na inny pulpit i OD RAZU przełącza na ten pulpit --
  ## tak, żeby użytkownik zobaczył efekt swojego skrótu (Ctrl+Alt+Shift+
  ## Left/Right), zamiast okno "znikało" mu z ekranu bez wyjaśnienia.
  let w = comp.findWindow(id)
  if w.isNil: return
  w.workspace = clamp(ws, 0, WorkspaceCount - 1)
  comp.switchWorkspace(w.workspace)
  ## Rozbudowa (runda 27): NAPRAWIONY BŁĄD, znaleziony przez uruchomienie
  ## kodu -- `comp.focusedId = id` był tu ustawiany BEZPOŚREDNIO, z
  ## pominięciem `comp.focus(id)`. Dla zwykłego (niezminimalizowanego)
  ## okna to nie robiło różnicy -- ale dla okna PRZENOSZONEGO W STANIE
  ## ZMINIMALIZOWANYM (można to zrobić np. z paska zadań, bez wcześniejszego
  ## przywracania) zostawiało `w.minimized == true` nietknięte, mimo że
  ## `comp.focusedId` już na nie wskazywał -- kompozytor "wierzył", że to
  ## okno ma fokus, a jednocześnie `windowsInZOrder()` (używane do
  ## rysowania) dalej je pomijało jako zminimalizowane, więc było
  ## niewidoczne mimo rzekomego fokusu. Potwierdzone bezpośrednim
  ## uruchomieniem PRZED naprawą: zminimalizuj okno, przenieś na inny
  ## pulpit -- `windowsInZOrder()` na nowym pulpicie zwracało 0 okien,
  ## mimo że `focusedId` wskazywało na to jedno, właśnie przeniesione.
  ## Naprawa: użycie `comp.focus(id)` (które i tak czyści `minimized`,
  ## dokładnie jak w `restoreWindow`) zamiast bezpośredniego przypisania
  ## -- przeniesienie zminimalizowanego okna na inny pulpit teraz też je
  ## PRZYWRACA, spójnie z tym, jak "przywróć i pokaż" działa wszędzie
  ## indziej w tym module.
  comp.focus(id)

proc setScreenSize*(comp: Compositor, size: Vec2) =
  ## Rozbudowa (runda 24): NAPRAWIONY BŁĄD, znaleziony przez uruchomienie
  ## kodu (nie przez czytanie) -- pierwsza wersja tej procedury (sprzed
  ## tej rundy, ale w praktyce ujawniona dopiero przez ćwiartki z rundy
  ## 21) traktowała KAŻDE zmaksymalizowane okno tak samo: rozciągała je
  ## na CAŁY nowy ekran (`size.x, size.y - TaskbarHeight`). To poprawne
  ## dla okna zmaksymalizowanego W CAŁOŚCI (`snapEdge == seNone`), ale
  ## BŁĘDNE dla okna przyciągniętego do POŁOWY albo ĆWIARTKI
  ## (`snapEdge != seNone`, `w.maximized == true` -- to jeden i ten sam
  ## fla ga dla obu przypadków, patrz `ZdeWindow` w `types.nim`) --
  ## zmiana rozdzielczości ekranu (np. podłączenie innego monitora) w
  ## PRAKTYCE gubiła snap: okno przyciągnięte do lewej połowy nagle
  ## zajmowało CAŁY nowy ekran, mimo że `snapEdge` wciąż formalnie mówił
  ## `seLeft`. Potwierdzone bezpośrednim uruchomieniem PRZED naprawą:
  ## okno 1920x1080 przyciągnięte do lewej połowy (960 szer.) po
  ## `setScreenSize(2560x1440)` miało szerokość 2560 -- CAŁY nowy ekran,
  ## nie 1280 (połowa nowego). Naprawa: gdy `snapEdge != seNone`,
  ## przelicz geometrię przez `snapGeometry` (tę samą funkcję, której
  ## używa `snapWindow`) względem NOWEGO rozmiaru ekranu, zamiast na
  ## sztywno rozciągać na cały ekran.
  comp.screenSize = size
  for w in comp.windows:
    if w.maximized:
      if w.snapEdge != seNone:
        let (pos, sz) = comp.snapGeometry(w.snapEdge)
        w.pos = pos
        w.size = sz
      else:
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
