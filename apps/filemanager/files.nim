import std/[os, algorithm, strutils, strformat, times, sequtils, re, osproc]
import fidget
import ../../comp/comp
import ../../shell/notifications
import ../../shell/state
import ./thumbnails

## Rozbudowa: prawdziwe operacje na plikach -- do tej pory ta aplikacja
## była WYŁĄCZNIE przeglądarką (README już to uczciwie nazywało
## "przeglądarką plików", nie "menedżerem") -- nawigacja po katalogach
## działała, ale nie dało się utworzyć folderu, zmienić nazwy, usunąć ani
## nawet OTWORZYĆ pliku (`lastClickTime`/`lastClickName` niżej istniały w
## typie od dawna, sugerując zamiar wykrywania podwójnego kliknięcia, ale
## nigdy nie były faktycznie odczytywane -- martwe pola). Ta rozbudowa
## domyka oba braki: podwójny klik na pliku otwiera go w edytorze tekstu
## (`openFile`, ustawiane przez `launchFileManager` w
## `shell/launcher_apps.nim` -- ten plik CELOWO nie importuje
## `launcher_apps.nim` wprost, żeby uniknąć cyklu importów, skoro to
## WŁAŚNIE `launcher_apps.nim` importuje `files.nim`, nie odwrotnie), a
## nowy folder/zmiana nazwy/usuwanie dostają proste, w pełni klikalne UI
## bez żadnego natywnego dialogu (Fidget go nie ma -- ten sam duch co
## reszta shellu, np. potwierdzenie usuwania alarmu w
## `apps/clock/clockapp.nim` to zwykły przycisk "×", bez pytania "na
## pewno?" -- tu, w przeciwieństwie do alarmu, USUWANIE PLIKU jest
## nieodwracalne, więc dostaje osobny mechanizm "uzbrojenia" -- patrz
## `pendingDeleteName`/`drawDeleteButton` niżej).

type
  EntryKind = enum ekDir, ekFile
  ## Rozbudowa (sortowanie listy): dotąd `refresh` sortowała na sztywno
  ## -- foldery przed plikami, potem alfabetycznie, bez wyjątku. Teraz to
  ## TYLKO sortowanie w ramach każdej z tych dwóch grup (foldery zawsze
  ## przed plikami -- ta konwencja zostaje, bo tak działa każdy realny
  ## menedżer plików, mieszanie ich wg rozmiaru/daty byłoby zaskakujące),
  ## a klucz sortowania w ramach grupy jest wybierany przyciskiem w
  ## toolbarze.
  SortMode = enum smName, smSize, smDate

  Entry = object
    name: string
    kind: EntryKind
    size: BiggestInt
    modified: Time

  FilesState* = ref object of RootObj
    cwd*: string
    entries: seq[Entry]
    ## Rozbudowa (zaznaczanie wielu wpisów): zwykły `seq[string]` zamiast
    ## dawnego pojedynczego `selected: string` -- listy w typowym
    ## katalogu są małe (dziesiątki, rzadko setki wpisów), więc liniowe
    ## `contains`/`keepItIf` na `seq` jest w pełni wystarczające i nie
    ## wymaga dokładania `std/sets` tylko dla tego jednego pola. Zwykłe
    ## kliknięcie (bez Ctrl) zawsze redukuje to do JEDNEGO elementu --
    ## więc stary kod, który zakładał "co najwyżej jedno zaznaczenie",
    ## nadal działa bez zmian koncepcyjnych, tylko przez `seq` z długością
    ## 0 albo 1.
    selectedSet: seq[string]
    ## Rozbudowa (Shift+klik -- zaznaczanie ciągłego zakresu): nazwa
    ## wpisu, od którego liczony jest zakres przy Shift+kliknięciu.
    ## Ustawiana na KAŻDYM zwykłym kliknięciu (bez modyfikatorów) --
    ## dokładnie tak zachowują się Nautilus/Dolphin/Eksplorator Windows:
    ## "kotwica" to zawsze ostatnie zwykłe kliknięcie, NIE ostatni
    ## Ctrl-klik ani koniec poprzedniego zakresu Shift. "" = brak kotwicy
    ## (jeszcze nic nie kliknięto zwykłym klikiem w tej sesji okna) --
    ## Shift+klik bez kotwicy po prostu zachowuje się jak zwykły klik.
    anchorName: string
    lastClickTime: float
    lastClickName: string
    errorMsg: string
    scrollOffset: float32  ## przesunięcie w pikselach listy plików (scroll kółkiem myszy)
    ## Rozbudowa (otwieranie plików): wołane z podwójnego kliknięcia na
    ## pliku, ze ścieżką bezwzględną. `nil`, dopóki `launchFileManager`
    ## (`shell/launcher_apps.nim`) go nie ustawi -- `newFileManager` samo
    ## w sobie nie wie nic o edytorze tekstu, więc bez ustawienia tego
    ## pola podwójny klik po prostu nic nie robi (patrz sprawdzenie
    ## `fs.openFile != nil` przy wołaniu), zamiast wywalić się na `nil`.
    openFile*: proc(path: string) {.closure.}
    ## Rozbudowa (operacje na plikach): stan kreatora "nowy folder" --
    ## ten sam wzorzec co pole ścieżki w `apps/texteditor/texteditor.nim`
    ## (`editableText`/`onInput` do bufora, osobny przycisk do faktycznego
    ## zatwierdzenia -- NIE zatwierdzamy na każde naciśnięcie klawisza,
    ## inaczej niż np. wyszukiwarka launchera, bo tworzenie folderu to
    ## akcja z efektem ubocznym na dysku, nie samo filtrowanie widoku).
    newFolderMode: bool
    newFolderName: string
    ## Rozbudowa (operacje na plikach): nazwa wpisu aktualnie w trybie
    ## zmiany nazwy -- "" oznacza "nikt". Tylko JEDEN wpis naraz może być
    ## edytowany (prostsze niż śledzenie trybu per-wiersz osobno, i tak
    ## realistyczne -- nikt nie zmienia nazw dwóch plików jednocześnie).
    renamingName: string
    renameBuffer: string
    ## Rozbudowa (operacje na plikach): "uzbrojone" usuwanie -- pierwszy
    ## klik ikony kosza dla danego wpisu USTAWIA to pole (zamiast od razu
    ## usuwać), drugi klik W TYM SAMYM MIEJSCU w ciągu `DeleteArmSeconds`
    ## faktycznie usuwa. Bez osobnego "tickera" -- wygaśnięcie liczone
    ## leniwie, przy każdym renderowaniu wiersza (`epochTime() -
    ## pendingDeleteAt`), ten sam styl co `formatAgo` w
    ## `shell/notifications.nim` liczący upływ czasu bez własnego zegara.
    pendingDeleteName: string
    pendingDeleteAt: float
    ## Rozbudowa (zbiorcze usuwanie): ten sam mechanizm "uzbrojenia" co
    ## `pendingDeleteName`/`pendingDeleteAt` wyżej, ale dla przycisku
    ## "Usuń" w pasku narzędzi działającego na CAŁYM `selectedSet` --
    ## osobne pole, bo `pendingDeleteName` to pojedyncza nazwa (dla ikony
    ## kosza PRZY WIERSZU), a tu zbrojone jest usunięcie WIELU wpisów
    ## naraz.
    pendingBulkDelete: bool
    pendingBulkDeleteAt: float
    ## Rozbudowa (sortowanie listy): patrz komentarz przy `SortMode`
    ## wyżej. Domyślne wartości (`smName`, `sortDesc = false`) odtwarzają
    ## DOKŁADNIE dotychczasowe, sztywne zachowanie -- żadne istniejące
    ## okno menedżera nie zmienia się wizualnie, dopóki ktoś świadomie
    ## nie kliknie przycisku sortowania.
    sortMode: SortMode
    sortDesc: bool
    ## Rozbudowa (historia nawigacji wstecz/dalej): ten sam wzorzec co
    ## historia przeglądarki -- `navBack` to stos katalogów, z których
    ## PRZYSZLIŚMY (najnowszy na końcu), `navForward` to stos katalogów,
    ## od których się cofnęliśmy (żeby "▶ Dalej" miało dokąd wrócić).
    ## Zwykła nawigacja (klik na folder, breadcrumb, "⬆ Wyżej") DOPISUJE
    ## do `navBack` i CZYŚCI `navForward` -- tak samo jak w każdej
    ## przeglądarce: pójście w NOWĄ stronę po cofnięciu się kasuje starą
    ## "przyszłość". Klik "◀ Wstecz"/"▶ Dalej" same w sobie NIE dopisują
    ## do `navBack` w zwykły sposób -- patrz `navigateBack`/
    ## `navigateForward` niżej.
    navBack: seq[string]
    navForward: seq[string]
    ## Rozbudowa (ukrywanie wg .gitignore): domyślnie `false` -- ta sama
    ## zasada co `useRegex`/`caseSensitive` w edytorze (patrz runda 14):
    ## nowa opcja nigdy nie zmienia domyślnego zachowania istniejących
    ## okien, dopóki użytkownik świadomie jej nie włączy przełącznikiem w
    ## toolbarze.
    hideIgnored: bool
    ## Rozbudowa (runda 19, wyszukiwanie plików): `searchOpen` pokazuje/
    ## chowa pasek wyszukiwania (przełącznik "🔍" w toolbarze, ten sam
    ## wzorzec co "📁+ Folder"). Wyszukiwanie NIE uruchamia się przy
    ## każdym naciśnięciu klawisza (w odróżnieniu od Znajdź w edytorze
    ## tekstu, gdzie `computeFindMatches` przelicza się co klatkę na
    ## treści JUŻ leżącej w pamięci) -- to rekurencyjne przeszukiwanie
    ## DYSKU, więc świadomie wymaga jawnego kliknięcia "Szukaj"/Enter
    ## (`searchResults`/`searchTruncated` trzymają wynik OSTATNIEGO
    ## uruchomienia, nie liczą się na bieżąco z `searchQuery`).
    searchOpen: bool
    searchQuery: string
    searchResults: seq[string]  ## bezwzględne ścieżki, wynik ostatniego wywołania `doSearch`
    searchTruncated: bool
    searchScrollOffset: float32  ## OSOBNE przewijanie od `scrollOffset` zwykłej listy -- to inny widok, nie powinny współdzielić pozycji

const DeleteArmSeconds = 4.0

## Rozbudowa v0.2 (schowek plików WSPÓLNY między oknami): do tej rundy
## `clipboardPaths`/`clipboardCut` były polami `FilesState` -- czyli
## realnie żyły w pamięci JEDNEGO okna menedżera plików (każde okno ma
## własną instancję `FilesState`, patrz `newFileManager` niżej). Skopiuj
## w oknie A, przełącz się do okna B, kliknij "Wklej" -- nic się nie
## działo, bo `fs` w oknie B miało swój własny, pusty `clipboardPaths`.
## To był jawnie wypisany brak w README (sekcja "Ograniczenia":
## "schowek plików ... żyje wyłącznie w pamięci JEDNEGO okna menedżera").
## Naprawa: przenieś oba pola na poziom modułu (`var` zamiast pól
## obiektu) -- Nim moduły są singletonami w obrębie procesu, więc każde
## okno menedżera odwołujące się do `gFileClipboard*` widzi TĘ SAMĄ
## pamięć. To NADAL nie jest prawdziwy schowek plików w stylu GNOME/KDE
## (wciąż brak integracji z `wl_data_device`, więc nie działa z
## aplikacjami spoza ZDE, i nie przeżywa restartu `zde-shell` -- oba te
## ograniczenia zostają, patrz README) -- ale "kopiuj w jednym oknie,
## wklej w drugim" (najczęstszy realny scenariusz posiadania dwóch okien
## menedżera otwartych naraz) teraz działa.
var
  gFileClipboardPaths: seq[string]
  gFileClipboardCut: bool  ## true = "Wytnij" (przenieś przy wklejeniu), false = "Kopiuj"

