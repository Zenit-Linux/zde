import std/[os, algorithm, strutils, strformat, times, sequtils]
import fidget
import ../../comp/comp
import ../../shell/notifications
import ../../shell/state

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
    ## Rozbudowa (kopiuj/wytnij/wklej): "schowek plików" -- CELOWO osobny
    ## byt od `shell/clipboard.nim` (schowka TEKSTOWEGO systemu) -- to
    ## dwie różne rzeczy z różnymi protokołami (ten tutaj to zwykła lista
    ## bezwzględnych ścieżek + flaga, trzymana wyłącznie w pamięci JEDNEGO
    ## okna menedżera plików, bez integracji z `wl_data_device`, więc NIE
    ## działa między dwoma otwartymi oknami menedżera ani z zewnętrznymi
    ## aplikacjami -- prawdziwy schowek plików w stylu GNOME/KDE
    ## wymagałby własnego typu MIME na `wl_data_device`, czego dziś
    ## architektura ZDE nigdzie nie robi; to świadomy kompromis, nie
    ## przeoczenie). Pusta lista = pusty schowek. `seq`, nie pojedyncza
    ## ścieżka -- od rozbudowy "zaznaczanie wielu wpisów" można
    ## kopiować/wycinać całe zaznaczenie naraz, nie tylko jeden wpis.
    clipboardPaths: seq[string]
    clipboardCut: bool  ## true = "Wytnij" (przenieś przy wklejeniu), false = "Kopiuj"
    ## Rozbudowa (zbiorcze usuwanie): ten sam mechanizm "uzbrojenia" co
    ## `pendingDeleteName`/`pendingDeleteAt` wyżej, ale dla przycisku
    ## "Usuń" w pasku narzędzi działającego na CAŁYM `selectedSet` --
    ## osobne pole, bo `pendingDeleteName` to pojedyncza nazwa (dla ikony
    ## kosza PRZY WIERSZU), a tu zbrojone jest usunięcie WIELU wpisów
    ## naraz.
    pendingBulkDelete: bool
    pendingBulkDeleteAt: float

const DeleteArmSeconds = 4.0

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