## **Runda 34** -- częściowe domknięcie jawnie wypisanego ograniczenia
## "schowek plików... wciąż jednak nie działa z aplikacjami spoza ZDE".
## Pełne rozwiązanie (prawdziwy typ MIME na `wl_data_device`, żeby
## APLIKACJE SPOZA ZDE mogły też WKLEJAĆ pliki DO ZDE) wymaga zmiany na
## poziomie KOMPOZYTORA (`wlcomp/seatext.nim`) -- to zostaje jako
## nieruszone ograniczenie architektoniczne, patrz README.
##
## To, co DA się zrobić z samego `zde-shell`, bez zmiany w kompozytorze:
## przy każdym "Kopiuj"/"Wytnij" wystawić listę skopiowanych ścieżek na
## SYSTEMOWY schowek (ten sam `wl-copy`/`xclip`, którego już używa
## `shell/clipboard.nim` do tekstu) jako `text/uri-list` -- standardowy
## typ MIME, którego GTK/Qt/Nautilus/Dolphin i inne aplikacje SPOZA ZDE
## nasłuchują przy wklejaniu plików. Efekt: "Kopiuj" w menedżerze plików
## ZDE, potem Ctrl+V w prawdziwym, zewnętrznym menedżerze plików (albo w
## oknie "Zapisz jako" dowolnej aplikacji obsługującej `text/uri-list`)
## TERAZ DZIAŁA -- jednokierunkowo (Z ZDE NA ZEWNĄTRZ), best-effort,
## dokładnie tym samym duchem co reszta integracji z zewnętrznymi
## narzędziami w tym projekcie (`quicksettings.nim`, `sound.nim`).
## Wklejanie plików SKOPIOWANYCH GDZIE INDZIEJ do wnętrza ZDE (kierunek
## odwrotny) WCIĄŻ nie działa -- to wymagałoby, żeby `zde-comp` sam
## obsługiwał `request_set_selection` dla tego typu MIME i eksponował go
## `zde-shell`, czego dziś architektura kompozytora nie robi.
proc copyFileUrisToClipboard(paths: seq[string]): bool =
  if paths.len == 0: return false
  ## `text/uri-list` wg RFC 2483: jeden URI na linię, zakończenia CRLF.
  var body = ""
  for p in paths:
    var absPath = p
    try: absPath = absolutePath(p)
    except ValueError: discard
    body.add("file://")
    body.add(absPath)
    body.add("\r\n")
  let wlCopy = findExe("wl-copy")
  let xclip = findExe("xclip")
  try:
    if wlCopy.len > 0:
      ## `wl-copy --type <mime>` -- flaga wspierana od dawna przez
      ## `wl-clipboard`, ten sam pakiet, który dostarcza już używane
      ## `wl-paste`.
      var p = startProcess(wlCopy, args = @["--type", "text/uri-list"], options = {poUsePath})
      p.inputStream.write(body)
      p.inputStream.close()
      discard p.waitForExit()
      p.close()
      return true
    if xclip.len > 0:
      var p = startProcess(xclip, args = @["-selection", "clipboard", "-t", "text/uri-list"], options = {poUsePath})
      p.inputStream.write(body)
      p.inputStream.close()
      discard p.waitForExit()
      p.close()
      return true
  except OSError, IOError:
    return false
  false  ## brak wl-copy/xclip -- cichy no-op, wewnętrzny schowek plików ZDE (gFileClipboardPaths) i tak działa niezależnie

## Rozbudowa (przeciąganie plików/folderów myszą): domyka kolejny jawnie
## wypisany brak z listy ograniczeń ("wciąż bez przeciągania plików myszą
## (drag & drop)"). Ten sam duch co schowek plików wyżej -- stan na
## poziomie MODUŁU (nie pola `FilesState`), bo przeciąganie z jednego
## okna menedżera i upuszczenie w DRUGIM otwartym oknie (różna `fs.cwd`)
## ma naturalnie działać, dokładnie jak "kopiuj w oknie A / wklej w
## oknie B" już działa dla schowka plików -- gdyby stan żył w polu
## instancji, upuszczenie w INNYM oknie nie miałoby jak się o nim
## dowiedzieć.
##
## Metoda dokładnie odtwarza już sprawdzony w projekcie wzorzec
## "przeciągania przez trzymanie" (`comp/drag.nim` dla okien,
## `SliderDragState`/`updateSliderDrag` w `shell/taskbar.nim` dla
## suwaków quick settings -- oba opisane w dużych komentarzach tam):
## `onMouseDown` na wierszu ZAPAMIĘTUJE start przeciągania (bez
## natychmiastowego przenoszenia), `updateFileDrag()` (wołane raz na
## klatkę z `shell/shell.nim`, obok analogicznych `compositor.updateDrag`/
## `updateSliderDrag`) sprawdza co klatkę, czy przycisk myszy wciąż jest
## trzymany, a `onHover` na wierszu FOLDERU (potencjalnego celu) ustawia
## `gFileDropTarget` na bezwzględną ścieżkę tego folderu -- gdy przycisk
## myszy zostanie puszczony NAD folderem, `updateFileDrag` wykonuje
## faktyczne przeniesienie.
##
## Świadomie POZA zakresem tej rozbudowy: brak przeciągania MIĘDZY ZDE a
## aplikacjami spoza niego (wymagałoby to integracji z
## `wl_data_device`/DND na poziomie kompozytora, czego architektura ZDE
## dziś nigdzie nie robi -- ten sam, już wcześniej udokumentowany
## kompromis co przy schowku plików, patrz komentarz przy
## `gFileClipboardPaths` wyżej).
##
## Rozbudowa (runda 14): domyka DWA punkty, które runda 13 świadomie
## zostawiła otwarte na tej liście -- (1) modyfikator
## Ctrl-przeciągnij-żeby-skopiować: `FileDragState.copyMode` zapisuje, czy
## Ctrl był trzymany w chwili PUSZCZENIA przycisku myszy (sprawdzane w
## `updateFileDrag`, NIE w chwili złapania pliku w `onMouseDown` -- ten
## pierwszy moment jest już zajęty przez Ctrl+klik do zaznaczania wielu
## wpisów, więc mieszanie tych dwóch znaczeń Ctrl w tym samym momencie
## przeciągania byłoby mylące). (2) przeciąganie FOLDERÓW, nie tylko
## plików -- ograniczone do sytuacji, w których zwykły klik na danym
## wierszu i tak NIE nawigowałby do środka (patrz `onMouseDown` niżej),
## żeby nie kolidować z istniejącym "klik na folder = wejdź".
type
  FileDragState = object
    active: bool
    sourceDir: string   ## `fs.cwd` okna, z którego wystartowało przeciąganie
    names: seq[string]  ## nazwy przeciąganych wpisów (względne, w `sourceDir`)
    ## Rozbudowa (runda 14): `true`, jeśli Ctrl był trzymany w chwili
    ## PUSZCZENIA przycisku myszy (sprawdzane i zapisywane w
    ## `updateFileDrag`, tuż przed wywołaniem `doDropMove`) -- decyduje,
    ## czy `doDropMove` ma SKOPIOWAĆ, czy PRZENIEŚĆ. Domyślne `false`
    ## (Nim zeruje pola `bool` do `false`) zachowuje dawne zachowanie
    ## rundy 13 -- zwykłe przeciąganie bez Ctrl nadal zawsze przenosi.
    copyMode: bool

var
  gFileDrag: FileDragState
  ## Bezwzględna ścieżka aktualnie najechanego folderu-celu -- żyje
  ## WYŁĄCZNIE przez jedną klatkę (ustawiana w `onHover` wiersza podczas
  ## rysowania okien, odczytywana i ZAWSZE zerowana na końcu w
  ## `updateFileDrag`, wołanym już PO narysowaniu wszystkich okien w tej
  ## samej klatce -- patrz kolejność w `shell/shell.nim`). Jeśli
  ## użytkownik w kolejnej klatce wciąż najeżdża na ten sam folder,
  ## `onHover` ustawi ją ponownie -- efekt jest ciągły dla oka (60x/s),
  ## mimo że sam stan technicznie "migocze" między klatkami.
  gFileDropTarget: string
  ## Sygnalizuje OTWARTYM oknom menedżera plików (dowolnym, nie tylko
  ## źródłowemu/docelowemu), że katalog, na który akurat patrzą, mógł się
  ## właśnie zmienić z zewnątrz (wskutek przeniesienia przez przeciąganie
  ## w INNYM oknie) -- `drawFileManager` sprawdza to na początku i
  ## odświeża się sam, jeśli `fs.cwd` się tu znajduje. Ten sam
  ## jednoklatkowy rytm życia co `gFileDropTarget` wyżej -- wypełniane w
  ## `doDropMove`, konsumowane/czyszczone w `updateFileDrag`.
  gDirsNeedingRefresh: seq[string]

proc humanSize(bytes: BiggestInt): string =
  const units = ["B", "KB", "MB", "GB", "TB"]
  var size = bytes.float
  var unit = 0
  while size >= 1024.0 and unit < units.high:
    size /= 1024.0
    inc unit
  if unit == 0:
    result = &"{bytes} {units[unit]}"
  else:
    result = &"{size:.1f} {units[unit]}"

## Rozbudowa (ukrywanie wg .gitignore) + **runda 34** (domknięcie dwóch
## punktów jawnie wypisanych jako "wciąż poza zakresem": wzorce ze
## ścieżką względną, zawierające `/` w środku, ORAZ wędrówka po
## katalogach nadrzędnych w poszukiwaniu dodatkowych `.gitignore`).
##
## Dwie osobne kategorie wzorca, rozróżniane tak jak w prawdziwym Gicie:
## - **wzorzec BEZ `/`** (poza końcowym, oznaczającym "tylko katalog") --
##   dopasowuje samą NAZWĘ wpisu, na DOWOLNEJ głębokości pod katalogiem,
##   w którym leży dany `.gitignore` (np. `*.log`, `node_modules`);
## - **wzorzec Z `/` w środku (albo zaczynający się od `/`)** -- jest
##   ZAKOTWICZONY: dopasowuje PEŁNĄ ścieżkę WZGLĘDEM katalogu, w którym
##   leży TEN `.gitignore` (np. `src/generated/`, `/build`).
##
## `*` (pojedyncza gwiazdka) NIE przekracza `/` (zgodnie ze
## specyfikacją -- `[^/]*`), `**` przekracza dowolną liczbę segmentów
## (`.*`) -- oba przypadki mają teraz osobną, poprawną obsługę zamiast
## wcześniejszego jednolitego traktowania `*`/`**` identycznie jako
## "cokolwiek".
proc gitignoreGlobToRegexStr(pattern: string, anchored: bool): string =
  result = "^"
  var i = 0
  while i < pattern.len:
    if anchored and pattern[i] == '*' and i + 1 < pattern.len and pattern[i+1] == '*':
      result.add(".*")
      inc i, 2
      continue
    case pattern[i]
    of '*': result.add(if anchored: "[^/]*" else: ".*")
    of '?': result.add(if anchored: "[^/]" else: ".")
    of '.', '+', '(', ')', '[', ']', '{', '}', '^', '$', '|', '\\':
      result.add('\\')
      result.add(pattern[i])
    else:
      result.add(pattern[i])
    inc i
  result.add("$")

type IgnorePattern = tuple[rx: Regex, dirOnly: bool, negate: bool, anchored: bool]
type GitignoreLevel = tuple[patterns: seq[IgnorePattern], anchorDir: string]

proc parseGitignoreFile(path: string): seq[IgnorePattern] =
  ## Parsuje JEDEN plik `.gitignore` -- wydzielone z dawnego
  ## `loadGitignorePatterns`, żeby dało się je wołać dla KAŻDEGO poziomu
  ## w `loadGitignoreChain` niżej, nie tylko dla jednego katalogu.
  try:
    for rawLine in lines(path):
      let line = rawLine.strip()
      if line.len == 0 or line.startsWith("#"): continue
      var pat = line
      var negate = false
      if pat.startsWith("!"):
        negate = true
        pat = pat[1 .. ^1]
      var dirOnly = false
      if pat.endsWith("/"):
        dirOnly = true
        pat = pat[0 ..< pat.len - 1]
      if pat.len == 0: continue
      var anchored = false
      if pat.startsWith("/"):
        anchored = true
        pat = pat[1 .. ^1]
      elif '/' in pat:
        anchored = true
      if pat.len == 0: continue
      try:
        result.add((re(gitignoreGlobToRegexStr(pat, anchored)), dirOnly, negate, anchored))
      except CatchableError:
        discard  ## pojedynczy nieparsowalny wzorzec nie wywala reszty pliku
  except CatchableError:
    discard  ## nieczytelny .gitignore (rzadkie, np. uprawnienia) -- po prostu nic nie ukrywamy

proc loadGitignorePatterns(dir: string): seq[IgnorePattern] =
  ## Zachowane dla wstecznej zgodności / prostych wywołań -- wzorce z
  ## `.gitignore` WYŁĄCZNIE z `dir` (bez rodziców). Nowy kod (od rundy
  ## 34) powinien wołać `loadGitignoreChain`, które to opakowuje i
  ## dokłada wędrówkę po rodzicach.
  let path = dir / ".gitignore"
  if not fileExists(path): return @[]
  parseGitignoreFile(path)

const MaxGitignoreParentWalk = 64  ## zabezpieczenie przed nieskończoną pętlą przy nietypowych systemach plików -- normalna głębokość to kilka-kilkanaście poziomów

proc loadGitignoreChain(startDir: string): seq[GitignoreLevel] =
  ## **Runda 34** -- domyka jawnie wypisany brak: dotąd sprawdzany był
  ## WYŁĄCZNIE `.gitignore` z `startDir` samego, nigdy z jego rodziców.
  ## Prawdziwy Git scala wzorce z CAŁEJ ścieżki od korzenia repo w dół --
  ## to wciąż nie jest to (nie wiemy, gdzie jest korzeń repo bez
  ## szukania `.git/`, i tego świadomie nie robimy tutaj), ale wędrówka
  ## PO WSZYSTKICH rodzicach aż do korzenia systemu plików (z limitem
  ## `MaxGitignoreParentWalk` jako siatką bezpieczeństwa) łapie
  ## zdecydowaną większość praktycznych przypadków: `.gitignore` w
  ## katalogu głównym repo, gdy przeglądamy jego PODKATALOG, nie tylko
  ## sam korzeń.
  ##
  ## Zwraca poziomy uporządkowane od NAJBARDZIEJ ZEWNĘTRZNEGO (bliżej
  ## korzenia systemu plików) do NAJBARDZIEJ WEWNĘTRZNEGO (`startDir`
  ## sam) -- `isGitignoredAt` iteruje w TEJ kolejności, więc bardziej
  ## specyficzny (bliższy) `.gitignore` naturalnie ma możliwość
  ## nadpisania decyzji zewnętrznego, tym samym mechanizmem "ostatni
  ## pasujący wygrywa", którego już używa `isGitignoredAt` w obrębie
  ## jednego pliku.
  var levels: seq[GitignoreLevel] = @[]
  var cur = try: absolutePath(startDir) except ValueError: startDir
  var steps = 0
  while steps < MaxGitignoreParentWalk:
    let path = cur / ".gitignore"
    if fileExists(path):
      levels.add((parseGitignoreFile(path), cur))
    let parent = parentDir(cur)
    if parent.len == 0 or parent == cur: break
    cur = parent
    inc steps
  ## odwracamy, żeby najbardziej ZEWNĘTRZNY poziom był pierwszy
  for i in countdown(levels.high, 0):
    result.add(levels[i])

proc isGitignoredAt(fullPath: string, isDir: bool, chain: seq[GitignoreLevel]): bool =
  ## Odpowiednik `isGitignored`, ale operujący na PEŁNEJ ścieżce i
  ## całym `chain` z `loadGitignoreChain` -- pozwala poprawnie dopasować
  ## zarówno wzorce po samej nazwie (jak dawniej), jak i, od rundy 34,
  ## wzorce ZAKOTWICZONE względem katalogu KONKRETNEGO `.gitignore`
  ## (patrz duży komentarz przy `gitignoreGlobToRegexStr` wyżej).
  let name = extractFilename(fullPath)
  if isDir and name == ".git": return true   ## patrz uzasadnienie w dawnym `isGitignored` -- bez zmian
  var ignored = false
  for level in chain:
    ## Wzorce zakotwiczone z TEGO poziomu dotyczą tylko wpisów
    ## faktycznie leżących pod jego katalogiem (zawsze prawda przy
    ## wędrówce w górę od `fullPath`, ale liczymy relPath bezpiecznie).
    var relPath = ""
    try: relPath = relativePath(fullPath, level.anchorDir)
    except ValueError: relPath = name
    for p in level.patterns:
      if p.dirOnly and not isDir: continue
      let target = if p.anchored: relPath else: name
      if target.match(p.rx):
        ignored = not p.negate
  ignored

proc isGitignored(name: string, isDir: bool, patterns: seq[IgnorePattern]): bool =
  ## Zachowane dla prostych, jednopoziomowych wywołań (bez wędrówki po
  ## rodzicach) -- dopasowuje TYLKO wzorce bez zakotwiczenia (po
  ## samej nazwie), bo bez pełnej ścieżki nie da się bezpiecznie
  ## dopasować wzorca zakotwiczonego. Nowy kod korzysta z
  ## `isGitignoredAt`/`loadGitignoreChain` (patrz wyżej), które
  ## obsługują OBA rodzaje wzorców poprawnie.
  if isDir and name == ".git": return true
  var ignored = false
  for p in patterns:
    if p.anchored: continue  ## bez pełnej ścieżki nie da się bezpiecznie dopasować -- patrz komentarz wyżej
    if p.dirOnly and not isDir: continue
    if name.match(p.rx):
      ignored = not p.negate
  ignored

const
  MaxSearchResults = 200   ## limit LICZBY TRAFIEŃ -- powyżej tego dalsze wyniki i tak przestają być praktycznie przeglądalne w jednym oknie
  MaxSearchScanned = 5000  ## limit liczby ODWIEDZONYCH WPISÓW (nie tylko trafień) -- zapobiega zawieszeniu na wielkich drzewach (np. przypadkowe wyszukiwanie od "/" albo "/usr")

proc searchFilesRecursive(root: string, query: string, hideIgnored: bool): tuple[results: seq[string], truncated: bool] =
  ## Rozbudowa (runda 19, wyszukiwanie plików): domyka brak, którego
  ## menedżer plików NIE MIAŁ W OGÓLE od pierwszej rundy -- żadnej formy
  ## szukania pliku po nazwie w poddrzewie katalogów, tylko ręczne
  ## przeklikiwanie się przez foldery. Rekurencyjny skan PO NAZWIE
  ## (prosty podciąg, case-insensitive -- bez glob/regex, świadomie
  ## prościej niż `.gitignore`/regex Znajdź w edytorze, bo to ma być
  ## szybkie "znajdź plik", nie potężne wyszukiwanie), z DWOMA
  ## niezależnymi zabezpieczeniami przed zawieszeniem na wielkim drzewie:
  ## `MaxSearchResults` (nie zbieraj więcej trafień, niż da się sensownie
  ## przejrzeć) i, ważniejsze, `MaxSearchScanned` (przestań skanować po
  ## odwiedzeniu tylu wpisów, NIEZALEŻNIE od tego, ile trafień znaleziono
  ## -- inaczej wyszukiwanie frazy z zerem trafień w ogromnym drzewie,
  ## np. przez pomyłkę uruchomione z "/", skanowałoby WSZYSTKO bez końca,
  ## zanim cokolwiek by zwróciło).
  ##
  ## Respektuje `.gitignore` na TYCH SAMYCH zasadach co zwykła lista
  ## katalogu (runda 15/18) -- ale patrz NAPRAWIONY BŁĄD niżej.
  ##
  ## NAPRAWIONY BŁĄD (wychwycony testem `test_file_search.nim`, nie przez
  ## czytanie kodu): pierwsza wersja woła `loadGitignorePatterns(dir)`
  ## OSOBNO na KAŻDYM poziomie rekursji, tak jak `refresh` robi to dla
  ## POJEDYNCZEGO katalogu -- co brzmi konsekwentnie, ale dla wyszukiwania
  ## REKURENCYJNEGO jest błędne: reguła `node_modules` zapisana w
  ## `.gitignore` w katalogu GŁÓWNYM w ogóle nie obejmowałaby pliku
  ## leżącego dwa poziomy niżej w podkatalogu, który sam nie ma WŁASNEGO
  ## `.gitignore` (`loadGitignorePatterns` dla TEGO podkatalogu zwraca
  ## po prostu pustą listę). Poprawka: wzorce są wczytywane RAZ, z
  ## katalogu, w którym wyszukiwanie się ZACZYNA (`root`), i stosowane
  ## jednolicie do WSZYSTKICH poziomów przeszukiwanego poddrzewa -- to
  ## wciąż nie jest pełna semantyka Gita (prawdziwy Git honorowałby też
  ## DODATKOWE, zagnieżdżone `.gitignore` głębiej w drzewie -- ten sam,
  ## świadomie mniejszy zakres co reszta tego mechanizmu, patrz komentarz
  ## przy `loadGitignorePatterns` wyżej), ale poprawnie obsługuje
  ## zdecydowanie najczęstszy przypadek: jeden `.gitignore` w korzeniu
  ## repo, obejmujący całe poddrzewo.
  if query.len == 0: return (@[], false)
  let q = query.toLowerAscii()
  var scanned = 0
  var results: seq[string] = @[]
  var truncated = false
  ## Runda 34: `loadGitignoreChain` zamiast pojedynczego
  ## `loadGitignorePatterns` -- dokłada wzorce z `.gitignore` W
  ## RODZICACH `root`, nie tylko z `root` samego, i pozwala poprawnie
  ## dopasować wzorce zakotwiczone (ze `/` w środku), patrz
  ## `isGitignoredAt`. Chain jest wczytywany RAZ (tak jak wcześniej
  ## patterns), nie na każdym poziomie rekursji -- ten sam, już wcześniej
  ## ustalony powód (patrz NAPRAWIONY BŁĄD w komentarzu poniżej).
  let chain = if hideIgnored: loadGitignoreChain(root) else: @[]

  proc walk(dir: string) =
    if truncated: return
    var entries: seq[tuple[name: string, path: string, isDir: bool]] = @[]
    try:
      for kind, path in walkDir(dir):
        let name = extractFilename(path)
        if name.len == 0: continue
        case kind
        of pcDir, pcLinkToDir:
          if hideIgnored and isGitignoredAt(path, true, chain): continue
          entries.add((name, path, true))
        of pcFile, pcLinkToFile:
          if hideIgnored and isGitignoredAt(path, false, chain): continue
          entries.add((name, path, false))
        else: discard
    except OSError:
      return
    for e in entries:
      if truncated: return
      inc scanned
      if scanned > MaxSearchScanned:
        truncated = true
        return
      if q in e.name.toLowerAscii():
        results.add(e.path)
        if results.len >= MaxSearchResults:
          truncated = true
          return
      if e.isDir:
        walk(e.path)

  walk(root)
  (results, truncated)

proc refresh(fs: FilesState) =
  fs.entries.setLen(0)
  fs.errorMsg = ""
  try:
    ## Runda 34: chain z rodzicami zamiast pojedynczego katalogu, patrz
    ## komentarz przy `loadGitignoreChain`.
    let chain = if fs.hideIgnored: loadGitignoreChain(fs.cwd) else: @[]
    for kind, path in walkDir(fs.cwd):
      let name = extractFilename(path)
      if name.len == 0: continue
      case kind
      of pcDir, pcLinkToDir:
        if fs.hideIgnored and isGitignoredAt(path, true, chain): continue
        var mt: Time
        try: mt = getLastModificationTime(path)
        except OSError: discard
        fs.entries.add(Entry(name: name, kind: ekDir, size: 0, modified: mt))
      of pcFile, pcLinkToFile:
        if fs.hideIgnored and isGitignoredAt(path, false, chain): continue
        var sz: BiggestInt = 0
        var mt: Time
        try:
          sz = getFileSize(path)
          mt = getLastModificationTime(path)
        except OSError:
          discard
        fs.entries.add(Entry(name: name, kind: ekFile, size: sz, modified: mt))
    ## Rozbudowa (sortowanie listy): foldery ZAWSZE przed plikami (ta
    ## konwencja zostaje niezmieniona, patrz komentarz przy `SortMode`
    ## wyżej) -- w ramach KAŻDEJ z tych dwóch grup osobno sortujemy wg
    ## `fs.sortMode`, z `fs.sortDesc` odwracającym TYLKO ten drugi,
    ## wewnątrzgrupowy klucz (kierunek "foldery przed plikami" jest
    ## ZAWSZE taki sam, niezależnie od `sortDesc` -- odwracanie TEGO
    ## byłoby zaskakujące, żaden realny menedżer plików tego nie robi).
    ## Nazwa jako klucz ZAWSZE jest case-insensitive (`toLowerAscii`) --
    ## zachowanie sprzed tej rundy, świadomie niezmienione nawet gdy
    ## `sortMode == smName` (to jedyny tryb, w którym kierunek dotyczy
    ## bezpośrednio litery, nie liczby/daty).
    fs.entries.sort(proc(a, b: Entry): int =
      if a.kind != b.kind:
        return (if a.kind == ekDir: -1 else: 1)
      let base = case fs.sortMode
        of smName: cmp(a.name.toLowerAscii, b.name.toLowerAscii)
        of smSize: cmp(a.size, b.size)
        of smDate: cmp(a.modified, b.modified)
      let primary = if fs.sortDesc: -base else: base
      if primary != 0: return primary
      cmp(a.name.toLowerAscii, b.name.toLowerAscii)  ## remis -> zawsze alfabetycznie, stabilna, przewidywalna kolejność
    )
  except OSError as e:
    fs.errorMsg = "Nie można odczytać katalogu: " & e.msg

proc newFileManager*(startDir = getHomeDir()): FilesState =
  result = FilesState(
    cwd: startDir.absolutePath().normalizedPath(),
    entries: @[],
    selectedSet: @[],
    lastClickTime: 0.0,
    lastClickName: "",
  )
  refresh(result)

proc navigateTo(fs: FilesState, path: string) =
  let normalized = path.absolutePath().normalizedPath()
  if dirExists(normalized) and normalized != fs.cwd:
    ## Rozbudowa (historia nawigacji): zwykła nawigacja (nie przez
    ## "◀ Wstecz"/"▶ Dalej", patrz te dwie procedury niżej) dopisuje
    ## STARY katalog do `navBack` i KASUJE `navForward` -- dokładnie jak w
    ## przeglądarce: pójście w nową stronę po cofnięciu się kasuje starą
    ## "przyszłość", bo nie jest już aktualna.
    fs.navBack.add(fs.cwd)
    fs.navForward.setLen(0)
    fs.cwd = normalized
    fs.selectedSet.setLen(0)
    fs.anchorName = ""  ## kotwica odnosi się do wpisów w STARYM katalogu -- w nowym jest bez sensu
    fs.scrollOffset = 0.0
    fs.renamingName = ""       ## zmiana katalogu porzuca niedokończone operacje --
    fs.pendingDeleteName = ""  ## kontynuowanie ich w NOWYM katalogu byłoby mylące
    fs.pendingBulkDelete = false
    refresh(fs)

proc navigateUp(fs: FilesState) =
  let parent = parentDir(fs.cwd)
  if parent.len > 0:
    navigateTo(fs, parent)

proc navigateBack(fs: FilesState) =
  ## Rozbudowa (historia nawigacji): w odróżnieniu od `navigateTo`, NIE
  ## dopisuje do `navBack` (cofałoby to samo siebie w nieskończoność) --
  ## zamiast tego zdejmuje ostatni wpis z `navBack` i przenosi BIEŻĄCY
  ## katalog na `navForward`, żeby "▶ Dalej" mogło wrócić.
  if fs.navBack.len == 0: return
  let target = fs.navBack.pop()
  if not dirExists(target): return  ## katalog mógł zniknąć z dysku w międzyczasie -- po cichu pomijamy, nie wywalamy się
  fs.navForward.add(fs.cwd)
  fs.cwd = target
  fs.selectedSet.setLen(0)
  fs.anchorName = ""
  fs.scrollOffset = 0.0
  fs.renamingName = ""
  fs.pendingDeleteName = ""
  fs.pendingBulkDelete = false
  refresh(fs)