proc refresh(fs: FilesState) =
  fs.entries.setLen(0)
  fs.errorMsg = ""
  try:
    for kind, path in walkDir(fs.cwd):
      let name = extractFilename(path)
      if name.len == 0: continue
      case kind
      of pcDir, pcLinkToDir:
        fs.entries.add(Entry(name: name, kind: ekDir, size: 0))
      of pcFile, pcLinkToFile:
        var sz: BiggestInt = 0
        var mt: Time
        try:
          sz = getFileSize(path)
          mt = getLastModificationTime(path)
        except OSError:
          discard
        fs.entries.add(Entry(name: name, kind: ekFile, size: sz, modified: mt))
    fs.entries.sort(proc(a, b: Entry): int =
      if a.kind != b.kind:
        return (if a.kind == ekDir: -1 else: 1)
      cmp(a.name.toLowerAscii, b.name.toLowerAscii)
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
  if dirExists(normalized):
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
  fs.clipboardPaths = names.mapIt(fs.cwd / it)
  fs.clipboardCut = false

proc doCut(fs: FilesState, names: seq[string]) =
  fs.clipboardPaths = names.mapIt(fs.cwd / it)
  fs.clipboardCut = true

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
  if fs.clipboardPaths.len == 0: return
  var okCount = 0
  var failMsgs: seq[string] = @[]
  for src in fs.clipboardPaths:
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
        if fs.clipboardCut: moveDir(src, dst)
        else: copyDir(src, dst)
      else:
        if fs.clipboardCut: moveFile(src, dst)
        else: copyFile(src, dst)
      inc okCount
    except OSError as e:
      failMsgs.add(extractFilename(src) & ": " & e.msg)

  if okCount > 0:
    notify((if fs.clipboardCut: "Przeniesiono" else: "Skopiowano"),
      $okCount & " " & (if okCount == 1: "wpis" else: "wpisów"), nkInfo)
  if failMsgs.len > 0:
    fs.errorMsg = "Nie udało się wkleić: " & failMsgs.join("; ")
    notify("Błąd wklejania", $failMsgs.len & " się nie udało", nkWarning)

  ## "Wytnij" jest jednorazowe -- po wklejeniu schowek się czyści,
  ## dokładnie jak przy Ctrl+X/Ctrl+V w innych menedżerach. "Kopiuj"
  ## NIE czyści schowka -- to samo źródło można wkleić wielokrotnie do
  ## kilku różnych miejsc, tak samo jak ze zwykłym schowkiem tekstowym.
  if fs.clipboardCut: fs.clipboardPaths.setLen(0)
  refresh(fs)

# --- Rysowanie ------------------------------------------------------------

proc drawFileManager*(fs: FilesState, win: ZdeWindow) =
  let toolbarH = 32.0'f32
  let breadcrumbH = 26.0'f32
  let rowH = 24.0'f32
  let pad = 6.0'f32
  ## Rozbudowa (nowy folder): drugi, opcjonalny pasek pod breadcrumbem --
  ## obecny TYLKO gdy `fs.newFolderMode`, więc nie zabiera stale miejsca
  ## listie plików w typowym przypadku przeglądania.
  let newFolderBarH = if fs.newFolderMode: 30.0'f32 else: 0.0'f32
  let listTop = toolbarH + breadcrumbH + newFolderBarH

  ## Rozbudowa (skróty klawiszowe): Delete/Ctrl+A/Escape/F2 -- tylko gdy
  ## TO okno jest aktywne (`win.id == compositor.focusedId`, ten sam
  ## sprawdzony sposób co podświetlanie ramki w `shell/chrome.nim`) i
  ## użytkownik nie jest akurat w trakcie wpisywania nazwy (zmiana nazwy
  ## albo nowy folder) -- bez tej drugiej blokady np. Delete skasowałby
  ## zaznaczenie w trakcie pisania nazwy nowego pliku, co byłoby mylące.
  ## `buttonPress[...]` (nie `buttonDown`) -- zdarzenie "wciśnięto W TEJ
  ## KLATCE", więc trzymanie klawisza nie powtarza akcji bez końca.
  let isFocused = win.id == compositor.focusedId
  let editingText = fs.renamingName.len > 0 or fs.newFolderMode
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

      group "up-btn":
        box pad, 4, 64, toolbarH - 8
        fill "#2a2f36"
        cornerRadius 4
        onHover: fill "#3a4048"
        onClick: navigateUp(fs)
        text "up-label":
          box 0, 0, 64, toolbarH - 8
          font "sans-serif", 12, 600, toolbarH - 8, hCenter, vCenter
          fill "#e6e6e6"
          characters "⬆ Wyżej"

      group "refresh-btn":
        box pad * 2 + 64, 4, 90, toolbarH - 8
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
        box pad * 3 + 64 + 90, 4, 96, toolbarH - 8
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
      let hasClipboard = fs.clipboardPaths.len > 0
      let deleteArmed = fs.pendingBulkDelete and
        (epochTime() - fs.pendingBulkDeleteAt) < DeleteArmSeconds
      let pasteW = if hasClipboard and fs.clipboardPaths.len > 1: 84.0'f32 else: 70.0'f32
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
          characters (if fs.clipboardPaths.len > 1: "📋 Wklej (" & $fs.clipboardPaths.len & ")"
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
      let listH = win.size.y - listTop
      let contentH = float32(fs.entries.len) * rowH
      let maxScroll = max(0.0'f32, contentH - listH)
      onHover:
        if mouse.wheelDelta != 0:
          fs.scrollOffset = clamp(fs.scrollOffset - mouse.wheelDelta * rowH, 0.0'f32, maxScroll)

      if fs.errorMsg.len > 0:
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
          group "row-" & entry.name:
            box 0, y, win.size.x, rowH
            fill (if isSelected: "#2d5f8a" else: "#000000")
            onHover:
              if not isSelected:
                fill "#20262d"
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