proc navigateForward(fs: FilesState) =
  if fs.navForward.len == 0: return
  let target = fs.navForward.pop()
  if not dirExists(target): return
  fs.navBack.add(fs.cwd)
  fs.cwd = target
  fs.selectedSet.setLen(0)
  fs.anchorName = ""
  fs.scrollOffset = 0.0
  fs.renamingName = ""
  fs.pendingDeleteName = ""
  fs.pendingBulkDelete = false
  refresh(fs)

proc doSearch(fs: FilesState) =
  ## Wołane WYŁĄCZNIE z kliknięcia "Szukaj"/Enter (patrz komentarz przy
  ## `searchOpen` w `FilesState`) -- NIGDY co klatkę. Wynik zastępuje
  ## poprzedni w całości (nie doklejamy do starych wyników przy kolejnym
  ## wyszukiwaniu).
  let (results, truncated) = searchFilesRecursive(fs.cwd, fs.searchQuery, fs.hideIgnored)
  fs.searchResults = results
  fs.searchTruncated = truncated
  fs.searchScrollOffset = 0.0

proc jumpToSearchResult(fs: FilesState, path: string) =
  ## Klik na wynik wyszukiwania: nawiguje do KATALOGU NADRZĘDNEGO wyniku
  ## (przez `navigateTo`, więc historia wstecz/dalej z rundy 15 działa tu
  ## tak samo jak przy zwykłej nawigacji) i zaznacza sam wpis, żeby był
  ## od razu widoczny/wyróżniony -- zamyka pasek wyszukiwania, żeby
  ## użytkownik wylądował w zwykłym, znajomym widoku katalogu, nie
  ## utknął w widoku wyników.
  let dir = parentDir(path)
  let name = extractFilename(path)
  if dir.len == 0 or not dirExists(dir): return
  navigateTo(fs, dir)
  if name.len > 0 and (fileExists(path) or dirExists(path)):
    fs.selectedSet = @[name]
    fs.anchorName = name
  fs.searchOpen = false
  fs.searchQuery = ""
  fs.searchResults = @[]

proc breadcrumbParts(fs: FilesState): seq[tuple[label, path: string]] =
  ## Rozbija bieżącą ścieżkę na klikalne segmenty: / , home , user , docs...
  result = @[("/", "/")]
  var acc = ""
  for part in fs.cwd.split(DirSep):
    if part.len == 0: continue
    acc.add(DirSep & part)
    result.add((part, acc))

proc entryKind(fs: FilesState, name: string): EntryKind =
  ## Używane przez `doRename`/`doDelete` -- `os.moveFile`/`removeFile`
  ## działają tylko na plikach, katalogi potrzebują `moveDir`/`removeDir`.
  ## Brak dopasowania (wpis zniknął z listy między kliknięciem a
  ## wykonaniem, np. usunięty w międzyczasie z zewnątrz) domyślnie
  ## traktujemy jak plik -- to i tak zaraz zawiedzie na `fileExists`/
  ## `dirExists` wewnątrz `try` w wołającym, więc błąd i tak trafi do
  ## użytkownika przez `errorMsg`/`notify`, nie zniknie po cichu.
  for e in fs.entries:
    if e.name == name: return e.kind
  ekFile

proc entryIndex(fs: FilesState, name: string): int =
  ## Rozbudowa (Shift+klik): pozycja wpisu o danej nazwie w BIEŻĄCEJ,
  ## posortowanej liście (`fs.entries`, patrz `refresh`) -- potrzebna do
  ## policzenia zakresu "od kotwicy do kliknięcia". `-1`, gdy nazwa nie
  ## istnieje w liście (np. kotwica wskazywała na coś, co w międzyczasie
  ## usunięto/zmieniło nazwę z zewnątrz) -- wołający traktuje to jak brak
  ## kotwicy, nie jak błąd.
  for i, e in fs.entries:
    if e.name == name: return i
  -1

proc doCreateFolder(fs: FilesState) =
  let trimmed = fs.newFolderName.strip()
  fs.newFolderMode = false
  fs.newFolderName = ""
  if trimmed.len == 0: return
  let target = fs.cwd / trimmed
  try:
    createDir(target)
    notify("Utworzono folder", trimmed, nkInfo)
    refresh(fs)
  except OSError as e:
    fs.errorMsg = "Nie można utworzyć folderu \"" & trimmed & "\": " & e.msg
    notify("Błąd", fs.errorMsg, nkWarning)

proc doRename(fs: FilesState, oldName: string) =
  let trimmed = fs.renameBuffer.strip()
  fs.renamingName = ""
  if trimmed.len == 0 or trimmed == oldName: return
  let src = fs.cwd / oldName
  let dst = fs.cwd / trimmed
  if fileExists(dst) or dirExists(dst):
    fs.errorMsg = "Już istnieje: " & trimmed
    notify("Błąd zmiany nazwy", fs.errorMsg, nkWarning)
    return
  try:
    if entryKind(fs, oldName) == ekDir: moveDir(src, dst)
    else: moveFile(src, dst)
    if oldName in fs.selectedSet:
      fs.selectedSet.keepItIf(it != oldName)
      fs.selectedSet.add(trimmed)
    if fs.anchorName == oldName: fs.anchorName = trimmed
    notify("Zmieniono nazwę", oldName & " → " & trimmed, nkInfo)
    refresh(fs)
  except OSError as e:
    fs.errorMsg = "Nie można zmienić nazwy \"" & oldName & "\": " & e.msg
    notify("Błąd zmiany nazwy", fs.errorMsg, nkWarning)

proc doDelete(fs: FilesState, name: string) =
  fs.pendingDeleteName = ""
  let path = fs.cwd / name
  ## NAPRAWIONY BŁĄD (znaleziony podczas testowania tej rozbudowy, nie
  ## teoretycznie): `os.removeFile` w Nim CICHO NIC NIE ROBI dla
  ## nieistniejącego pliku -- nie rzuca `OSError`, po prostu zwraca. Bez
  ## tego jawnego sprawdzenia `fileExists`/`dirExists` PRZED próbą,
  ## usunięcie czegoś, co już zniknęło z dysku (np. usunięte z zewnątrz
  ## między odświeżeniem listy a kliknięciem), zgłosiłoby fałszywy
  ## sukces "Usunięto" -- `except OSError` nigdy by się nie uruchomił,
  ## bo nic by go nie wywołało.
  if not (fileExists(path) or dirExists(path)):
    fs.errorMsg = "Nie znaleziono \"" & name & "\" (być może już usunięty)"
    notify("Błąd usuwania", fs.errorMsg, nkWarning)
    fs.selectedSet.keepItIf(it != name)
    refresh(fs)
    return
  try:
    if entryKind(fs, name) == ekDir: removeDir(path)
    else: removeFile(path)
    fs.selectedSet.keepItIf(it != name)
    notify("Usunięto", name, nkInfo)
    refresh(fs)
  except OSError as e:
    fs.errorMsg = "Nie można usunąć \"" & name & "\": " & e.msg
    notify("Błąd usuwania", fs.errorMsg, nkWarning)

proc doBulkDelete(fs: FilesState) =
  ## Odpowiednik `doDelete`, ale dla CAŁEGO `selectedSet` naraz -- wołane
  ## z przycisku "Usuń" w pasku narzędzi po drugim kliknięciu (patrz
  ## `pendingBulkDelete` w typie `FilesState`). Usuwa co się da, a jeśli
  ## któryś wpis zawiedzie (np. katalog niepusty bez uprawnień do
  ## któregoś z plików wewnątrz, albo już nie istnieje -- patrz komentarz
  ## w `doDelete` wyżej o `removeFile` cicho nic nie robiącym dla
  ## brakującego pliku), NIE przerywa reszty -- zbiera liczbę
  ## sukcesów/porażek i melduje jedno zbiorcze podsumowanie zamiast
  ## zalewać powiadomieniami po jednym na plik.
  fs.pendingBulkDelete = false
  let names = fs.selectedSet
  var okCount = 0
  var failMsgs: seq[string] = @[]
  for name in names:
    let path = fs.cwd / name
    if not (fileExists(path) or dirExists(path)):
      failMsgs.add(name & ": już nie istnieje")
      continue
    try:
      if entryKind(fs, name) == ekDir: removeDir(path)
      else: removeFile(path)
      inc okCount
    except OSError as e:
      failMsgs.add(name & ": " & e.msg)
  fs.selectedSet.setLen(0)
  if okCount > 0:
    notify("Usunięto", $okCount & " " & (if okCount == 1: "wpis" else: "wpisów"), nkInfo)
  if failMsgs.len > 0:
    fs.errorMsg = "Nie udało się usunąć: " & failMsgs.join("; ")
    notify("Błąd usuwania", $failMsgs.len & " z " & $names.len & " się nie udało", nkWarning)
  refresh(fs)

proc doCopy(fs: FilesState, names: seq[string]) =
  ## "Kopiuj" -- tylko ZAZNACZA źródła w schowku plików (jako
  ## bezwzględne ścieżki -- `fs.cwd` może się zmienić zanim użytkownik
  ## faktycznie wklei), nic jeszcze nie kopiuje na dysku (dokładnie jak
  ## Ctrl+C w każdym innym menedżerze -- faktyczna operacja dysku dzieje
  ## się dopiero przy "Wklej", patrz `doPaste` niżej). Działa na CAŁYM
  ## `selectedSet` -- jeden albo wiele wpisów naraz, bez rozróżniania.
  gFileClipboardPaths = names.mapIt(fs.cwd / it)
  gFileClipboardCut = false
  discard copyFileUrisToClipboard(gFileClipboardPaths)  ## runda 34 -- best-effort, patrz komentarz przy funkcji

proc doCut(fs: FilesState, names: seq[string]) =
  gFileClipboardPaths = names.mapIt(fs.cwd / it)
  gFileClipboardCut = true
  discard copyFileUrisToClipboard(gFileClipboardPaths)  ## runda 34 -- best-effort, patrz komentarz przy funkcji

proc uniqueDestName(dir, baseName: string): string =
  ## Rozwiązuje kolizję nazw przy wklejaniu -- NAJCZĘSTSZY przypadek to
  ## wklejenie skopiowanego pliku z powrotem do TEGO SAMEGO katalogu
  ## (zwykłe "zduplikuj"), gdzie nazwa zawsze koliduje z oryginałem, ale
  ## ta sama logika obsługuje też przypadkową kolizję przy wklejaniu do
  ## innego katalogu. Zamiast pytać "nadpisać?" (czego i tak nie mamy jak
  ## zrobić bez natywnego dialogu -- patrz komentarz na górze pliku),
  ## dokładamy sufiks "(kopia)"/"(kopia 2)"/... aż trafimy na wolną nazwę
  ## -- ten sam mechanizm co "Zdjęcie (kopia).jpg" w Nautilusie/Dolphinie.
  let (_, name, ext) = splitFile(baseName)
  var candidate = dir / baseName
  if not (fileExists(candidate) or dirExists(candidate)): return candidate
  var n = 1
  while true:
    let suffix = if n == 1: " (kopia)" else: " (kopia " & $n & ")"
    candidate = dir / (name & suffix & ext)
    if not (fileExists(candidate) or dirExists(candidate)): return candidate
    inc n

proc doPaste(fs: FilesState) =
  ## Wkleja WSZYSTKIE ścieżki ze schowka (jedną albo wiele -- patrz
  ## `doCopy`/`doCut` wyżej). Podobnie jak `doBulkDelete`, kontynuuje
  ## mimo pojedynczych błędów (np. jedno ze źródeł zniknęło z dysku od
  ## czasu skopiowania) i melduje zbiorcze podsumowanie na końcu, zamiast
  ## przerywać na pierwszym niepowodzeniu.
  if gFileClipboardPaths.len == 0: return
  var okCount = 0
  var failMsgs: seq[string] = @[]
  for src in gFileClipboardPaths:
    let srcIsDir = dirExists(src)
    if not (srcIsDir or fileExists(src)):
      failMsgs.add(extractFilename(src) & ": źródło już nie istnieje")
      continue
    ## Zabezpieczenie przed wklejeniem folderu do samego siebie albo do
    ## własnego podkatalogu -- bez tego `copyDir`/`moveDir` wpadłyby w
    ## nieskończoną rekurencję (kopiowanie tworzyłoby własny cel wewnątrz
    ## samo siebie) albo w trudny do zrozumienia błąd systemowy.
    if srcIsDir and (fs.cwd == src or fs.cwd.startsWith(src & DirSep)):
      failMsgs.add(extractFilename(src) & ": nie można wkleić folderu do samego siebie")
      continue
    let dst = uniqueDestName(fs.cwd, extractFilename(src))
    try:
      if srcIsDir:
        if gFileClipboardCut: moveDir(src, dst)
        else: copyDir(src, dst)
      else:
        if gFileClipboardCut: moveFile(src, dst)
        else: copyFile(src, dst)
      inc okCount
    except OSError as e:
      failMsgs.add(extractFilename(src) & ": " & e.msg)

  if okCount > 0:
    notify((if gFileClipboardCut: "Przeniesiono" else: "Skopiowano"),
      $okCount & " " & (if okCount == 1: "wpis" else: "wpisów"), nkInfo)
  if failMsgs.len > 0:
    fs.errorMsg = "Nie udało się wkleić: " & failMsgs.join("; ")
    notify("Błąd wklejania", $failMsgs.len & " się nie udało", nkWarning)

  ## "Wytnij" jest jednorazowe -- po wklejeniu schowek się czyści,
  ## dokładnie jak przy Ctrl+X/Ctrl+V w innych menedżerach. "Kopiuj"
  ## NIE czyści schowka -- to samo źródło można wkleić wielokrotnie do
  ## kilku różnych miejsc, tak samo jak ze zwykłym schowkiem tekstowym.
  if gFileClipboardCut: gFileClipboardPaths.setLen(0)
  refresh(fs)

proc doDropMove(sourceDir: string, names: seq[string], destDir: string, copyMode = false) =
  ## Wykonuje faktyczne przeniesienie (albo, od rundy 14, kopiowanie --
  ## patrz `copyMode`) po upuszczeniu (patrz `updateFileDrag` niżej) --
  ## bardzo podobne do `doPaste` wyżej (ten sam `uniqueDestName` przy
  ## kolizji nazw, to samo pomijanie źródeł, które w międzyczasie
  ## zniknęły z dysku, ta sama ochrona przed wklejeniem/przeniesieniem
  ## folderu do samego siebie/własnego podkatalogu). NIE dotyka
  ## globalnego schowka plików (`gFileClipboardPaths`/`gFileClipboardCut`)
  ## -- to zupełnie osobny mechanizm, przeciąganie nie "zużywa" ani nie
  ## nadpisuje tego, co ewentualnie leży w schowku ze zwykłego
  ## Kopiuj/Wytnij.
  ##
  ## `copyMode` domyślnie `false` (PRZENOSI, dokładnie jak w rundzie 13 --
  ## zwykłe przeciąganie bez Ctrl zachowuje się identycznie jak wcześniej)
  ## -- `true`, gdy Ctrl był trzymany w chwili puszczenia przycisku myszy
  ## (ustalane w `updateFileDrag`, patrz komentarz przy `FileDragState`
  ## wyżej), używa `copyFile`/`copyDir` zamiast `moveFile`/`moveDir`, ten
  ## sam dobór procedur co już sprawdzony w `doPaste`.
  if names.len == 0 or destDir == sourceDir: return
  var okCount = 0
  var failMsgs: seq[string] = @[]
  for name in names:
    let src = sourceDir / name
    if not (fileExists(src) or dirExists(src)):
      failMsgs.add(name & ": źródło już nie istnieje")
      continue
    if dirExists(src) and (destDir == src or destDir.startsWith(src & DirSep)):
      failMsgs.add(name & ": nie można " & (if copyMode: "skopiować" else: "przenieść") &
        " folderu do samego siebie")
      continue
    let dst = uniqueDestName(destDir, name)
    try:
      if dirExists(src):
        if copyMode: copyDir(src, dst)
        else: moveDir(src, dst)
      else:
        if copyMode: copyFile(src, dst)
        else: moveFile(src, dst)
      inc okCount
    except OSError as e:
      failMsgs.add(name & ": " & e.msg)
  if okCount > 0:
    notify((if copyMode: "Skopiowano" else: "Przeniesiono"),
      $okCount & " " & (if okCount == 1: "wpis" else: "wpisów") &
      " do " & extractFilename(destDir), nkInfo)
  if failMsgs.len > 0:
    notify((if copyMode: "Błąd kopiowania" else: "Błąd przenoszenia"),
      $failMsgs.len & " z " & $names.len & " się nie udało", nkWarning)
  ## Sygnalizuje WSZYSTKIM otwartym oknom menedżera plików (patrz duży
  ## komentarz przy `gDirsNeedingRefresh` wyżej), że katalog źródłowy I
  ## docelowy mogły się zmienić -- na wypadek, gdyby to były dwa RÓŻNE,
  ## akurat otwarte okna, oba odświeżą swoją listę automatycznie, bez
  ## czekania na ręczne "Odśwież".
  if sourceDir notin gDirsNeedingRefresh: gDirsNeedingRefresh.add(sourceDir)
  if destDir notin gDirsNeedingRefresh: gDirsNeedingRefresh.add(destDir)

proc updateFileDrag*() =
  ## Wołane raz na klatkę z `shell/shell.nim` (`drawMain`), obok
  ## analogicznych `compositor.updateDrag`/`updateSliderDrag` -- ten sam
  ## sprawdzony wzorzec "zapamiętaj przy wciśnięciu (`onMouseDown` na
  ## wierszu pliku, patrz `drawFileManager` niżej), sprawdzaj co klatkę,
  ## dopóki przycisk myszy jest trzymany, wykonaj przy puszczeniu".
  if not gFileDrag.active:
    gFileDropTarget = ""
    return
  if not mouse.down:
    if gFileDropTarget.len > 0:
      ## Rozbudowa (runda 14): Ctrl sprawdzany TERAZ, w chwili puszczenia
      ## przycisku myszy -- NIE w chwili złapania pliku w `onMouseDown`
      ## (ten moment jest już zajęty przez Ctrl+klik do zaznaczania wielu
      ## wpisów, patrz komentarz przy `FileDragState` wyżej). Użytkownik
      ## może więc np. zacząć przeciąganie bez Ctrl, a doszczypnąć Ctrl
      ## dopiero tuż przed upuszczeniem, żeby zmienić zamiar na "kopiuj"
      ## -- naturalne zachowanie, znane z innych menedżerów plików.
      let copyMode = buttonDown[LEFT_CONTROL] or buttonDown[RIGHT_CONTROL]
      doDropMove(gFileDrag.sourceDir, gFileDrag.names, gFileDropTarget, copyMode)
    gFileDrag = FileDragState(active: false)
  ## `gFileDropTarget` żyje tylko JEDNĄ klatkę -- patrz komentarz przy
  ## jego deklaracji wyżej -- zerowane bezwarunkowo na końcu, niezależnie
  ## od tego, czy przycisk myszy akurat został puszczony, czy nie.
  gFileDropTarget = ""

# --- Rysowanie ------------------------------------------------------------

proc drawFileManager*(fs: FilesState, win: ZdeWindow) =
  ## Rozbudowa (przeciąganie plików/folderów myszą): jeśli przeniesienie
  ## przez przeciąganie (w TYM oknie lub w INNYM oknie menedżera, patrz
  ## `doDropMove`/`gDirsNeedingRefresh`) dotknęło katalogu, na który akurat
  ## patrzy TO okno, odśwież jego listę automatycznie -- bez tego drugie,
  ## otwarte akurat na katalogu DOCELOWYM okno pokazywałoby przestarzałą
  ## listę aż do ręcznego "Odśwież" albo zmiany katalogu.
  if fs.cwd in gDirsNeedingRefresh:
    refresh(fs)

  let toolbarH = 32.0'f32
  let breadcrumbH = 26.0'f32
  let rowH = 24.0'f32
  let pad = 6.0'f32
  ## Rozbudowa (nowy folder): drugi, opcjonalny pasek pod breadcrumbem --
  ## obecny TYLKO gdy `fs.newFolderMode`, więc nie zabiera stale miejsca
  ## listie plików w typowym przypadku przeglądania.
  let newFolderBarH = if fs.newFolderMode: 30.0'f32 else: 0.0'f32
  ## Rozbudowa (runda 19, wyszukiwanie plików): trzeci, opcjonalny pasek
  ## -- ten sam wzorzec co `newFolderBarH` wyżej, obecny TYLKO gdy
  ## `fs.searchOpen`. Zawiera pole zapytania + przycisk "Szukaj" +
  ## licznik wyników, WYŻSZY niż pasek nowego folderu (36 vs 30px), bo
  ## mieści też licznik/komunikat "obcięto" pod polem wejściowym.
  let searchBarH = if fs.searchOpen: 36.0'f32 else: 0.0'f32
  let listTop = toolbarH + breadcrumbH + newFolderBarH + searchBarH

  ## Rozbudowa (skróty klawiszowe): Delete/Ctrl+A/Escape/F2 -- tylko gdy
  ## TO okno jest aktywne (`win.id == compositor.focusedId`, ten sam
  ## sprawdzony sposób co podświetlanie ramki w `shell/chrome.nim`) i
  ## użytkownik nie jest akurat w trakcie wpisywania nazwy (zmiana nazwy
  ## albo nowy folder) -- bez tej drugiej blokady np. Delete skasowałby
  ## zaznaczenie w trakcie pisania nazwy nowego pliku, co byłoby mylące.
  ## `buttonPress[...]` (nie `buttonDown`) -- zdarzenie "wciśnięto W TEJ
  ## KLATCE", więc trzymanie klawisza nie powtarza akcji bez końca.
  let isFocused = win.id == compositor.focusedId
  ## Rozbudowa (runda 19, wyszukiwanie plików): `fs.searchOpen` dołączone
  ## do `editingText` -- z tego samego powodu co `newFolderMode`: bez
  ## tego Delete/Ctrl+A/F2 działałyby "przez" pole wyszukiwania (np.
  ## Delete skasowałoby zaznaczenie z POPRZEDNIEGO widoku katalogu, mimo
  ## że użytkownik akurat pisze zapytanie, co byłoby mylące).
  let editingText = fs.renamingName.len > 0 or fs.newFolderMode or fs.searchOpen
  ## Escape zamyka pasek wyszukiwania -- CELOWO OSOBNY blok, POZA `not
  ## editingText` niżej (skoro `fs.searchOpen` właśnie WCHODZI w skład
  ## `editingText`, Escape musi mieć możliwość zadziałania MIMO tego, że
  ## `editingText` jest `true` -- inaczej sam siebie by zablokował: nie
  ## dałoby się zamknąć paska klawiszem, tylko drugim kliknięciem "🔍").
  if isFocused and fs.searchOpen and buttonPress[ESCAPE]:
    fs.searchOpen = false
    fs.searchQuery = ""
    fs.searchResults = @[]
  ## Enter w polu wyszukiwania uruchamia szukanie -- ten sam gest co
  ## "Enter = szukaj dalej" w pasku Znajdź edytora tekstu (choć tu Enter
  ## URUCHAMIA skan od zera, nie skacze do kolejnego wyniku -- to inny
  ## rodzaj operacji, patrz duży komentarz przy `searchOpen` w
  ## `FilesState` o tym, dlaczego wyszukiwanie NIE dzieje się na bieżąco
  ## przy każdym znaku).
  if isFocused and fs.searchOpen and buttonPress[ENTER] and fs.searchQuery.len > 0:
    doSearch(fs)
  if isFocused and not editingText:
    if fs.selectedSet.len > 0 and buttonPress[DELETE]:
      let armed = fs.pendingBulkDelete and
        (epochTime() - fs.pendingBulkDeleteAt) < DeleteArmSeconds
      if armed:
        doBulkDelete(fs)
      else:
        ## Ten sam mechanizm "uzbrojenia" co klik myszą w przycisk "Usuń"
        ## -- pierwsze Delete zbroi (przycisk w toolbarze pokaże "Na
        ## pewno? (N)"), DRUGIE Delete w ciągu `DeleteArmSeconds`
        ## faktycznie usuwa. Nieodwracalna operacja nie powinna nigdy
        ## wykonać się po jednym przypadkowym naciśnięciu klawisza.
        fs.pendingBulkDelete = true
        fs.pendingBulkDeleteAt = epochTime()
    if (buttonDown[LEFT_CONTROL] or buttonDown[RIGHT_CONTROL]) and buttonPress[LETTER_A]:
      ## Ctrl+A -- zaznacza WSZYSTKO w bieżącym katalogu, tak jak wszędzie
      ## indziej. Kotwica (`anchorName`) celowo NIE jest tu ustawiana --
      ## po Ctrl+A nie ma jednoznacznego "od którego wpisu zacząć" dla
      ## późniejszego Shift+kliknięcia, więc zostawiamy starą kotwicę
      ## (albo jej brak); pierwsze zwykłe kliknięcie i tak ją nadpisze.
      fs.selectedSet = fs.entries.mapIt(it.name)
    if buttonPress[ESCAPE]:
      ## Anuluje zaznaczenie i wszelkie "uzbrojone", ale niedokończone
      ## operacje -- czysty gest "cofnij się o krok", bez zamykania okna
      ## (za zamknięcie okna odpowiada `shell/chrome.nim`, osobno).
      fs.selectedSet.setLen(0)
      fs.pendingBulkDelete = false
      fs.pendingDeleteName = ""
    if buttonPress[F2] and fs.selectedSet.len == 1:
      ## F2 -- ten sam skrót co w Nautilusie/Dolphinie/Eksploratorze,
      ## wchodzi w tryb zmiany nazwy DOKŁADNIE JEDNEGO zaznaczonego wpisu
      ## (nieoznaczone przy wielu zaznaczonych -- zmiana nazwy działa
      ## tylko na jednym wpisie naraz, patrz `doRename`).
      let target = fs.selectedSet[0]
      fs.renamingName = target
      fs.renameBuffer = target

  frame "files-root":
    box 0, 0, win.size.x, win.size.y
    fill "#15181c"

    # Pasek narzędzi: "w górę" + odśwież + nowy folder
    group "toolbar":
      box 0, 0, win.size.x, toolbarH
      fill "#1d2126"

      ## Rozbudowa (historia nawigacji wstecz/dalej): ten sam wzorzec co
      ## przycisk "wstecz" w każdej przeglądarce -- wyszarzony/nieaktywny
      ## (fill ciemniejszy, klik nic nie robi), gdy odpowiedni stos
      ## historii jest pusty, żeby od razu było widać, że nie ma dokąd
      ## wrócić/pójść dalej, bez klikania "na spróbowanie".
      let canGoBack = fs.navBack.len > 0
      let canGoForward = fs.navForward.len > 0
      group "nav-back-btn":
        box pad, 4, 30, toolbarH - 8
        fill (if canGoBack: "#2a2f36" else: "#202429")
        cornerRadius 4
        onHover:
          if canGoBack: fill "#3a4048"
        onClick:
          if canGoBack: navigateBack(fs)
        text "nav-back-label":
          box 0, 0, 30, toolbarH - 8
          font "sans-serif", 13, 700, toolbarH - 8, hCenter, vCenter
          fill (if canGoBack: "#e6e6e6" else: "#5b6470")
          characters "◀"

      group "nav-forward-btn":
        box pad + 30 + 4, 4, 30, toolbarH - 8
        fill (if canGoForward: "#2a2f36" else: "#202429")
        cornerRadius 4
        onHover:
          if canGoForward: fill "#3a4048"
        onClick:
          if canGoForward: navigateForward(fs)
        text "nav-forward-label":
          box 0, 0, 30, toolbarH - 8
          font "sans-serif", 13, 700, toolbarH - 8, hCenter, vCenter
          fill (if canGoForward: "#e6e6e6" else: "#5b6470")
          characters "▶"

      let navBtnsW = 30 + 4 + 30 + pad  ## szerokość zajęta przez dwa przyciski historii wyżej + odstęp przed "⬆ Wyżej"

      group "up-btn":
        box pad + navBtnsW, 4, 64, toolbarH - 8
        ## Rozbudowa (przeciąganie plików/folderów myszą): "⬆ Wyżej"
        ## przyjmuje upuszczone pliki tak samo jak wiersz folderu w
        ## liście -- przenosi je do katalogu NADRZĘDNEGO, bez potrzeby
        ## najpierw ręcznie tam nawigować.
        let parentIsDropTarget = gFileDrag.active and gFileDropTarget == parentDir(fs.cwd)
        fill (if parentIsDropTarget: "#2d6b48" else: "#2a2f36")
        cornerRadius 4
        onHover:
          fill "#3a4048"
          if gFileDrag.active and parentDir(fs.cwd).len > 0:
            gFileDropTarget = parentDir(fs.cwd)
        onClick: navigateUp(fs)
        text "up-label":
          box 0, 0, 64, toolbarH - 8
          font "sans-serif", 12, 600, toolbarH - 8, hCenter, vCenter
          fill "#e6e6e6"
          characters "⬆ Wyżej"

      group "refresh-btn":
        box pad * 2 + navBtnsW + 64, 4, 90, toolbarH - 8
        fill "#2a2f36"
        cornerRadius 4
        onHover: fill "#3a4048"
        onClick: refresh(fs)
        text "refresh-label":
          box 0, 0, 90, toolbarH - 8
          font "sans-serif", 12, 600, toolbarH - 8, hCenter, vCenter
          fill "#e6e6e6"
          characters "⟳ Odśwież"

      ## Rozbudowa (nowy folder): przełącznik paska kreatora poniżej --
      ## drugi klik (gdy pasek już otwarty) go zamyka, tak samo jak
      ## przyciski launchera/quick settings w `shell/taskbar.nim`.
      group "new-folder-toggle-btn":
        box pad * 3 + navBtnsW + 64 + 90, 4, 96, toolbarH - 8
        fill (if fs.newFolderMode: "#2d5f8a" else: "#2a2f36")
        cornerRadius 4
        onHover:
          if not fs.newFolderMode: fill "#3a4048"
        onClick:
          fs.newFolderMode = not fs.newFolderMode
          fs.newFolderName = ""
        text "new-folder-toggle-label":
          box 0, 0, 96, toolbarH - 8
          font "sans-serif", 12, 600, toolbarH - 8, hCenter, vCenter
          fill "#e6e6e6"
          characters "📁+ Folder"

      ## Rozbudowa (sortowanie listy): jeden przycisk cyklujący klucz
      ## (Nazwa -> Rozmiar -> Data -> Nazwa...) + osobny, wąski przycisk
      ## kierunku (▲ rosnąco / ▼ malejąco) -- rozdzielone na dwa przyciski
      ## zamiast jednego "cyklującego wszystko", żeby zmiana kierunku nie
      ## wymagała przeklikiwania się przez wszystkie trzy klucze z powrotem.
      let sortBaseX = pad * 4 + navBtnsW + 64 + 90 + 96
      let sortModeLabel = case fs.sortMode
        of smName: "Nazwa"
        of smSize: "Rozmiar"
        of smDate: "Data"
      group "sort-mode-btn":
        box sortBaseX, 4, 74, toolbarH - 8
        fill "#2a2f36"
        cornerRadius 4
        onHover: fill "#3a4048"
        onClick:
          fs.sortMode = case fs.sortMode
            of smName: smSize
            of smSize: smDate
            of smDate: smName
          refresh(fs)
        text "sort-mode-label":
          box 0, 0, 74, toolbarH - 8
          font "sans-serif", 12, 600, toolbarH - 8, hCenter, vCenter
          fill "#e6e6e6"
          characters "↕ " & sortModeLabel

      group "sort-dir-btn":
        box sortBaseX + 74 + 4, 4, 26, toolbarH - 8
        fill "#2a2f36"
        cornerRadius 4
        onHover: fill "#3a4048"
        onClick:
          fs.sortDesc = not fs.sortDesc
          refresh(fs)
        text "sort-dir-label":
          box 0, 0, 26, toolbarH - 8
          font "sans-serif", 12, 700, toolbarH - 8, hCenter, vCenter
          fill "#e6e6e6"
          characters (if fs.sortDesc: "▼" else: "▲")

      ## Rozbudowa (ukrywanie wg .gitignore): zwykły przełącznik (kolor
      ## akcentu, gdy włączony) -- ten sam wzorzec wizualny co "Aa"/".*"
      ## w pasku Znajdź edytora tekstu (runda 14).
      group "gitignore-toggle-btn":
        box sortBaseX + 74 + 4 + 26 + pad, 4, 40, toolbarH - 8
        fill (if fs.hideIgnored: "#2d5f8a" else: "#2a2f36")
        cornerRadius 4
        onHover:
          if not fs.hideIgnored: fill "#3a4048"
        onClick:
          fs.hideIgnored = not fs.hideIgnored
          refresh(fs)
        text "gitignore-toggle-label":
          box 0, 0, 40, toolbarH - 8
          font "sans-serif", 12, 700, toolbarH - 8, hCenter, vCenter
          fill (if fs.hideIgnored: "#ffffff" else: "#8a94a3")
          characters ".gi"

      ## Rozbudowa (runda 19, wyszukiwanie plików): przełącznik "🔍" --
      ## domyka brak, którego menedżer plików NIE MIAŁ W OGÓLE (żadnej
      ## formy szukania po nazwie w poddrzewie). Zamknięcie paska
      ## (drugi klik) czyści zapytanie i wyniki -- ten sam "drugi klik
      ## zamyka" wzorzec co "📁+ Folder" wyżej.
      let searchBtnX = sortBaseX + 74 + 4 + 26 + pad + 40 + pad
      group "search-toggle-btn":
        box searchBtnX, 4, 40, toolbarH - 8
        fill (if fs.searchOpen: "#2d5f8a" else: "#2a2f36")
        cornerRadius 4
        onHover:
          if not fs.searchOpen: fill "#3a4048"
        onClick:
          fs.searchOpen = not fs.searchOpen
          if not fs.searchOpen:
            fs.searchQuery = ""
            fs.searchResults = @[]
        text "search-toggle-label":
          box 0, 0, 40, toolbarH - 8
          font "sans-serif", 13, 700, toolbarH - 8, hCenter, vCenter
          fill (if fs.searchOpen: "#ffffff" else: "#8a94a3")
          characters "🔍"

      ## Rozbudowa (kopiuj/wytnij/wklej/usuń zbiorczo): wyrównane do
      ## PRAWEJ krawędzi paska narzędzi (nie doklejone za "Nowy folder"
      ## po lewej) -- ten sam powód co `rightZoneX` w
      ## `shell/taskbar.nim`: prawa strona zostaje na swoim miejscu
      ## niezależnie od szerokości okna (menedżer plików jest domyślnie
      ## zmieniany rozmiarowo), zamiast rozjeżdżać się przy każdej
      ## zmianie rozmiaru. Działają na `fs.selectedSet` -- OD rozbudowy
      ## "zaznaczanie wielu wpisów" (Ctrl+klik w wierszu, patrz niżej)
      ## może to być więcej niż jeden wpis naraz, nie wymagają osobnych
      ## ikon w każdym wierszu.
      let hasSelection = fs.selectedSet.len > 0
      let hasClipboard = gFileClipboardPaths.len > 0
      let deleteArmed = fs.pendingBulkDelete and
        (epochTime() - fs.pendingBulkDeleteAt) < DeleteArmSeconds
      let pasteW = if hasClipboard and gFileClipboardPaths.len > 1: 84.0'f32 else: 70.0'f32
      let cutW = 62.0'f32
      let copyW = 74.0'f32
      let deleteW = if deleteArmed: 100.0'f32 else: 62.0'f32
      let btnGap = 6.0'f32
      let pasteX = win.size.x - pad - pasteW
      let cutX = pasteX - btnGap - cutW
      let copyX = cutX - btnGap - copyW
      let deleteX = copyX - btnGap - deleteW

      ## "Usuń" (zbiorczo) -- ten sam mechanizm "uzbrojenia" co ikona 🗑
      ## przy pojedynczym wierszu (patrz `pendingDeleteName` niżej): klik
      ## nie usuwa od razu, tylko zbroi na `DeleteArmSeconds`, w trakcie
      ## których przycisk zmienia kolor/etykietę na "Na pewno? (N)".
      ## Osobne pole (`pendingBulkDelete`) od `pendingDeleteName`, bo to
      ## usuwanie WIELU wpisów naraz, nie jednego przy konkretnym wierszu.
      group "bulk-delete-btn":
        box deleteX, 4, deleteW, toolbarH - 8
        fill (if not hasSelection: "#202429" elif deleteArmed: "#5a2323" else: "#2a2f36")
        cornerRadius 4
        onHover:
          if hasSelection and not deleteArmed: fill "#3a4048"
          elif deleteArmed: fill "#6a2a2a"
        onClick:
          if hasSelection:
            if deleteArmed: doBulkDelete(fs)
            else:
              fs.pendingBulkDelete = true
              fs.pendingBulkDeleteAt = epochTime()
        text "bulk-delete-label":
          box 0, 0, deleteW, toolbarH - 8
          font "sans-serif", 12, 600, toolbarH - 8, hCenter, vCenter
          fill (if not hasSelection: "#5b6470" else: "#e6e6e6")
          characters (if deleteArmed: "Na pewno? (" & $fs.selectedSet.len & ")" else: "🗑 Usuń")

      group "copy-btn":
        box copyX, 4, copyW, toolbarH - 8
        fill (if hasSelection: "#2a2f36" else: "#202429")
        cornerRadius 4
        onHover:
          if hasSelection: fill "#3a4048"
        onClick:
          if hasSelection: doCopy(fs, fs.selectedSet)
        text "copy-label":
          box 0, 0, copyW, toolbarH - 8
          font "sans-serif", 12, 600, toolbarH - 8, hCenter, vCenter
          fill (if hasSelection: "#e6e6e6" else: "#5b6470")
          characters "⧉ Kopiuj"

      group "cut-btn":
        box cutX, 4, cutW, toolbarH - 8
        fill (if hasSelection: "#2a2f36" else: "#202429")
        cornerRadius 4
        onHover:
          if hasSelection: fill "#3a4048"
        onClick:
          if hasSelection: doCut(fs, fs.selectedSet)
        text "cut-label":
          box 0, 0, cutW, toolbarH - 8
          font "sans-serif", 12, 600, toolbarH - 8, hCenter, vCenter
          fill (if hasSelection: "#e6e6e6" else: "#5b6470")
          characters "✂ Wytnij"

      ## "Wklej" dostaje inny kolor niż zwykłe szare przyciski, gdy jest
      ## coś do wklejenia -- to jedyny przycisk w tym pasku (obok "Usuń"
      ## po drugim kliknięciu), który faktycznie MODYFIKUJE dysk od razu
      ## po kliknięciu, więc wart wyraźniejszego wyróżnienia, ten sam
      ## kolor co przycisk "Utwórz" w pasku nowego folderu niżej. Etykieta
      ## pokazuje liczbę wpisów w schowku, gdy jest ich więcej niż jeden.
      group "paste-btn":
        box pasteX, 4, pasteW, toolbarH - 8
        fill (if hasClipboard: "#2d8a5f" else: "#202429")
        cornerRadius 4
        onHover:
          if hasClipboard: fill "#37a373"
        onClick:
          if hasClipboard: doPaste(fs)
        text "paste-label":
          box 0, 0, pasteW, toolbarH - 8
          font "sans-serif", 12, 600, toolbarH - 8, hCenter, vCenter
          fill (if hasClipboard: "#ffffff" else: "#5b6470")
          characters (if gFileClipboardPaths.len > 1: "📋 Wklej (" & $gFileClipboardPaths.len & ")"
                      else: "📋 Wklej")

    # Breadcrumb ze ścieżką
    group "breadcrumb":
      box 0, toolbarH, win.size.x, breadcrumbH
      fill "#181b1f"
      clipContent true
      var x = pad
      for part in breadcrumbParts(fs):
        let w = float32(part.label.len * 8 + 14)
        group "crumb-" & part.path:
          box x, 2, w, breadcrumbH - 4
          onHover: fill "#232830"
          onClick: navigateTo(fs, part.path)
          text "crumb-label-" & part.path:
            box 0, 0, w, breadcrumbH - 4
            font "sans-serif", 12, 500, breadcrumbH - 4, hCenter, vCenter
            fill "#8fb8ff"
            characters part.label
        x += w + 2

    # Rozbudowa (nowy folder): pasek kreatora, widoczny tylko w trybie
    # `newFolderMode` -- pole nazwy + "Utwórz" + "Anuluj".
    if fs.newFolderMode:
      group "new-folder-bar":
        box 0, toolbarH + breadcrumbH, win.size.x, newFolderBarH
        fill "#1b2027"

        text "new-folder-input":
          box pad, 3, win.size.x - 170, newFolderBarH - 6
          font "sans-serif", 12, 400, newFolderBarH - 6, hLeft, vCenter
          fill "#e8ecf0"
          editableText true
          selectable true
          if not current.hasKeyboardFocus() and fs.newFolderName.len == 0:
            characters "nazwa nowego folderu..."
          else:
            characters fs.newFolderName
          onClick:
            keyboard.focus(current)
          onInput:
            fs.newFolderName = keyboard.input

        group "new-folder-create-btn":
          box win.size.x - 156, 3, 76, newFolderBarH - 6
          cornerRadius 4
          fill "#2d8a5f"
          onHover: fill "#37a373"
          onClick: doCreateFolder(fs)
          text "new-folder-create-label":
            box 0, 0, 76, newFolderBarH - 6
            font "sans-serif", 11, 700, newFolderBarH - 6, hCenter, vCenter
            fill "#ffffff"
            characters "Utwórz"

        group "new-folder-cancel-btn":
          box win.size.x - 76, 3, 70, newFolderBarH - 6
          cornerRadius 4
          fill "#2a2f36"
          onHover: fill "#3a424d"
          onClick:
            fs.newFolderMode = false
            fs.newFolderName = ""
          text "new-folder-cancel-label":
            box 0, 0, 70, newFolderBarH - 6
            font "sans-serif", 11, 600, newFolderBarH - 6, hCenter, vCenter
            fill "#c7ccd3"
            characters "Anuluj"

    # Rozbudowa (runda 19, wyszukiwanie plików): pasek pod breadcrumbem
    # (i pod paskiem nowego folderu, jeśli oba akurat otwarte na raz --
    # rzadkie, ale nie wykluczone, stąd `newFolderBarH` w Y niżej, nie
    # sztywne `breadcrumbH`), widoczny tylko gdy `fs.searchOpen`.
    if fs.searchOpen:
      group "search-bar":
        box 0, toolbarH + breadcrumbH + newFolderBarH, win.size.x, searchBarH
        fill "#1b2027"

        text "search-input":
          box pad, 3, win.size.x - 100, 26
          font "sans-serif", 12, 400, 26, hLeft, vCenter
          fill "#e8ecf0"
          editableText true
          selectable true
          if not current.hasKeyboardFocus() and fs.searchQuery.len == 0:
            characters "szukaj pliku w tym katalogu i podkatalogach..."
          else:
            characters fs.searchQuery
          onClick:
            keyboard.focus(current)
          onInput:
            fs.searchQuery = keyboard.input

        group "search-run-btn":
          box win.size.x - 88, 3, 82, 26
          cornerRadius 4
          fill (if fs.searchQuery.len > 0: "#2d5f8a" else: "#202429")
          onHover:
            if fs.searchQuery.len > 0: fill "#376ba3"
          onClick:
            if fs.searchQuery.len > 0: doSearch(fs)
          text "search-run-label":
            box 0, 0, 82, 26
            font "sans-serif", 11, 700, 26, hCenter, vCenter
            fill (if fs.searchQuery.len > 0: "#ffffff" else: "#5b6470")
            characters "🔍 Szukaj"

        ## Licznik wyników / komunikat "obcięto" -- pod polem, w drugiej,
        ## niższej linijce paska (stąd `searchBarH` = 36, nie 30 jak
        ## pasek nowego folderu -- potrzeba miejsca na tę dodatkową
        ## linijkę).
        text "search-status":
          box pad, 29, win.size.x - pad * 2, 14
          font "sans-serif", 10, 400, 14, hLeft, vCenter
          fill (if fs.searchTruncated: "#e0a850" else: "#8a94a3")
          characters (
            if fs.searchQuery.len == 0: "Wpisz nazwę (albo jej fragment) i naciśnij \"Szukaj\"."
            elif fs.searchResults.len == 0: "Brak wyników dla ostatniego wyszukiwania (kliknij \"Szukaj\", by uruchomić dla bieżącego zapytania)."
            elif fs.searchTruncated: "Znaleziono " & $fs.searchResults.len & "+ wyników (lista obcięta -- zawęź zapytanie)"
            else: "Znaleziono " & $fs.searchResults.len & " " & (if fs.searchResults.len == 1: "wynik" else: "wyników"))

    # Lista plików
    group "listing":
      box 0, listTop, win.size.x, win.size.y - listTop
      clipContent true

      ## NAPRAWIONY BRAK: lista miała `clipContent true`, ale nigdy nie
      ## śledziła przesunięcia scrolla -- w katalogu z więcej wpisami niż
      ## mieściło się w oknie, reszta była po prostu ucięta bez możliwości
      ## przewinięcia. `onHover` + `mouse.wheelDelta` (Fidget nie ma
      ## wbudowanego automatycznego scrolla dla zwykłych grup -- trzeba
      ## ręcznie doliczać przesunięcie i użyć go przy pozycjonowaniu
      ## wierszy, patrz `y` niżej).
      ##
      ## Rozbudowa (runda 19, wyszukiwanie plików): gdy pasek wyszukiwania
      ## jest otwarty I ma jakiekolwiek wyniki, TA SAMA grupa "listing"
      ## (te same wymiary/`clipContent`/scroll -- nie osobny widok obok)
      ## pokazuje listę wyników zamiast zwykłej zawartości katalogu,
      ## dlatego `showingSearch` (i `visibleCount`/`maxScroll` liczone na
      ## jego podstawie) decyduje, z KTÓREGO `seq` i KTÓREGO pola
      ## przewijania korzystać poniżej -- `fs.searchScrollOffset` jest
      ## CELOWO osobnym polem od `fs.scrollOffset` (patrz komentarz przy
      ## nim w `FilesState`), żeby przewinięcie wyników wyszukiwania nie
      ## nadpisywało pozycji przewinięcia zwykłej listy katalogu (i na
      ## odwrót) przy przełączaniu się między nimi.
      let showingSearch = fs.searchOpen and fs.searchResults.len > 0
      let listH = win.size.y - listTop
      let visibleCount = if showingSearch: fs.searchResults.len else: fs.entries.len
      let contentH = float32(visibleCount) * rowH
      let maxScroll = max(0.0'f32, contentH - listH)
      onHover:
        if mouse.wheelDelta != 0:
          if showingSearch:
            fs.searchScrollOffset = clamp(fs.searchScrollOffset - mouse.wheelDelta * rowH, 0.0'f32, maxScroll)
          else:
            fs.scrollOffset = clamp(fs.scrollOffset - mouse.wheelDelta * rowH, 0.0'f32, maxScroll)

      if showingSearch:
        ## Lista wyników wyszukiwania -- CELOWO prosty, płaski wiersz
        ## tekstowy (ikona + ścieżka WZGLĘDNA do katalogu, w którym
        ## wyszukiwanie się zaczęło, żeby było widać W KTÓRYM podkatalogu
        ## leży wynik) zamiast pełnej maszynerii wierszy zwykłej listy
        ## (bez przeciągania/zmiany nazwy/usuwania/zaznaczania -- wyniki
        ## mogą leżeć w RÓŻNYCH katalogach naraz, więc te akcje w ogóle
        ## nie mają tu jednoznacznego sensu). Klik nawiguje do wyniku
        ## przez `jumpToSearchResult` i zamyka pasek wyszukiwania.
        var ys = -fs.searchScrollOffset
        for path in fs.searchResults:
          let relPath = try: path.relativePath(fs.cwd) except ValueError: path
          let isDir = dirExists(path)
          group "search-result-" & path:
            box 0, ys, win.size.x, rowH
            fill "#000000"
            onHover: fill "#20262d"
            onClick: jumpToSearchResult(fs, path)
            text "search-result-icon-" & path:
              box pad, 0, 20, rowH
              font "sans-serif", 13, 400, rowH, hLeft, vCenter
              fill (if isDir: "#ffcc66" else: "#9fb4c7")
              characters (if isDir: "📁" else: "📄")
            text "search-result-label-" & path:
              box pad + 24, 0, win.size.x - pad * 2 - 24, rowH
              font "sans-serif", 12, 400, rowH, hLeft, vCenter
              fill "#c7ccd3"
              characters relPath
          ys += rowH
      elif fs.errorMsg.len > 0:
        text "err":
          box pad, pad, win.size.x - pad * 2, 40
          font "sans-serif", 12, 400, 18, hLeft, vTop
          fill "#ff8080"
          characters fs.errorMsg
      elif fs.entries.len == 0:
        text "empty":
          box pad, pad, win.size.x - pad * 2, 20
          font "sans-serif", 12, 400, 18, hLeft, vTop
          fill "#8a8f96"
          characters "(pusty katalog)"
      else:
        ## Szerokości zarezerwowane po prawej stronie każdego wiersza --
        ## rozbudowa (operacje na plikach) dołożyła dwie małe ikony
        ## (zmień nazwę / usuń), których wcześniej tu nie było. Liczone
        ## jako zmienne, nie magiczne literały wprost w `box`, z tego
        ## samego powodu co `rightZoneW` w `shell/taskbar.nim`.
        const actionsW = 54.0'f32   ## dwa przyciski 20px + odstępy
        const sizeW = 90.0'f32      ## kolumna rozmiaru pliku

        var y = -fs.scrollOffset
        for rowIdx, entry in fs.entries:
          let isSelected = entry.name in fs.selectedSet
          let isRenaming = fs.renamingName == entry.name
          let isPendingDelete = fs.pendingDeleteName == entry.name and
            (epochTime() - fs.pendingDeleteAt) < DeleteArmSeconds
          ## Rozbudowa (przeciąganie plików/folderów myszą): dwa dodatkowe
          ## stany wizualne wiersza w trakcie aktywnego przeciągania (patrz
          ## duży komentarz przy `FileDragState` wyżej) -- `isBeingDragged`
          ## przygasza wiersz, z którego przeciąganie WYSTARTOWAŁO,
          ## `isDropTarget` podświetla NA ZIELONO wiersz folderu aktualnie
          ## najechanego jako cel upuszczenia. Działa też MIĘDZY dwoma
          ## różnymi otwartymi oknami menedżera -- `gFileDropTarget` to
          ## zwykła bezwzględna ścieżka, nieświadoma tego, które okno ją
          ## ustawiło.
          let isBeingDragged = gFileDrag.active and fs.cwd == gFileDrag.sourceDir and
            entry.name in gFileDrag.names
          let isDropTarget = gFileDrag.active and entry.kind == ekDir and
            not isBeingDragged and gFileDropTarget == fs.cwd / entry.name
          ## Rozbudowa (runda 14, Ctrl = kopiuj): kolor celu upuszczenia
          ## odzwierciedla, co się stanie PRZY PUSZCZENIU przycisku TERAZ
          ## -- niebieski ("skopiuj") gdy Ctrl aktualnie trzymany, zielony
          ## ("przenieś", jak w rundzie 13) w przeciwnym razie. Czytane na
          ## bieżąco, więc doszczypnięcie/puszczenie Ctrl w trakcie
          ## przeciągania NAD tym samym folderem widocznie zmienia kolor
          ## klatka po klatce, zanim użytkownik w ogóle puści przycisk.
          let dropWouldCopy = buttonDown[LEFT_CONTROL] or buttonDown[RIGHT_CONTROL]
          group "row-" & entry.name:
            box 0, y, win.size.x, rowH
            fill (if isDropTarget and dropWouldCopy: "#2d4f8a"
                  elif isDropTarget: "#2d6b48"
                  elif isBeingDragged: "#262b33"
                  elif isSelected: "#2d5f8a"
                  else: "#000000")
            onHover:
              if not isSelected and not isDropTarget:
                fill "#20262d"
              ## Rejestruje TEN wiersz jako bieżący cel upuszczenia, jeśli
              ## akurat trwa przeciąganie i to wiersz folderu -- odczytane
              ## w `updateFileDrag` PO narysowaniu wszystkich okien w tej
              ## samej klatce (patrz kolejność wołań w `shell/shell.nim`),
              ## więc samo podświetlenie pojawia się dopiero od NASTĘPNEJ
              ## klatki (nieodczuwalne opóźnienie jednej klatki, ten sam
              ## kompromis co gdzie indziej w tym pliku). Nie da się
              ## upuścić folderu na SAMEGO SIEBIE ani na aktualnie
              ## przeciągany wpis -- `isBeingDragged` wyżej to wyklucza z
              ## bycia zarejestrowanym jako cel.
              if gFileDrag.active and entry.kind == ekDir and not isBeingDragged:
                gFileDropTarget = fs.cwd / entry.name
            onMouseDown:
              ## DODATKOWY handler obok istniejącego `onClick` niżej --
              ## Fidget pozwala na wiele bloków zdarzeń na jednym węźle
              ## (ten sam wzorzec co `onHover` + `onClick` na "up-btn"
              ## wyżej) -- wyłącznie UZBRAJA potencjalne przeciąganie, nie
              ## zmienia zaznaczenia ani nie nawiguje (tym w całości
              ## zajmuje się WYŁĄCZNIE `onClick`, bez żadnych zmian). Jeśli
              ## użytkownik po prostu kliknie bez ruchu myszy,
              ## `gFileDropTarget` nigdy się nie ustawi (nie najechał na
              ## żaden INNY wiersz folderu w międzyczasie), więc
              ## `updateFileDrag` przy puszczeniu przycisku nic nie
              ## przeniesie -- czysty no-op, zwykły klik działa dokładnie
              ## jak wcześniej. Przeciąganie WIELU zaznaczonych wpisów
              ## naraz działa tylko, gdy kliknięty wiersz JEST już częścią
              ## wieloelementowego zaznaczenia (Ctrl/Shift+klik) -- zwykły
              ## klik na czymś spoza zaznaczenia i tak zaraz zredukuje
              ## zaznaczenie do tego jednego wpisu (patrz `onClick` niżej),
              ## więc przeciąganie samego tego jednego wpisu jest tu
              ## poprawnym zachowaniem, nie błędem.
              ##
              ## Rozbudowa (runda 14): FOLDERY też można teraz przeciągać
              ## -- ale TYLKO w sytuacjach, w których `onClick` niżej i tak
              ## NIE nawigowałby do ich środka, żeby te dwa gesty na tym
              ## samym wierszu nigdy się nie pogryzły: (a) Ctrl albo Shift
              ## trzymany W TEJ CHWILI (te same dwa warunki, którymi
              ## `onClick` rozpoznaje "to zaznacz/zakres, nie wejście do
              ## środka"), albo (b) wiersz jest już częścią
              ## wieloelementowego zaznaczenia sprzed tego kliknięcia.
              ## Zwykły, pojedynczy klik na NIEZAZNACZONYM folderze (bez
              ## modyfikatorów) dalej nawiguje do środka, bez zmian --
              ## `onMouseDown` w tym przypadku po prostu nic nie uzbraja.
              if not editingText:
                let ctrlHeld = buttonDown[LEFT_CONTROL] or buttonDown[RIGHT_CONTROL]
                let shiftHeld = buttonDown[LEFT_SHIFT] or buttonDown[RIGHT_SHIFT]
                let alreadyMultiSelected = entry.name in fs.selectedSet and fs.selectedSet.len > 1
                let canDrag = entry.kind == ekFile or ctrlHeld or shiftHeld or alreadyMultiSelected
                if canDrag:
                  let draggedNames = if alreadyMultiSelected: fs.selectedSet
                                      else: @[entry.name]
                  gFileDrag = FileDragState(active: true, sourceDir: fs.cwd, names: draggedNames)
            onClick:
              ## Rozbudowa (zaznaczanie wielu wpisów): Ctrl+klik PRZEŁĄCZA
              ## ten wpis w `selectedSet` (dodaje, jeśli go tam nie było,
              ## usuwa, jeśli był) i NIGDY nie nawiguje/otwiera -- nawet
              ## dla katalogu -- bo intencja Ctrl+kliknięcia to zawsze
              ## "zaznacz to też", nigdy "wejdź do środka". Shift+klik
              ## zaznacza CIĄGŁY ZAKRES od `anchorName` (ostatnie zwykłe
              ## kliknięcie, patrz komentarz przy tym polu w typie
              ## `FilesState`) do tego wiersza, ZASTĘPUJĄC dotychczasowe
              ## zaznaczenie -- dokładnie tak zachowują się
              ## Nautilus/Dolphin/Eksplorator. Zwykły klik (bez
              ## modyfikatorów) zastępuje całe zaznaczenie tym jednym
              ## wpisem i przestawia kotwicę na niego. `buttonDown[...]`
              ## zamiast `keyboard.ctrlKey`/`shiftKey` -- ten sam,
              ## sprawdzony wcześniej sposób odczytu modyfikatorów co w
              ## `shell/shortcuts.nim` (tam opisano dlaczego
              ## `keyboard.ctrlKey` bywa zawodny).
              let ctrlDown = buttonDown[LEFT_CONTROL] or buttonDown[RIGHT_CONTROL]
              let shiftDown = buttonDown[LEFT_SHIFT] or buttonDown[RIGHT_SHIFT]
              if ctrlDown:
                if isSelected:
                  fs.selectedSet.keepItIf(it != entry.name)
                else:
                  fs.selectedSet.add(entry.name)
              elif shiftDown:
                let anchorIdx = entryIndex(fs, fs.anchorName)
                if anchorIdx < 0:
                  ## Brak (jeszcze) kotwicy, albo kotwica wskazywała na coś,
                  ## co już nie istnieje -- Shift+klik bez ważnej kotwicy
                  ## zachowuje się jak zwykły klik, kotwica ustawia się
                  ## na TEN wpis.
                  fs.selectedSet = @[entry.name]
                  fs.anchorName = entry.name
                else:
                  let lo = min(anchorIdx, rowIdx)
                  let hi = max(anchorIdx, rowIdx)
                  fs.selectedSet = fs.entries[lo .. hi].mapIt(it.name)
                  ## Kotwica NIE przesuwa się na kliknięty wiersz -- kolejne
                  ## Shift+kliknięcie ma poszerzać/zwężać zakres względem
                  ## TEJ SAMEJ kotwicy, nie względem ostatniego zakresu.
              else:
                fs.selectedSet = @[entry.name]
                fs.anchorName = entry.name
                ## Rozbudowa (otwieranie plików): wykrywanie podwójnego
                ## kliknięcia -- dwa kliknięcia W TĘ SAMĄ nazwę w ciągu
                ## 0.4s. `lastClickTime`/`lastClickName` istniały w typie
                ## od dawna, ale nigdy nie były odczytywane -- ten kod je
                ## nareszcie wykorzystuje.
                let t = epochTime()
                let isDoubleClick = entry.name == fs.lastClickName and
                  (t - fs.lastClickTime) < 0.4
                fs.lastClickTime = t
                fs.lastClickName = entry.name
                case entry.kind
                of ekDir:
                  navigateTo(fs, fs.cwd / entry.name)
                of ekFile:
                  if isDoubleClick and fs.openFile != nil:
                    fs.openFile(fs.cwd / entry.name)

            ## Rozbudowa (runda 16, miniatury obrazów): domyka jawnie
            ## wypisany brak z README. Dla plików o rozszerzeniu, które
            ## `apps/filemanager/thumbnails.nim` (moduł BEZ `fidget`,
            ## patrz duży komentarz tam po pełne uzasadnienie i metodę
            ## weryfikacji) potrafi zdekodować, próbujemy narysować
            ## PRAWDZIWĄ miniaturę zamiast generycznej ikony "📄" -- ten
            ## sam wzorzec `image(...)` co `shell/wallpaper.nim` już
            ## sprawdziło dla tapety (`dataDir = "/"` ustawione raz w
            ## `shell/shell.nim`, stąd ścieżka BEZ wiodącego "/"). Dla
            ## folderów oraz plików, dla których miniatura się nie udała
            ## (zły format mimo pasującego rozszerzenia, uszkodzony plik,
            ## błąd zapisu cache'a -- `ensureThumbnail` zwraca wtedy "",
            ## nigdy nie rzuca wyjątku) -- bez zmian, stara ikona
            ## tekstowa.
            ##
            ## Uwaga wydajnościowa: `ensureThumbnail` jest wołane co
            ## KLATKĘ dla każdego WIDOCZNEGO wiersza z pasującym
            ## rozszerzeniem -- w praktyce tanie (samo `fileExists` na
            ## trafienie w cache, bez ponownego dekodowania/skalowania),
            ## ale to wciąż jeden dodatkowy `stat()` na klatkę na wiersz,
            ## nie w pełni zoptymalizowane trzymanie wyniku w pamięci
            ## `FilesState` między klatkami. Przy typowej liczbie
            ## widocznych wierszy (kilkanaście-kilkadziesiąt) to
            ## niezauważalne; przy setkach jednocześnie widocznych plików
            ## graficznych w bardzo dużym oknie mogłoby zacząć mieć
            ## znaczenie -- świadomie zostawione jako możliwa przyszła
            ## optymalizacja, nie problem tej rundy.
            let thumbPath =
              if entry.kind == ekFile and thumbnails.isThumbnailableExt(entry.name):
                thumbnails.ensureThumbnail(fs.cwd / entry.name)
              else: ""
            if thumbPath.len > 0 and fileExists(thumbPath):
              rectangle "thumb-" & entry.name:
                box pad, (rowH - 20.0'f32) / 2.0'f32, 20, 20
                cornerRadius 3
                image thumbPath[1 .. ^1]
            else:
              text "icon-" & entry.name:
                box pad, 0, 20, rowH
                font "sans-serif", 13, 400, rowH, hLeft, vCenter
                fill (if entry.kind == ekDir: "#ffcc66" else: "#9fb4c7")
                characters (if entry.kind == ekDir: "📁" else: "📄")

            if isRenaming:
              ## Tryb zmiany nazwy: pole tekstowe w miejscu zwykłej nazwy,
              ## plus "✓"/"×" zamiast normalnych ikon zmień-nazwę/usuń.
              text "rename-input-" & entry.name:
                box pad + 24, 0, win.size.x - pad - 24 - actionsW, rowH
                font "sans-serif", 13, 400, rowH, hLeft, vCenter
                fill "#ffffff"
                editableText true
                selectable true
                characters fs.renameBuffer
                onClick:
                  keyboard.focus(current)
                onInput:
                  fs.renameBuffer = keyboard.input

              group "rename-confirm-" & entry.name:
                box win.size.x - actionsW, (rowH - 20) / 2, 20, 20
                cornerRadius 4
                fill "#000000", 0.0
                onHover: fill "#1f3a2b"
                onClick: doRename(fs, entry.name)
                text "rename-confirm-label-" & entry.name:
                  box 0, 0, 20, 20
                  font "sans-serif", 12, 700, 20, hCenter, vCenter
                  fill "#6ad18f"
                  characters "✓"

              group "rename-cancel-" & entry.name:
                box win.size.x - actionsW + 24, (rowH - 20) / 2, 20, 20
                cornerRadius 4
                fill "#000000", 0.0
                onHover: fill "#3a2323"
                onClick: fs.renamingName = ""
                text "rename-cancel-label-" & entry.name:
                  box 0, 0, 20, 20
                  font "sans-serif", 12, 700, 20, hCenter, vCenter
                  fill "#c96a6a"
                  characters "×"
            else:
              text "name-" & entry.name:
                box pad + 24, 0, win.size.x - pad - 24 - actionsW -
                  (if entry.kind == ekFile: sizeW else: 0.0'f32), rowH
                font "sans-serif", 13, 400, rowH, hLeft, vCenter
                fill "#e6e6e6"
                characters entry.name

              if entry.kind == ekFile:
                text "size-" & entry.name:
                  box win.size.x - actionsW - sizeW, 0, sizeW - pad, rowH
                  font "sans-serif", 12, 400, rowH, hRight, vCenter
                  fill "#8a8f96"
                  characters humanSize(entry.size)

              ## Ikona zmiany nazwy -- wchodzi w tryb `isRenaming`,
              ## wypełniając bufor bieżącą nazwą (użytkownik edytuje od
              ## pełnej nazwy, nie od pustego pola).
              group "rename-btn-" & entry.name:
                box win.size.x - actionsW, (rowH - 20) / 2, 20, 20
                cornerRadius 4
                fill "#000000", 0.0
                onHover: fill "#2a323d"
                onClick:
                  fs.renamingName = entry.name
                  fs.renameBuffer = entry.name
                  fs.pendingDeleteName = ""
                text "rename-btn-label-" & entry.name:
                  box 0, 0, 20, 20
                  font "sans-serif", 11, 400, 20, hCenter, vCenter
                  fill "#9fb0c7"
                  characters "✎"

              ## Ikona usuwania -- rozbudowa "uzbrojenia" (patrz duży
              ## komentarz przy `pendingDeleteName` w typie `FilesState`
              ## wyżej): pierwszy klik zbroi, DRUGI (na tej samej,
              ## teraz-czerwonej ikonie) faktycznie usuwa. Kliknięcie
              ## GDZIEKOLWIEK INDZIEJ nie rozbraja natychmiast -- pole po
              ## prostu wygasa samo po `DeleteArmSeconds`, sprawdzane
              ## leniwie przy renderze (`isPendingDelete` wyżej) -- prościej
              ## niż dopinać osobny globalny `onClickOutside` tylko dla
              ## tego jednego przycisku.
              group "delete-btn-" & entry.name:
                box win.size.x - actionsW + 24, (rowH - 20) / 2, 20, 20
                cornerRadius 4
                fill (if isPendingDelete: "#5a2323" else: "#000000")
                onHover: fill (if isPendingDelete: "#6a2a2a" else: "#3a2323")
                onClick:
                  if isPendingDelete:
                    doDelete(fs, entry.name)
                  else:
                    fs.pendingDeleteName = entry.name
                    fs.pendingDeleteAt = epochTime()
                    fs.renamingName = ""
                text "delete-btn-label-" & entry.name:
                  box 0, 0, 20, 20
                  font "sans-serif", (if isPendingDelete: 10 else: 11), 600, 20, hCenter, vCenter
                  fill "#c96a6a"
                  characters (if isPendingDelete: "✔?" else: "🗑")

          y += rowH
