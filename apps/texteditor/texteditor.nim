import std/[os, strutils, times, algorithm, re]
import fidget
import ../../comp/comp
import ../../shell/clipboard
import highlight

type
  Tab = ref object
    path: string
    content: string
    statusMsg: string
    dirty: bool
    scrollOffset: int
    wasEditing: bool
    ## Rozbudowa v0.1 ("Aurora" -- wykrywanie zmian na dysku): czas
    ## ostatniej modyfikacji pliku, jaki ZNAMY -- ustawiany po każdym
    ## udanym wczytaniu/zapisie (`doOpen`/`doSave`). `checkExternalChanges`
    ## (wołane co sekundę z `shell.nim`, patrz rejestr `texteditors` w
    ## `shell/state.nim`) porównuje go z aktualnym czasem modyfikacji na
    ## dysku -- różnica oznacza, że COŚ INNEGO (inny program, `git pull`,
    ## edycja w terminalu) zmieniło plik pod nami.
    lastKnownMtime: Time
    externallyChanged: bool  ## czy pokazywać baner "plik zmienił się na dysku"
    ## Rozbudowa (Znajdź): edytor nie miał ŻADNEGO sposobu na wyszukanie
    ## tekstu w dokumencie -- trzeba było przewijać ręcznie. `findOpen`
    ## pokazuje/ukrywa pasek "Znajdź" pod paskiem narzędzi (ten sam wzorzec
    ## rezerwowania wysokości co baner "plik zmienił się na dysku" niżej).
    findOpen: bool
    findQuery: string
    ## Wszystkie dopasowania w BIEŻĄCEJ treści dla `findQuery` -- (numer
    ## linii, kolumna początku), przeliczane na nowo przy KAŻDYM
    ## renderowaniu paska "Znajdź" (patrz `computeFindMatches` w
    ## `drawEditor`), nie tylko przy zmianie zapytania -- dokument mógł się
    ## zmienić pod spodem (pisanie w treści). Prosty, pełny przelicz-na-
    ## nowo skan, ten sam poziom "wystarczająco dobre" co
    ## `drawHighlighted` niżej, które retokenizuje widoczne linie na każdej
    ## klatce niezależnie od rozmiaru pliku -- ten sam kompromis
    ## wydajnościowy, nie nowy.
    findMatches: seq[tuple[line, col, length: int, groups: seq[tuple[col, length: int]]]]
    findCurrentIdx: int  ## indeks w `findMatches` aktualnie "wycelowanego" dopasowania, -1 = brak
    findLastQuery: string  ## poprzednia wartość `findQuery` -- do odróżnienia "nowe zapytanie" od "ta sama treść, inny dokument", patrz `computeFindMatches`
    findLastCaseSensitive: bool  ## poprzednia wartość `caseSensitive` -- tak samo jak `findLastQuery`, ale dla przełącznika "Aa" (patrz `computeFindMatches`)
    ## Rozbudowa (Zamień): tekst, na który zamieniane są dopasowania --
    ## osobne pole od `findQuery`, bo to logicznie dwie różne rzeczy
    ## (czego szukamy vs. na co zamieniamy), mimo że w UI stoją obok
    ## siebie w tym samym pasku.
    replaceQuery: string
    ## Rozbudowa v0.2 (Znajdź -- rozróżnianie wielkości liter): do tej
    ## rundy `computeFindMatches`/`doReplaceCurrent`/`doReplaceAll`
    ## ZAWSZE porównywały przez `toLowerAscii()` po obu stronach -- README
    ## (sekcja "Ograniczenia") jawnie wymieniało to jako brak: "bez
    ## rozróżniania wielkości liter". Domyślnie `false` (zachowanie
    ## nieczułe na wielkość liter, jak dotychczas -- żadna istniejąca
    ## karta/dokument nie dostaje niespodziewanej zmiany zachowania po tej
    ## rozbudowie), przełączane przyciskiem "Aa" w pasku Znajdź (patrz
    ## `drawEditor`).
    caseSensitive: bool
    ## Rozbudowa (wyrażenia regularne w Znajdź/Zamień): domyka jawnie
    ## wypisany brak z listy ograniczeń ("wciąż bez wyrażeń regularnych").
    ## Przełącznik ".*" w pasku Znajdź, obok "Aa" -- domyślnie `false`
    ## (zwykłe dopasowanie podłańcucha, jak dotychczas -- żaden istniejący
    ## dokument/karta nie dostaje niespodziewanej zmiany zachowania). Gdy
    ## włączone, `t.findQuery` jest interpretowane jako wzorzec PCRE
    ## (`std/re`, ten sam silnik, którego reszta stdlib Nim używa do
    ## wyrażeń regularnych) zamiast dosłownego podłańcucha.
    useRegex: bool
    findLastUseRegex: bool  ## poprzednia wartość `useRegex` -- ten sam wzorzec co `findLastCaseSensitive`, patrz `computeFindMatches`
    ## Komunikat błędu kompilacji wzorca (np. niedomknięty nawias) --
    ## PUSTY, gdy wzorzec jest poprawny (albo `useRegex` wyłączone).
    ## Kompilacja wzorca może rzucić wyjątkiem (`std/re` opakowuje PCRE),
    ## więc `computeFindMatches` łapie go i pokazuje w miejscu licznika
    ## wyników zamiast wywalać całe okno edytora na błędnym wzorcu w
    ## trakcie pisania (np. "(" bez domykającego ")" -- naturalny,
    ## przejściowy stan PODCZAS wpisywania wzorca, nie coś do traktowania
    ## jak awaria).
    regexError: string
    ## Rozbudowa (runda 16 -- cofanie dla "Zamień"/"Zamień wszystko"):
    ## odkrycie z rundy 15 -- edytor NIE MA żadnego mechanizmu Ctrl+Z dla
    ## treści dokumentu (sprawdzone w źródle, nie zakładane). Zamiast
    ## dopisywać się do NIEZWERYFIKOWANEGO wewnętrznego zachowania
    ## Fidget-owego pola `editableText` przy zwykłym pisaniu (ryzykowne --
    ## nie wiadomo, czy/jak Fidget sam obsługuje Ctrl+Z przy pisaniu, a
    ## przechwycenie tego globalnie mogłoby po cichu popsuć samo pisanie,
    ## rzecz używaną w KAŻDEJ klatce), ten mechanizm jest CELOWO wąski:
    ## cofa WYŁĄCZNIE operacje "Zamień"/"Zamień wszystko"
    ## (`doReplaceCurrent`/`doReplaceAll` niżej) -- to one i tak
    ## manipulują `t.content` jako zwykłym stringiem, z pominięciem pola
    ## tekstowego, więc dodanie ograniczonego stosu TYLKO dla nich nie
    ## rusza ścieżki zwykłego pisania w ogóle. Osobny przycisk "↶" w
    ## pasku Zamień (nie skrót Ctrl+Z) -- świadomie, z tego samego powodu:
    ## globalny skrót klawiszowy mógłby kolidować z nieznanym zachowaniem
    ## Fidgetu, zwykły przycisk nie koliduje z niczym.
    replaceUndoStack: seq[string]
    ## **Runda 34 -- domknięcie tego właśnie, jawnie opisanego wyżej
    ## ograniczenia: pełne Ctrl+Z/Ctrl+Shift+Z dla ZWYKŁEGO PISANIA, nie
    ## tylko dla "Zamień".** Ryzyko opisane w komentarzu wyżej (nieznane
    ## wewnętrzne zachowanie Fidget-owego bufora edycji pola
    ## `editableText`) jest realne i NIE zniknęło -- rozwiązane tym samym
    ## mechanizmem, którego ten projekt już raz użył do analogicznego
    ## problemu: `apps/terminal/term.nim` (runda 12) odkryło, że Fidget
    ## trzyma WŁASNY, wewnętrzny bufor edycji dla aktualnie SKUPIONEGO
    ## pola, niezależny od `keyboard.input`, i odtwarza go z powrotem po
    ## `onInput` -- jedynym sprawdzonym sposobem wymuszenia PEŁNEGO
    ## resetu tego bufora jest `keyboard.focusNode = nil`. Cofnięcie/
    ## przywrócenie (patrz `undoTyping`/`redoTyping` niżej) robi DOKŁADNIE
    ## to samo: po podmianie `t.content` na starszą/nowszą migawkę,
    ## `keyboard.focusNode` jest zerowane, więc pole traci fokus i przy
    ## kolejnym kliknięciu zaczyna od ŚWIEŻEGO bufora zgodnego z nowym
    ## `t.content`, zamiast dać Fidgetowi szansę nadpisać naszą zmianę
    ## swoją starą, wewnętrzną kopią na następnej klatce.
    ##
    ## Migawki CAŁEGO dokumentu (nie diff -- ten sam, już sprawdzony styl
    ## co `replaceUndoStack`), odkładane w `onInput` głównego pola
    ## `content-edit` z DEBOUNCE `UndoSnapshotIntervalSec` (nie przy
    ## KAŻDYM naciśniętym znaku -- inaczej seria szybkiego pisania
    ## rozbiłaby się na dziesiątki osobnych kroków cofania, myląco
    ## drobnych) i limitem głębokości `MaxUndoDepth`. Nowa edycja PO
    ## cofnięciu kasuje `redoTypingStack` (standardowe zachowanie -- tak
    ## samo jak w każdym innym edytorze: "napisz coś nowego" unieważnia
    ## starą "przyszłość" do przywrócenia).
    ##
    ## **Uczciwa notatka o weryfikacji**: w tej sesji, tak jak reszta UI
    ## `zde-shell`, TEGO pliku (importuje `fidget`) nie dało się
    ## skompilować ani uruchomić na żywo (środowisko ma tylko Nim 1.6.14,
    ## `fidget` wymaga >= 2.0) -- mechanizm `keyboard.focusNode = nil`
    ## jest odtworzeniem TECHNIKI już raz potwierdzonej żywym testem pod
    ## Xvfb (runda 12, terminal), ale zastosowanie jej TUTAJ, w tym
    ## konkretnym polu, nie zostało w tej rundzie ponownie zweryfikowane
    ## wizualnie. Do potwierdzenia w przyszłej sesji z dostępnym
    ## środowiskiem Fidget/GLFW.
    undoTypingStack: seq[string]
    redoTypingStack: seq[string]
    lastUndoSnapshotAt: float  ## `epochTime()` ostatniej migawki -- debounce, patrz wyżej
    ## Rozbudowa v0.2 (przeglądarka plików do otwierania, ten sam wzorzec
    ## co "Przeglądaj..." przy tapecie w `apps/settings/settings.nim` --
    ## patrz duży komentarz przy `drawFilePicker` niżej, WŁĄCZNIE z
    ## odkrytym tam istotnym quirkiem Fidgetu o odwróconej kolejności
    ## malowania rodzeństwa, który dotyczy TEJ nakładki dokładnie tak
    ## samo). Pole `path` dotąd trzeba było wpisać ręcznie w całości --
    ## ten sam brak co przy tapecie, teraz załatany tym samym
    ## rozwiązaniem, osobno na stan każdej KARTY (nie całego edytora),
    ## bo różne karty mogą przeglądać różne katalogi niezależnie.
    pickerOpen: bool
    pickerDir: string
    pickerEntries: seq[tuple[name: string, isDir: bool]]
    pickerScroll: float32
    pickerError: string

  EditorState* = ref object of RootObj
    tabs: seq[Tab]
    activeTab: int

const
  ApproxCharW = 7.6'f32
  LineH = 19.0'f32
  TabBarH = 30.0'f32
  TabW = 150.0'f32

proc newTab(startPath = ""): Tab =
  result = Tab(path: startPath, content: "", statusMsg: "", dirty: false, findCurrentIdx: -1)
  if startPath.len > 0 and fileExists(startPath):
    try:
      result.content = readFile(startPath)
      result.statusMsg = "Wczytano " & startPath
      result.lastKnownMtime = getLastModificationTime(startPath)
    except IOError as e:
      result.statusMsg = "Błąd wczytywania: " & e.msg

proc newEditorState*(startPath = ""): EditorState =
  EditorState(tabs: @[newTab(startPath)], activeTab: 0)

proc active(es: EditorState): Tab = es.tabs[es.activeTab]

proc switchTab(es: EditorState, i: int) =
  if i >= 0 and i < es.tabs.len:
    es.activeTab = i
    keyboard.focusNode = nil  # patrz uwaga na górze pliku

proc addTab(es: EditorState) =
  es.tabs.add(newTab())
  switchTab(es, es.tabs.len - 1)

proc closeTab(es: EditorState, i: int) =
  if i < 0 or i >= es.tabs.len: return
  es.tabs.delete(i)
  if es.tabs.len == 0:
    es.tabs.add(newTab())
  if es.activeTab >= es.tabs.len:
    es.activeTab = es.tabs.len - 1
  keyboard.focusNode = nil

proc doOpen(t: Tab) =
  if t.path.len == 0:
    t.statusMsg = "Podaj ścieżkę pliku do otwarcia."
    return
  try:
    t.content = readFile(t.path)
    t.statusMsg = "Wczytano " & t.path
    t.dirty = false
    t.scrollOffset = 0
    t.externallyChanged = false
    ## Rozbudowa (runda 16, "Cofnij zamianę"): historia zamian z
    ## POPRZEDNIEGO pliku w tej samej, ponownie użytej karcie (patrz
    ## wywołanie `doOpen` z przeglądarki plików, `picker-row-...` wyżej)
    ## nie ma żadnego sensu dla NOWO wczytanej treści -- bez tego resetu
    ## "Cofnij" mogłoby przywrócić stan zupełnie INNEGO, wcześniej
    ## otwartego pliku.
    t.replaceUndoStack.setLen(0)
    ## Runda 34 -- ten sam powód co wyżej, teraz też dla ogólnego
    ## cofania pisania (patrz komentarz przy `undoTypingStack` w `Tab`).
    t.undoTypingStack.setLen(0)
    t.redoTypingStack.setLen(0)
    t.lastUndoSnapshotAt = 0.0
    if fileExists(t.path): t.lastKnownMtime = getLastModificationTime(t.path)
    keyboard.focusNode = nil
  except IOError as e:
    t.statusMsg = "Błąd wczytywania: " & e.msg

proc doSave(t: Tab) =
  if t.path.len == 0:
    t.statusMsg = "Podaj ścieżkę pliku do zapisu."
    return
  try:
    writeFile(t.path, t.content)
    t.statusMsg = "Zapisano " & t.path
    t.dirty = false
    t.externallyChanged = false
    t.lastKnownMtime = getLastModificationTime(t.path)
  except IOError as e:
    t.statusMsg = "Błąd zapisu: " & e.msg

proc checkExternalChanges*(es: EditorState) =
  ## Wołane raz na sekundę z `shell.nim` (`tickMain`, przez rejestr
  ## `texteditors` w `shell/state.nim` -- ten sam wzorzec co `clocks`/
  ## `terminals`/`sysmonitors`). Sprawdza WSZYSTKIE karty (nie tylko
  ## aktywną) -- karta w tle też powinna dostać baner, gdy wrócimy do niej.
  for t in es.tabs:
    if t.path.len == 0 or not fileExists(t.path): continue
    let mtime = getLastModificationTime(t.path)
    if mtime != t.lastKnownMtime:
      t.externallyChanged = true
      t.lastKnownMtime = mtime  ## nie pytamy ponownie o TĘ SAMĄ zmianę co klatkę

proc tabLabel(t: Tab): string =
  if t.path.len == 0: "bez nazwy"
  else: t.path.extractFilename()

proc computeFindMatches(t: Tab) =
  ## Przelicza `t.findMatches` od zera z `t.content`/`t.findQuery` --
  ## proste, nieoverlapujące wyszukiwanie (podłańcuch "konsumuje" swoją
  ## długość przed szukaniem kolejnego, ten sam standard co wyszukiwanie
  ## w przeglądarce). Rozbudowa v0.2: rozróżnianie wielkości liter jest
  ## teraz OPCJONALNE (`t.caseSensitive`, przełącznik "Aa" w pasku Znajdź)
  ## zamiast na stałe wyłączone -- gdy wyłączone (domyślnie), obie strony
  ## porównania są sprowadzane do małych liter, dokładnie jak wcześniej;
  ## gdy włączone, porównujemy `line`/`t.findQuery` wprost, bez żadnej
  ## normalizacji.
  ##
  ## Rozbudowa (wyrażenia regularne): gdy `t.useRegex`, ZAMIAST powyższego
  ## prostego `find` na podłańcuchu, wzorzec jest kompilowany przez
  ## `std/re` i dopasowywany przez `findBounds` -- ten sam nieoverlapujący
  ## skan PER LINIA (spójny z trybem zwykłym: dopasowanie o DŁUGOŚCI 0,
  ## np. wzorzec "a*" na tekście bez "a", i tak przesuwa pozycję o
  ## przynajmniej 1 znak, żeby nie zapętlić się w miejscu). Długość
  ## dopasowania w trybie regex jest ZMIENNA (np. "\d+" dopasowuje "1" i
  ## "12345" o różnej długości) -- stąd `findMatches` niesie teraz osobne
  ## pole `length` per dopasowanie, zamiast zakładać (jak poprzednio), że
  ## każde dopasowanie ma długość `t.findQuery.len`.
  t.findMatches.setLen(0)
  t.regexError = ""
  if t.findQuery.len == 0:
    t.findCurrentIdx = -1
    t.findLastQuery = t.findQuery
    return
  let lines = t.content.splitLines()
  if t.useRegex:
    var pattern: Regex
    try:
      pattern = re(t.findQuery, (if t.caseSensitive: {} else: {reIgnoreCase}))
    except CatchableError as e:
      ## Wzorzec się nie kompiluje (np. niedomknięty nawias -- naturalny,
      ## PRZEJŚCIOWY stan w trakcie pisania) -- pokaż błąd zamiast
      ## wywalać się albo cicho pokazywać "brak wyników", co sugerowałoby
      ## poprawny, tylko niepasujący wzorzec.
      t.regexError = e.msg
      t.findCurrentIdx = -1
      t.findLastQuery = t.findQuery
      return
    for i, line in lines:
      var startPos = 0
      while startPos <= line.len:
        ## Rozbudowa (podświetlanie grup przechwytujących): przekazujemy
        ## teraz TEŻ bufor `groupTexts` -- `std/re`'s `findBounds`
        ## wypełnia go PRZECHWYCONYMI PODCIĄGAMI (nie ich pozycjami --
        ## `std/re` w tej wersji nie eksponuje offsetów grup wprost, tylko
        ## same teksty), więc pozycję KAŻDEJ niepustej grupy odtwarzamy
        ## HEURYSTYCZNIE: szukamy jej tekstu w obrębie dopasowanego
        ## fragmentu, zaczynając PO końcu poprzednio zlokalizowanej grupy
        ## (`searchFrom`) -- poprawne dla zwykłego, sekwencyjnego układu
        ## grup (zdecydowana większość realnych wzorców, np. `(\w+)@(\w+)`),
        ## ale może się pomylić przy nietypowych wzorcach z ZAGNIEŻDŻONYMI
        ## albo POWTARZAJĄCYMI SIĘ identycznymi wartościami grup w jednym
        ## dopasowaniu -- świadome, udokumentowane uproszczenie (patrz też
        ## test `test_regex_group_highlight`), nie próba pełnej precyzji
        ## PCRE.
        var groupTexts: array[MaxSubpatterns, string]  ## `MaxSubpatterns` = stała `std/re`, ten sam limit co reszta biblioteki
        let (first, last) = findBounds(line, pattern, groupTexts, startPos)
        if first < 0: break
        let length = last - first + 1
        var groups: seq[tuple[col, length: int]] = @[]
        if length > 0:
          let matchedText = line[first .. last]
          var searchFrom = 0
          for g in groupTexts:
            if g.len == 0: continue
            let gIdx = matchedText.find(g, searchFrom)
            if gIdx >= 0:
              groups.add((first + gIdx, g.len))
              searchFrom = gIdx + g.len
        t.findMatches.add((i, first, max(0, length), groups))
        ## Dopasowanie o długości 0 (np. wzorzec dopuszczający pusty
        ## match) MUSI przesunąć pozycję o przynajmniej 1 -- inaczej
        ## `findBounds` od tego samego `startPos` zwróciłoby TO SAMO
        ## dopasowanie w nieskończoność.
        startPos = if last >= first: last + 1 else: first + 1
  else:
    let query = (if t.caseSensitive: t.findQuery else: t.findQuery.toLowerAscii())
    for i, line in lines:
      let hay = (if t.caseSensitive: line else: line.toLowerAscii())
      var startPos = 0
      while true:
        let idx = hay.find(query, startPos)
        if idx < 0: break
        t.findMatches.add((i, idx, query.len, newSeq[tuple[col, length: int]](0)))
        startPos = idx + max(1, query.len)
  ## NAPRAWIONY BŁĄD: skoro to jest wołane co klatkę (dopóki pasek Znajdź
  ## jest otwarty, patrz `drawEditor`), BEZWARUNKOWE zerowanie
  ## `findCurrentIdx` tutaj cofałoby efekt kliknięcia "▶"/"◀" (albo
  ## Enter) na następnej samej klatce -- nawigacja nigdy by faktycznie nie
  ## ruszyła z miejsca, bo `findNextMatch` ustawiłby indeks, a zaraz potem
  ## `computeFindMatches` (wołane ponownie przy następnym renderze) by go
  ## z powrotem wyzerował. Zamiast tego zerujemy TYLKO gdy ZAPYTANIE
  ## faktycznie się zmieniło od ostatniego przeliczenia (nowe
  ## wyszukiwanie -- zacznij od nieustawionego stanu, niech pierwsze
  ## "▶"/Enter trafi w pierwszy wynik) ALBO gdy bieżący indeks przestał
  ## być poprawny dla nowej listy (np. lista się skurczyła po edycji
  ## dokumentu z TYM SAMYM zapytaniem). Gdy ani jedno, ani drugie (typowy
  ## przypadek: nic istotnego się nie zmieniło między klatkami) -- indeks
  ## przechodzi bez zmian.
  if t.findQuery != t.findLastQuery or t.caseSensitive != t.findLastCaseSensitive or
     t.useRegex != t.findLastUseRegex:
    t.findCurrentIdx = -1
    t.findLastQuery = t.findQuery
    t.findLastCaseSensitive = t.caseSensitive
    t.findLastUseRegex = t.useRegex
  elif t.findCurrentIdx >= t.findMatches.len:
    t.findCurrentIdx = -1

proc scrollToFindMatch(t: Tab) =
  ## Przewija tak, żeby trafienie było widoczne -- NIE ustawia kursora w
  ## dokładnym miejscu (Fidget nie daje nam programowego dostępu do
  ## pozycji kursora w polu `editableText`/`multiline`, patrz duży
  ## komentarz na górze `drawEditor` o `keyboard.focusNode`), tylko
  ## przewija widok tak, żeby linia z dopasowaniem była blisko góry, z
  ## odrobiną kontekstu nad nią -- świadomie uproszczone w porównaniu z
  ## "prawdziwym" skokiem kursora w edytorach z pełnym API tekstowym.
  if t.findCurrentIdx < 0 or t.findCurrentIdx >= t.findMatches.len: return
  let targetLine = t.findMatches[t.findCurrentIdx].line
  t.scrollOffset = max(0, targetLine - 3)

proc findNextMatch(t: Tab) =
  if t.findMatches.len == 0: return
  t.findCurrentIdx = (t.findCurrentIdx + 1) mod t.findMatches.len
  scrollToFindMatch(t)

proc findPrevMatch(t: Tab) =
  if t.findMatches.len == 0: return
  t.findCurrentIdx = (t.findCurrentIdx - 1 + t.findMatches.len) mod t.findMatches.len
  scrollToFindMatch(t)

proc lineColToOffset(content: string, line, col: int): int =
  ## Rozbudowa (Zamień): odwrotność myślenia w `computeFindMatches`
  ## (linia+kolumna liczone na WYNIKU `content.splitLines()`, gdzie KAŻDY
  ## separator -- "\n" ALBO "\r\n" -- jest już "zjedzony" przez
  ## `splitLines` i nie wchodzi do poszczególnych elementów listy) -- na
  ## przesunięcie znakowe w ORYGINALNYM `content`, z zachowanymi
  ## separatorami. NIE licz tego przez `content.splitLines().join("\n")`
  ## i pracę na wyniku -- to by CICHO ZAMIENIAŁO każde "\r\n" na samo
  ## "\n" w całym pliku przy pierwszej zamianie (sprawdzone empirycznie:
  ## `splitLines()` "zjada" `\r\n` jako jeden separator, a `join("\n")`
  ## oddaje z powrotem tylko `\n`) -- realny sposób na ciche przekonwertowanie
  ## stylu końców linii całego pliku przy okazji jednej drobnej zamiany
  ## tekstu, czego nikt by się nie spodziewał. Zamiast tego liczymy
  ## przesunięcie WPROST na oryginalnym stringu, sprawdzając faktyczny
  ## znak/parę znaków napotkanych po drodze -- działa poprawnie
  ## niezależnie od stylu zakończeń linii, nawet przy MIESZANYCH (rzadkie,
  ## ale możliwe -- plik edytowany na dwóch systemach).
  var pos = 0
  var curLine = 0
  while curLine < line and pos < content.len:
    if content[pos] == '\r' and pos + 1 < content.len and content[pos + 1] == '\n':
      pos += 2
      inc curLine
    elif content[pos] == '\n':
      pos += 1
      inc curLine
    else:
      pos += 1
  pos + col

const MaxReplaceUndoDepth = 20  ## głębokość stosu "Cofnij zamianę" -- to migawki CAŁEJ treści dokumentu, nie pojedyncze znaki, więc głębokość rzędu dziesiątek (nie setek/tysięcy jak przy cofaniu klawisz-po-klawiszu) jest z zapasem wystarczająca, bez ryzyka zauważalnego zużycia pamięci na duże pliki

proc pushReplaceUndo(t: Tab, prevContent: string) =
  ## Odkłada stan SPRZED operacji "Zamień"/"Zamień wszystko" -- wołane
  ## TUŻ PRZED faktyczną mutacją `t.content` w obu miejscach niżej, nigdy
  ## po (żeby migawka na stosie zawsze była stanem "da się do niego
  ## wrócić", nie już-zmienionym). Limit głębokości (`MaxReplaceUndoDepth`)
  ## egzekwowany przez obcięcie NAJSTARSZEGO wpisu -- ten sam kompromis co
  ## limity cache'y gdzie indziej w ZDE (`wallpaper.nim`,
  ## `thumbnails.nim`): utrata najstarszej migawki to najwyżej
  ## niedogodność (jedna mniej dostępna operacja "Cofnij"), nigdy utrata
  ## AKTUALNYCH danych.
  t.replaceUndoStack.add(prevContent)
  if t.replaceUndoStack.len > MaxReplaceUndoDepth:
    t.replaceUndoStack.delete(0)

proc undoLastReplace*(t: Tab): bool =
  ## Cofa OSTATNIĄ operację "Zamień"/"Zamień wszystko" -- przywraca
  ## `t.content` do stanu SPRZED niej. Zwraca `false` (bez zmian), gdy
  ## stos jest pusty -- np. nic jeszcze nie zamieniono w tej karcie, albo
  ## wszystkie dostępne cofnięcia już wykorzystano. Świadomie NIE jest to
  ## "redo" w drugą stronę (ponowne "wykonaj cofniętą zamianę") -- ten sam
  ## zakres co reszta tej rozbudowy: cofanie zamian, nie pełny
  ## dwukierunkowy system historii dla całego dokumentu (patrz duży
  ## komentarz przy polu `replaceUndoStack` w typie `Tab`).
  if t.replaceUndoStack.len == 0: return false
  t.content = t.replaceUndoStack.pop()
  t.dirty = true
  true

const
  UndoSnapshotIntervalSec = 0.6  ## debounce migawek Ctrl+Z -- patrz komentarz przy `undoTypingStack`
  MaxUndoTypingDepth = 100       ## głębokość ogólnego cofania pisania (większa niż `MaxReplaceUndoDepth`, bo to podstawowy, częściej używany mechanizm)

proc undoTyping*(t: Tab): bool =
  ## **Runda 34** -- ogólne Ctrl+Z dla zwykłego pisania (nie tylko
  ## "Zamień", patrz `undoLastReplace` wyżej). Zwraca `false`, gdy nie ma
  ## nic do cofnięcia. `keyboard.focusNode = nil` jest KLUCZOWE tutaj --
  ## bez niego Fidget na następnej klatce odtworzyłby swój STARY,
  ## wewnętrzny bufor edycji z powrotem do `t.content`, całkowicie
  ## kasując efekt cofnięcia (patrz duży komentarz przy `undoTypingStack`
  ## w `Tab` po pełne wyjaśnienie).
  if t.undoTypingStack.len == 0: return false
  t.redoTypingStack.add(t.content)
  t.content = t.undoTypingStack.pop()
  t.dirty = true
  keyboard.focusNode = nil
  true

proc redoTyping*(t: Tab): bool =
  ## Symetryczne do `undoTyping` -- "Ponów" (Ctrl+Shift+Z / Ctrl+Y).
  if t.redoTypingStack.len == 0: return false
  t.undoTypingStack.add(t.content)
  t.content = t.redoTypingStack.pop()
  t.dirty = true
  keyboard.focusNode = nil
  true

proc doReplaceCurrent(t: Tab): bool =
  ## Zamienia TYLKO aktualnie "wycelowane" dopasowanie (patrz
  ## `findCurrentIdx`) -- resztę zostawia bez zmian. Zwraca `false` (i nic
  ## nie zmienia), gdy nie ma aktualnego dopasowania ALBO gdy pod
  ## obliczonym przesunięciem nie ma faktycznie tego, czego szukamy --
  ## ten drugi przypadek nie powinien się zdarzyć, jeśli `lineColToOffset`
  ## jest poprawne, ale lepiej ODMÓWIĆ zamiany niż zaryzykować nadpisanie
  ## niewłaściwego fragmentu pliku, gdyby jednak było inaczej (np. przez
  ## nietypowe/mieszane zakończenia linii, których nie przewidzieliśmy).
  ##
  ## Rozbudowa (regex): długość zamienianego fragmentu to teraz
  ## `m.length` (rzeczywista długość DOPASOWANIA, policzona w
  ## `computeFindMatches`), NIE `t.findQuery.len` -- w trybie regex te
  ## dwie wartości mogą się różnić (np. wzorzec "\d+" ma `len == 3`, ale
  ## dopasowuje "1234" o długości 4). W trybie zwykłym `m.length` i
  ## `t.findQuery.len` są zawsze sobie równe, więc zachowanie dla
  ## istniejących dokumentów bez regexa jest identyczne jak wcześniej.
  if t.findCurrentIdx < 0 or t.findCurrentIdx >= t.findMatches.len: return false
  let m = t.findMatches[t.findCurrentIdx]
  let offset = lineColToOffset(t.content, m.line, m.col)
  if offset < 0 or offset + m.length > t.content.len: return false
  let actual = t.content[offset ..< offset + m.length]
  ## Weryfikacja "czy pod przesunięciem faktycznie jest to, czego
  ## szukamy" ma sens tylko w trybie ZWYKŁYM (porównanie z dosłownym
  ## `t.findQuery`) -- w trybie regex `t.findQuery` to WZORZEC, nie
  ## dosłowny tekst, więc nie da się go tak porównać z `actual`. W trybie
  ## regex ufamy pozycji z `computeFindMatches` (przeliczanej co klatkę,
  ## więc zawsze świeżej względem `t.content` -- ten sam poziom zaufania,
  ## jaki reszta tego pliku ma do świeżości `t.findMatches`).
  let matches = t.useRegex or
    (if t.caseSensitive: actual == t.findQuery
     else: actual.toLowerAscii() == t.findQuery.toLowerAscii())
  if not matches: return false
  pushReplaceUndo(t, t.content)
  t.content = t.content[0 ..< offset] & t.replaceQuery & t.content[offset + m.length .. ^1]
  t.dirty = true
  true

proc doReplaceAll(t: Tab): int =
  ## Zwraca liczbę wykonanych zamian. W odróżnieniu od
  ## `doReplaceCurrent` pracuje BEZPOŚREDNIO na `t.content` jako całości
  ## (bez konwersji linia/kolumna w ogóle) -- prostszy i z automatu
  ## bezpieczny dla dowolnego stylu zakończeń linii, bo nigdy nie dzieli
  ## treści na linie ani jej z powrotem nie składa.
  ##
  ## Rozbudowa (regex): w trybie `t.useRegex` UŻYWA WPROST `std/re`
  ## (`replacef`, NIE `replace` -- patrz uczciwa notatka o prawdziwym
  ## błędzie złapanym podczas testowania tej rundy, niżej) zamiast
  ## ręcznej pętli `find`/`add` niżej -- ten sam silnik, którego już
  ## używa `computeFindMatches` do liczenia dopasowań, więc oba miejsca
  ## zgadzają się co do tego, czym jest "dopasowanie". Liczbę zamian
  ## liczymy OSOBNO, PRZED samą zamianą (`findAll` na tym samym wzorcu) --
  ## `re.replacef` zwraca tylko wynikowy string, nie licznik.
  ##
  ## PRAWDZIWY BŁĄD złapany podczas testowania tej rundy (izolowany
  ## program Nim, nie czytanie dokumentacji): `system.replace(string,
  ## Regex, string)` traktuje TRZECI argument WPROST, dosłownie -- string
  ## `"$1 [at] $2"` w wyniku zawiera dosłowne znaki `$1`/`$2`, NIE tekst
  ## przechwyconych grup. To WŁAŚCIWY wariant do tego, `replacef`
  ## (odrębna procedura w `std/re`), interpretuje `$1`/`$2`/... jako
  ## odwołania do grup przechwytujących wzorca (`$$` dla dosłownego znaku
  ## dolara). Bez tego testu "Zamień wszystko" z grupami w trybie regex
  ## wyglądałoby na działające (kompiluje się, nic nie wywala), ale po
  ## cichu wstawiałoby dosłowne "$1" zamiast przechwyconego tekstu --
  ## dokładnie ten rodzaj cichej nieścisłości, którą ten projekt
  ## konsekwentnie łapie właśnie przez uruchamianie, nie samo czytanie.
  if t.findQuery.len == 0: return 0
  if t.useRegex:
    var pattern: Regex
    try:
      pattern = re(t.findQuery, (if t.caseSensitive: {} else: {reIgnoreCase}))
    except CatchableError:
      return 0  ## błędny wzorzec -- `computeFindMatches` już pokazuje `t.regexError`, tu po prostu nic nie robimy
    let count = t.content.findAll(pattern).len
    if count > 0:
      pushReplaceUndo(t, t.content)
      t.content = t.content.replacef(pattern, t.replaceQuery)
      t.dirty = true
    return count
  let query = (if t.caseSensitive: t.findQuery else: t.findQuery.toLowerAscii())
  let haystack = (if t.caseSensitive: t.content else: t.content.toLowerAscii())
  var res = ""
  var pos = 0
  var count = 0
  while true:
    let idx = haystack.find(query, pos)
    if idx < 0:
      res.add(t.content[pos .. ^1])
      break
    res.add(t.content[pos ..< idx])
    res.add(t.replaceQuery)
    pos = idx + t.findQuery.len
    inc count
  if count > 0:
    pushReplaceUndo(t, t.content)
    t.content = res
    t.dirty = true
  count

proc drawHighlighted(t: Tab, x, y, w, h: float32) =
  let lang = languageFor(t.path)
  let lines = t.content.splitLines()
  let visibleLines = max(1, int(h / LineH))
  t.scrollOffset = clamp(t.scrollOffset, 0, max(0, lines.len - visibleLines))
  let first = t.scrollOffset
  let last = min(lines.len, first + visibleLines)

  var state = LineState()
  for i in 0 ..< first:
    if i < lines.len:
      discard tokenizeLine(lines[i], lang, state)

  var ly = y
  for i in first ..< last:
    ## Rozbudowa (Znajdź): podświetlenia dopasowań RYSOWANE PRZED tokenami
    ## tej linii (kolejność deklaracji w Fidget = kolejność Z, później
    ## zadeklarowane leży NA WIERZCHU) -- żeby tekst tokenu był czytelny
    ## NAD kolorowym prostokątem, nie pod nim. Pozycja pozioma liczona
    ## tym samym przybliżeniem `ApproxCharW` co pozycjonowanie tokenów
    ## niżej (font `monospace`, więc przybliżenie jest tu uzasadnione --
    ## nie idealne, ale wystarczające dla podświetlenia, nie dla precyzji
    ## co do piksela).
    if t.findQuery.len > 0:
      for mIdx, m in t.findMatches:
        if m.line == i:
          rectangle "hl-match-" & $i & "-" & $m.col:
            box x + float32(m.col) * ApproxCharW, ly,
                float32(m.length) * ApproxCharW, LineH
            ## Aktualnie "wycelowane" dopasowanie (strzałki ◀/▶ w pasku
            ## Znajdź) dostaje wyraźnie wyższą nieprzezroczystość niż
            ## pozostałe -- ten sam pomysł co podświetlenie "current
            ## match" w każdym innym edytorze z funkcją wyszukiwania,
            ## tylko przez różnicę intensywności zamiast dwóch osobnych
            ## kolorów (prostsze, a wciąż jednoznacznie czytelne).
            fill "#e0a850", (if mIdx == t.findCurrentIdx: 0.55 else: 0.25)
          ## Rozbudowa (regex -- podświetlanie grup przechwytujących):
          ## RYSOWANE PO całym dopasowaniu wyżej (więc leżą na wierzchu,
          ## ta sama zasada "później zadeklarowane = wyżej w Z" co reszta
          ## tego bloku), innym kolorem (fioletowy, wyraźnie różny od
          ## bursztynowego tła całego dopasowania) -- widać od razu, KTÓRA
          ## część dopasowania trafiła do której grupy `(...)`, nie tylko
          ## że całość pasuje. Puste dla trybu bez regexa (`groups` to
          ## zawsze pusty `seq`, patrz `computeFindMatches`), więc pętla
          ## poniżej po prostu nic nie rysuje -- brak zmiany zachowania w
          ## trybie zwykłym.
          for gIdx, g in m.groups:
            rectangle "hl-group-" & $i & "-" & $m.col & "-" & $gIdx:
              box x + float32(g.col) * ApproxCharW, ly + LineH - 3.0,
                  float32(g.length) * ApproxCharW, 3.0
              fill "#a855f7", 0.85

    let tokens = tokenizeLine(lines[i], lang, state)
    var lx = x
    for j, tok in tokens:
      text "hl-" & $i & "-" & $j:
        box lx, ly, w - (lx - x), LineH
        font "monospace", 13, 400, LineH, hLeft, vTop
        fill colorFor(tok.kind)
        characters tok.text
      lx += float32(tok.text.len) * ApproxCharW
    ly += LineH

proc drawTabBar(es: EditorState, w: float32) =
  group "tab-bar":
    box 0, 0, w, TabBarH
    fill "#12151a"

    var tx = 0.0'f32
    for i, t in es.tabs:
      let isActive = i == es.activeTab
      group "tab-" & $i:
        box tx, 0, TabW, TabBarH
        fill (if isActive: "#1b2027" else: "#12151a")
        onHover:
          if not isActive: fill "#181c22"
        onClick:
          switchTab(es, i)

        text "tab-label-" & $i:
          box 10, 0, TabW - 30, TabBarH
          font "sans-serif", 11, (if isActive: 600 else: 400), TabBarH, hLeft, vCenter
          fill (if t.dirty: "#e0a850" elif isActive: "#e8ecf0" else: "#8a94a3")
          characters (if t.dirty: "● " & tabLabel(t) else: tabLabel(t))

        if es.tabs.len > 1:
          group "tab-close-" & $i:
            box TabW - 22, 6, 18, 18
            cornerRadius 3
            fill "#000000", 0.0
            onHover: fill "#3a1f24", 1.0
            onClick:
              closeTab(es, i)
            text "tab-close-x-" & $i:
              box 0, 0, 18, 18
              font "sans-serif", 12, 400, 18, hCenter, vCenter
              fill "#aeb6c2"
              characters "×"
      tx += TabW

    group "tab-add":
      box tx, 4, 22, 22
      cornerRadius 4
      fill "#2a2f36"
      onHover: fill "#3a424d"
      onClick:
        addTab(es)
      text "tab-add-label":
        box 0, 0, 22, 22
        font "sans-serif", 14, 600, 22, hCenter, vCenter
        fill "#e8ecf0"
        characters "+"

proc refreshPickerEntries(t: Tab) =
  ## Foldery najpierw (alfabetycznie), potem WSZYSTKIE pliki
  ## (alfabetycznie) -- w odróżnieniu od pickera tapety w Ustawieniach
  ## (ograniczonego do `.png`/`.jpg`), edytor tekstu może sensownie
  ## otworzyć DOWOLNY plik (nie tylko rozpoznane rozszerzenia tekstowe --
  ## ten sam duch co "Otwórz" zawsze przyjmowało dowolną ścieżkę wpisaną
  ## ręcznie), więc filtrowanie po rozszerzeniu byłoby tu niepotrzebnym
  ## ograniczeniem, nie usprawnieniem.
  t.pickerEntries.setLen(0)
  t.pickerError = ""
  var dirs: seq[string] = @[]
  var files: seq[string] = @[]
  try:
    for kind, path in walkDir(t.pickerDir):
      let name = extractFilename(path)
      if name.len == 0 or name[0] == '.': continue
      case kind
      of pcDir, pcLinkToDir: dirs.add(name)
      of pcFile, pcLinkToFile: files.add(name)
  except OSError as e:
    t.pickerError = "Nie można odczytać katalogu: " & e.msg
    return
  dirs.sort()
  files.sort()
  for d in dirs: t.pickerEntries.add((d, true))
  for f in files: t.pickerEntries.add((f, false))

proc openPicker(t: Tab) =
  let current = t.path.strip()
  t.pickerDir =
    if current.len > 0 and fileExists(current): parentDir(current)
    elif current.len > 0 and dirExists(current): current
    else: getHomeDir()
  t.pickerScroll = 0.0
  t.pickerOpen = true
  refreshPickerEntries(t)

proc drawFilePicker(t: Tab, win: ZdeWindow) =
  ## Pełnoekranowa nakładka nad oknem edytora -- KOPIA wzorca z
  ## `apps/settings/settings.nim` (`drawWallpaperPicker`), włącznie z
  ## kolejnością elementów. **To NIE jest przypadek, że kolejność
  ## wygląda "od tyłu"**: w tej wersji Fidget kolejność malowania
  ## RODZEŃSTWA na tym samym poziomie zagnieżdżenia jest ODWRÓCONA
  ## względem typowego modelu "malarskiego" CSS/Figmy -- element
  ## zadeklarowany WCZEŚNIEJ renderuje się NA WIERZCHU późniejszych, nie
  ## pod spodem (odkryte i szczegółowo opisane w README, sekcja "Nowości
  ## w v0.2 (runda 7)", metodycznymi testami izolującymi zmienne -- ten
  ## sam ustalony fakt, nie nowe odkrycie w tej rundzie, tylko konsekwentne
  ## zastosowanie). Dlatego `drawFilePicker` jest wołane na SAMYM
  ## POCZĄTKU `frame "editor-root"` (patrz `drawEditor` niżej), PRZED
  ## paskiem zakładek/narzędziowym -- i wewnątrz tej nakładki
  ## `picker-panel` (ma być na wierzchu) jest zadeklarowany PRZED
  ## `picker-backdrop` (ma być pod spodem), z tego samego powodu.
  const rowH = 30.0'f32
  const panelW = 480.0'f32
  const panelH = 420.0'f32
  let panelX = (win.size.x - panelW) / 2
  let panelY = (win.size.y - panelH) / 2

  group "picker-panel":
    box panelX, panelY, panelW, panelH
    cornerRadius 8
    fill "#1b2027"

    text "picker-title":
      box 16, 12, panelW - 32, 24
      font "sans-serif", 14, 700, 24, hLeft, vCenter
      fill "#e8ecf0"
      characters "Otwórz plik"

    text "picker-path":
      box 16, 38, panelW - 32, 18
      font "monospace", 10, 400, 18, hLeft, vCenter
      fill "#8a94a3"
      characters t.pickerDir

    group "picker-up-btn":
      box 16, 60, 70, 26
      cornerRadius 4
      fill "#2a2f36"
      onHover: fill "#3a4048"
      onClick:
        let up = parentDir(t.pickerDir)
        if up.len > 0 and up != t.pickerDir:
          t.pickerDir = up
          t.pickerScroll = 0.0
          refreshPickerEntries(t)
      text "picker-up-label":
        box 0, 0, 70, 26
        font "sans-serif", 11, 600, 26, hCenter, vCenter
        fill "#c7ccd3"
        characters "↑ Wyżej"

    group "picker-cancel-btn":
      box panelW - 86, 60, 70, 26
      cornerRadius 4
      fill "#2a2f36"
      onHover: fill "#3a4048"
      onClick:
        t.pickerOpen = false
      text "picker-cancel-label":
        box 0, 0, 70, 26
        font "sans-serif", 11, 600, 26, hCenter, vCenter
        fill "#c7ccd3"
        characters "Anuluj"

    let listTop = 94.0'f32
    let listH = panelH - listTop - 8
    group "picker-listing":
      box 8, listTop, panelW - 16, listH
      clipContent true

      let contentH = float32(t.pickerEntries.len) * rowH
      let maxScroll = max(0.0'f32, contentH - listH)
      onHover:
        if mouse.wheelDelta != 0:
          t.pickerScroll = clamp(t.pickerScroll - mouse.wheelDelta * rowH, 0.0'f32, maxScroll)

      if t.pickerError.len > 0:
        text "picker-err":
          box 8, 8, panelW - 32, 40
          font "sans-serif", 11, 400, 16, hLeft, vTop
          fill "#ff8080"
          characters t.pickerError
      elif t.pickerEntries.len == 0:
        text "picker-empty":
          box 8, 8, panelW - 32, 20
          font "sans-serif", 11, 400, 16, hLeft, vTop
          fill "#8a8f96"
          characters "(pusty katalog)"
      else:
        var y = -t.pickerScroll
        for entry in t.pickerEntries:
          if y > -rowH and y < listH:
            let fullPath = t.pickerDir / entry.name
            group "picker-row-" & entry.name:
              box 0, y, panelW - 16, rowH
              onHover: fill "#242a32"
              onClick:
                if entry.isDir:
                  t.pickerDir = fullPath
                  t.pickerScroll = 0.0
                  refreshPickerEntries(t)
                else:
                  t.path = fullPath
                  t.pickerOpen = false
                  doOpen(t)
              text "picker-row-label-" & entry.name:
                box 8, 0, panelW - 32, rowH
                font "sans-serif", 12, 400, rowH, hLeft, vCenter
                fill (if entry.isDir: "#e8ecf0" else: "#a8d8ff")
                characters (if entry.isDir: "📁 " & entry.name else: "📄 " & entry.name)
          y += rowH

  group "picker-backdrop":
    box 0, 0, win.size.x, win.size.y
    fill "#000000", 0.8
    onClick:
      discard

proc drawEditor*(es: EditorState, win: ZdeWindow) =
  let toolbarH = 34.0'f32
  let statusH = 22.0'f32
  let pad = 6.0'f32
  let t = es.active()

  ## Rozbudowa (Znajdź -- skróty klawiszowe): tylko gdy TO okno jest
  ## aktywne (`win.focused`, patrz `comp/types.nim`/`shell/chrome.nim` --
  ## bez tego Ctrl+F otwierałby pasek Znajdź we WSZYSTKICH otwartych
  ## oknach edytora naraz, nie tylko w tym, na które faktycznie patrzy
  ## użytkownik). `buttonPress[...]` (zdarzenie "wciśnięto W TEJ
  ## KLATCE"), ten sam sprawdzony sposób co w `apps/filemanager/files.nim`.
  if win.focused:
    if (buttonDown[LEFT_CONTROL] or buttonDown[RIGHT_CONTROL]) and buttonPress[LETTER_F]:
      t.findOpen = not t.findOpen
      if not t.findOpen:
        t.findQuery = ""
        t.findMatches.setLen(0)
        t.findCurrentIdx = -1
    if t.findOpen and buttonPress[ESCAPE]:
      ## Escape zamyka pasek Znajdź -- gdy jest otwarty, ale NIE gdy jest
      ## zamknięty (wtedy Escape nie robi tu nic -- to nie miejsce na
      ## zamykanie całego okna edytora, za to odpowiada `shell/chrome.nim`
      ## osobno).
      t.findOpen = false
      t.findQuery = ""
      t.findMatches.setLen(0)
      t.findCurrentIdx = -1
    if t.findOpen and buttonPress[ENTER]:
      ## Enter w polu Znajdź -- idzie do KOLEJNEGO dopasowania (ten sam
      ## gest co "Enter = szukaj dalej" w przeglądarkach). Shift+Enter na
      ## poprzednie -- ten sam sprawdzony sposób odczytu modyfikatora co
      ## Ctrl/Shift w menedżerze plików.
      if buttonDown[LEFT_SHIFT] or buttonDown[RIGHT_SHIFT]:
        findPrevMatch(t)
      else:
        findNextMatch(t)

    ## **Runda 34** -- Ctrl+Z / Ctrl+Shift+Z (i Ctrl+Y jako popularny
    ## alias "Ponów") dla ogólnego cofania pisania, patrz
    ## `undoTyping`/`redoTyping` i duży komentarz przy `undoTypingStack`
    ## w `Tab`. Tak samo jak Ctrl+F wyżej -- tylko gdy TO okno jest
    ## aktywne (`win.focused`), żeby nie cofać treści we WSZYSTKICH
    ## otwartych kartach/oknach edytora naraz.
    if (buttonDown[LEFT_CONTROL] or buttonDown[RIGHT_CONTROL]) and buttonPress[LETTER_Z]:
      if buttonDown[LEFT_SHIFT] or buttonDown[RIGHT_SHIFT]:
        discard redoTyping(t)
      else:
        discard undoTyping(t)
    elif (buttonDown[LEFT_CONTROL] or buttonDown[RIGHT_CONTROL]) and buttonPress[LETTER_Y]:
      discard redoTyping(t)

  frame "editor-root":
    box 0, 0, win.size.x, win.size.y
    fill "#14171c"

    ## Rozbudowa v0.2 (przeglądarka plików) -- na SAMYM POCZĄTKU, patrz
    ## duży komentarz przy `drawFilePicker` wyżej.
    if t.pickerOpen:
      drawFilePicker(t, win)

    drawTabBar(es, win.size.x)

    # -- pasek ścieżki + przyciski --------------------------------------------
    group "toolbar":
      box 0, TabBarH, win.size.x, toolbarH
      fill "#1b2027"

      text "path-field":
        box pad, 4, win.size.x - 404, toolbarH - 8
        font "monospace", 12, 400, toolbarH - 8, hLeft, vCenter
        fill "#e8ecf0"
        editableText true
        selectable true
        if not current.hasKeyboardFocus():
          characters (if t.path.len > 0: t.path else: "/ścieżka/do/pliku.txt")
        onClick:
          keyboard.focus(current)
        onInput:
          t.path = keyboard.input

      ## Rozbudowa v0.2 (przeglądarka plików): przycisk 📂 -- ten sam
      ## rozmiar/odstęp co 🔍 obok, żeby zmieścić się w już ciasnym
      ## pasku narzędzi bez przesuwania reszty przycisków bardziej niż
      ## to konieczne.
      group "btn-browse":
        box win.size.x - 390, 4, 44, toolbarH - 8
        cornerRadius 4
        fill "#2a2f36"
        onHover: fill "#3a424d"
        onClick:
          openPicker(t)
        text "btn-browse-label":
          box 0, 0, 44, toolbarH - 8
          font "sans-serif", 13, 400, toolbarH - 8, hCenter, vCenter
          fill "#e8ecf0"
          characters "📂"

      ## Rozbudowa (Znajdź): przycisk otwierający/zamykający pasek
      ## wyszukiwania -- na lewo od "Otwórz", z tym samym odstępem 6px co
      ## reszta przycisków toolbara (patrz przesunięcia liczone od prawej
      ## krawędzi niżej).
      group "btn-find":
        box win.size.x - 340, 4, 44, toolbarH - 8
        cornerRadius 4
        fill (if t.findOpen: "#2d5f8a" else: "#2a2f36")
        onHover:
          if not t.findOpen: fill "#3a424d"
        onClick:
          t.findOpen = not t.findOpen
          if not t.findOpen:
            t.findQuery = ""
            t.findMatches.setLen(0)
            t.findCurrentIdx = -1
          keyboard.focusNode = nil
        text "btn-find-label":
          box 0, 0, 44, toolbarH - 8
          font "sans-serif", 13, 400, toolbarH - 8, hCenter, vCenter
          fill (if t.findOpen: "#ffffff" else: "#e8ecf0")
          characters "🔍"

      group "btn-open":
        box win.size.x - 290, 4, 64, toolbarH - 8
        cornerRadius 4
        fill "#2a2f36"
        onHover: fill "#3a424d"
        onClick:
          doOpen(t)
        text "btn-open-label":
          box 0, 0, 64, toolbarH - 8
          font "sans-serif", 11, 600, toolbarH - 8, hCenter, vCenter
          fill "#e8ecf0"
          characters "Otwórz"

      group "btn-save":
        box win.size.x - 220, 4, 64, toolbarH - 8
        cornerRadius 4
        fill "#2d5f8a"
        onHover: fill "#3a72a3"
        onClick:
          doSave(t)
          keyboard.focusNode = nil  # patrz komentarz przy "editor-area" niżej
        text "btn-save-label":
          box 0, 0, 64, toolbarH - 8
          font "sans-serif", 11, 600, toolbarH - 8, hCenter, vCenter
          fill "#ffffff"
          characters "Zapisz"

      group "btn-copy":
        box win.size.x - 150, 4, 64, toolbarH - 8
        cornerRadius 4
        fill "#1f2530"
        onHover: fill "#2a323f"
        onClick:
          ## NAPRAWIONY BRAK: kopiowanie/wklejanie POJEDYNCZYCH znaków w
          ## polu edycji już działało (Ctrl+C/Ctrl+V, wbudowane w Fidget --
          ## patrz `fidget/opengl/base.nim`), ale nie było jednoklikowego
          ## sposobu na skopiowanie CAŁEJ zawartości pliku do schowka
          ## systemowego. Patrz `shell/clipboard.nim`.
          if copyToClipboard(t.content):
            t.statusMsg = "Skopiowano całą zawartość do schowka"
          else:
            t.statusMsg = "Brak wl-copy/xclip -- nie można skopiować do schowka systemowego"
          keyboard.focusNode = nil
        text "btn-copy-label":
          box 0, 0, 64, toolbarH - 8
          font "sans-serif", 11, 600, toolbarH - 8, hCenter, vCenter
          fill "#dbe1e8"
          characters "Kopiuj"

      group "btn-paste":
        box win.size.x - 80, 4, 64, toolbarH - 8
        cornerRadius 4
        fill "#1f2530"
        onHover: fill "#2a323f"
        onClick:
          let (text, ok) = pasteFromClipboard()
          if ok:
            t.content.add(text)
            t.dirty = true
            t.statusMsg = "Wklejono ze schowka na koniec dokumentu"
          else:
            t.statusMsg = "Brak wl-paste/xclip -- nie można wkleić ze schowka systemowego"
          keyboard.focusNode = nil
        text "btn-paste-label":
          box 0, 0, 64, toolbarH - 8
          font "sans-serif", 11, 600, toolbarH - 8, hCenter, vCenter
          fill "#dbe1e8"
          characters "Wklej"

    # -- pasek "Znajdź" (rozbudowa) -------------------------------------------
    # Widoczny TYLKO gdy `t.findOpen` (przełączane przyciskiem 🔍 w
    # toolbarze albo Ctrl+F, patrz obsługa skrótów niżej w tym pliku).
    # Rezerwuje własny pas wysokości, TAK SAMO jak baner "plik zmienił się
    # na dysku" poniżej -- oba pasy się sumują w `areaY`.
    let findBarH = (if t.findOpen: 68.0'f32 else: 0.0'f32)
    if t.findOpen:
      computeFindMatches(t)
      group "find-bar":
        box 0, TabBarH + toolbarH, win.size.x, findBarH
        fill "#1b2027"

        text "find-input":
          box pad, 3, win.size.x - 306, 26
          font "monospace", 12, 400, 26, hLeft, vCenter
          fill "#e8ecf0"
          editableText true
          selectable true
          if not current.hasKeyboardFocus() and t.findQuery.len == 0:
            characters "szukaj w dokumencie..."
          else:
            characters t.findQuery
          onClick:
            keyboard.focus(current)
          onInput:
            t.findQuery = keyboard.input

        ## Rozbudowa (wyrażenia regularne): przełącznik ".*" -- ten sam
        ## wzorzec wizualny i to samo miejsce w layoucie co "Aa" (patrz
        ## niżej), tylko przesunięty o 38px w lewo, żeby zrobić mu
        ## miejsce (38 = 34px szerokości przycisku + 4px odstępu) --
        ## POZYCJE WSZYSTKICH pozostałych elementów paska (licznik,
        ## ◀/▶, Zamknij) zostają BEZ ZMIAN, bo to WŁAŚNIE pole
        ## wyszukiwania (wyżej) zostało odpowiednio zwężone, nie one
        ## przesunięte.
        group "find-regex-btn":
          box win.size.x - 298, 3, 34, 26
          cornerRadius 4
          fill (if t.useRegex: "#2d5f8a" else: "#2a2f36")
          onHover:
            if not t.useRegex: fill "#3a424d"
          onClick:
            t.useRegex = not t.useRegex
          text "find-regex-label":
            box 0, 0, 34, 26
            font "monospace", 12, 700, 26, hCenter, vCenter
            fill (if t.useRegex: "#ffffff" else: "#8a94a3")
            characters ".*"

        ## Rozbudowa v0.2 (rozróżnianie wielkości liter): przełącznik
        ## "Aa" -- ten sam wzorzec wizualny co przycisk 🔍 w toolbarze
        ## (kolor akcentu, gdy aktywny), ustawiony między polem
        ## wyszukiwania a licznikiem wyników. Zmiana od razu wpływa na
        ## `computeFindMatches` (wołane co klatkę, dopóki pasek jest
        ## otwarty), więc nie trzeba osobnego przycisku "zastosuj".
        group "find-case-btn":
          box win.size.x - 260, 3, 34, 26
          cornerRadius 4
          fill (if t.caseSensitive: "#2d5f8a" else: "#2a2f36")
          onHover:
            if not t.caseSensitive: fill "#3a424d"
          onClick:
            t.caseSensitive = not t.caseSensitive
          text "find-case-label":
            box 0, 0, 34, 26
            font "sans-serif", 12, 700, 26, hCenter, vCenter
            fill (if t.caseSensitive: "#ffffff" else: "#8a94a3")
            characters "Aa"

        text "find-count":
          box win.size.x - 220, 3, 80, 26
          font "sans-serif", 11, 400, 26, hLeft, vCenter
          fill (if t.regexError.len > 0: "#e08080" else: "#8a94a3")
          characters (
            if t.findQuery.len == 0: ""
            elif t.regexError.len > 0: "błędny wzorzec"
            elif t.findMatches.len == 0: "brak wyników"
            else: $(t.findCurrentIdx + 1) & " z " & $t.findMatches.len)

        group "find-prev":
          box win.size.x - 136, 3, 30, 26
          cornerRadius 4
          fill "#2a2f36"
          onHover: fill "#3a424d"
          onClick: findPrevMatch(t)
          text "find-prev-label":
            box 0, 0, 30, 26
            font "sans-serif", 13, 400, 26, hCenter, vCenter
            fill "#e8ecf0"
            characters "◀"

        group "find-next":
          box win.size.x - 102, 3, 30, 26
          cornerRadius 4
          fill "#2a2f36"
          onHover: fill "#3a424d"
          onClick: findNextMatch(t)
          text "find-next-label":
            box 0, 0, 30, 26
            font "sans-serif", 13, 400, 26, hCenter, vCenter
            fill "#e8ecf0"
            characters "▶"

        group "find-close":
          box win.size.x - 68, 3, 62, 26
          cornerRadius 4
          fill "#000000", 0.0
          stroke "#3a424d"
          strokeWeight 1
          onHover: fill "#2a2f36"
          onClick:
            t.findOpen = false
            t.findQuery = ""
            t.findMatches.setLen(0)
            t.findCurrentIdx = -1
          text "find-close-label":
            box 0, 0, 62, 26
            font "sans-serif", 10, 600, 26, hCenter, vCenter
            fill "#c7ccd3"
            characters "Zamknij"

        ## Rozbudowa (Zamień): drugi wiersz paska, pod polem wyszukiwania.
        ## Celowo BEZ osobnego przełącznika "pokaż zamianę" -- skoro pasek
        ## Znajdź już zajmuje miejsce w layoucie, dołożenie stale
        ## widocznego drugiego wiersza jest prostsze niż osobny stan
        ## zwijania/rozwijania, a w praktyce niewiele kosztuje (jeden
        ## dodatkowy rządek wysokości).
        text "replace-input":
          box pad, 35, win.size.x - 264, 26
          font "monospace", 12, 400, 26, hLeft, vCenter
          fill "#e8ecf0"
          editableText true
          selectable true
          if not current.hasKeyboardFocus() and t.replaceQuery.len == 0:
            characters "zamień na..."
          else:
            characters t.replaceQuery
          onClick:
            keyboard.focus(current)
          onInput:
            t.replaceQuery = keyboard.input

        ## Rozbudowa (runda 16, "Cofnij zamianę"): wąski przycisk "↶"
        ## między polem "zamień na..." (zwężonym, żeby zrobić mu miejsce
        ## -- pozycje "Zamień"/"Zamień wszystko" PO PRAWEJ zostają
        ## nietknięte, ten sam trik co przy dodawaniu ".*" w rundzie 14)
        ## a przyciskiem "Zamień" -- widoczny/klikalny TYLKO gdy jest co
        ## cofnąć (`t.replaceUndoStack.len > 0`). Patrz duży komentarz
        ## przy polu `replaceUndoStack` w typie `Tab` po pełne
        ## uzasadnienie, dlaczego to przycisk, nie skrót Ctrl+Z.
        group "undo-replace-btn":
          let canUndo = t.replaceUndoStack.len > 0
          box win.size.x - 254, 35, 30, 26
          cornerRadius 4
          fill (if canUndo: "#2a2f36" else: "#202429")
          onHover:
            if canUndo: fill "#3a424d"
          onClick:
            if canUndo and undoLastReplace(t):
              computeFindMatches(t)
              t.statusMsg = "Cofnięto ostatnią zamianę"
          text "undo-replace-label":
            box 0, 0, 30, 26
            font "sans-serif", 14, 700, 26, hCenter, vCenter
            fill (if canUndo: "#e8ecf0" else: "#5b6470")
            characters "↶"

        group "replace-one-btn":
          box win.size.x - 220, 35, 100, 26
          cornerRadius 4
          fill (if t.findMatches.len > 0: "#2a2f36" else: "#202429")
          onHover:
            if t.findMatches.len > 0: fill "#3a424d"
          onClick:
            if t.findCurrentIdx < 0 and t.findMatches.len > 0:
              ## Nic nie jest jeszcze "wycelowane" (użytkownik nie kliknął
              ## jeszcze ◀/▶/Enter) -- potraktuj "Zamień" jak "przejdź do
              ## pierwszego, a POTEM zamień", zamiast po prostu nic nie
              ## robić. Bardziej przewidywalne niż wymaganie od
              ## użytkownika ręcznego kliknięcia ▶ najpierw.
              t.findCurrentIdx = 0
            if doReplaceCurrent(t):
              computeFindMatches(t)
              if t.findMatches.len > 0:
                t.findCurrentIdx = min(t.findCurrentIdx, t.findMatches.len - 1)
                scrollToFindMatch(t)
          text "replace-one-label":
            box 0, 0, 100, 26
            font "sans-serif", 11, 600, 26, hCenter, vCenter
            fill (if t.findMatches.len > 0: "#e8ecf0" else: "#5b6470")
            characters "Zamień"

        group "replace-all-btn":
          box win.size.x - 112, 35, 112, 26
          cornerRadius 4
          fill (if t.findMatches.len > 0: "#8a5f2d" else: "#202429")
          onHover:
            if t.findMatches.len > 0: fill "#a3722d"
          onClick:
            let n = doReplaceAll(t)
            if n > 0:
              t.statusMsg = "Zamieniono " & $n & " wystąpień"
              computeFindMatches(t)
          text "replace-all-label":
            box 0, 0, 112, 26
            font "sans-serif", 11, 600, 26, hCenter, vCenter
            fill (if t.findMatches.len > 0: "#ffffff" else: "#5b6470")
            characters "Zamień wszystko"

    # -- baner "plik zmienił się na dysku" (rozbudowa v0.1 "Aurora") --------
    # Pokazuje się TYLKO gdy `checkExternalChanges` (wołane co sekundę z
    # `shell.nim`) wykryje, że coś INNEGO niż ten edytor zmieniło plik pod
    # nami. Rezerwuje własny pas wysokości -- `areaY` niżej się do niego
    # dostosowuje, żeby baner nie nachodził na obszar edycji.
    let bannerH = (if t.externallyChanged: 28.0'f32 else: 0.0'f32)
    if t.externallyChanged:
      group "external-change-banner":
        box 0, TabBarH + toolbarH + findBarH, win.size.x, bannerH
        fill "#4a3820"
        text "external-change-label":
          box pad, 0, win.size.x - 190, bannerH
          font "sans-serif", 11, 600, bannerH, hLeft, vCenter
          fill "#f0d9a0"
          characters "Plik zmienił się na dysku (zmieniony spoza edytora)."
        group "btn-reload":
          box win.size.x - 170, 3, 80, bannerH - 6
          cornerRadius 4
          fill "#2d5f8a"
          onHover: fill "#3a72a3"
          onClick:
            doOpen(t)  ## wczytuje na nowo z dysku -- też czyści `externallyChanged`
          text "btn-reload-label":
            box 0, 0, 80, bannerH - 6
            font "sans-serif", 10, 600, bannerH - 6, hCenter, vCenter
            fill "#ffffff"
            characters "Przeładuj"
        group "btn-dismiss-banner":
          box win.size.x - 84, 3, 74, bannerH - 6
          cornerRadius 4
          fill "#000000", 0.0
          stroke "#6a5a3a"
          strokeWeight 1
          onHover: fill "#5a4a2a"
          onClick:
            t.externallyChanged = false
          text "btn-dismiss-banner-label":
            box 0, 0, 74, bannerH - 6
            font "sans-serif", 10, 600, bannerH - 6, hCenter, vCenter
            fill "#f0d9a0"
            characters "Zignoruj"

    # -- obszar edycji ---------------------------------------------------------
    let areaY = TabBarH + toolbarH + findBarH + bannerH
    let areaH = win.size.y - areaY - statusH
    group "editor-area":
      box 0, areaY, win.size.x, areaH
      fill "#101318"
      clipContent true

      ## NAPRAWIONY BRAK (scroll): `mouse.wheelDelta`, którego używamy
      ## niżej, jest ustawiane przez Fidget TYLKO gdy żadne pole tekstowe
      ## nie ma fokusu klawiatury -- patrz `onScroll` w
      ## `fidget/opengl/base.nim`. Klikanie w tło obszaru edycji (poza
      ## samym polem `content-edit`) zwalnia fokus, żeby scroll znów
      ## trafiał tam, gdzie użytkownik faktycznie najechał myszą.
      onClick:
        keyboard.focusNode = nil

      onHover:
        if mouse.wheelDelta != 0 and not t.wasEditing:
          t.scrollOffset = max(0, t.scrollOffset - int(mouse.wheelDelta))

      var isEditingNow = false
      text "content-edit":
        box pad, pad, win.size.x - pad * 2, areaH - pad * 2
        font "monospace", 13, 400, LineH, hLeft, vTop
        multiline true
        selectable true
        editableText true
        isEditingNow = current.hasKeyboardFocus()
        fill "#dbe1e8", (if isEditingNow: 1.0 else: 0.0)
        if not isEditingNow:
          characters t.content
        onClick:
          keyboard.focus(current)
        onInput:
          if t.content != keyboard.input:
            ## Runda 34 -- migawka PRZED zastosowaniem nowej treści, z
            ## debounce (patrz duży komentarz przy `undoTypingStack` w
            ## `Tab`). Nowa edycja kasuje `redoTypingStack` -- standardowe
            ## zachowanie cofania w każdym edytorze.
            let now = epochTime()
            if t.undoTypingStack.len == 0 or now - t.lastUndoSnapshotAt >= UndoSnapshotIntervalSec:
              t.undoTypingStack.add(t.content)
              if t.undoTypingStack.len > MaxUndoTypingDepth:
                t.undoTypingStack.delete(0)
              t.lastUndoSnapshotAt = now
            t.redoTypingStack.setLen(0)
            t.content = keyboard.input
            t.dirty = true
      t.wasEditing = isEditingNow

      if not isEditingNow:
        drawHighlighted(t, pad, pad, win.size.x - pad * 2, areaH - pad * 2)

    # -- pasek statusu ------------------------------------------------------
    group "status-bar":
      box 0, win.size.y - statusH, win.size.x, statusH
      fill "#1b2027"
      text "status-label":
        box pad, 0, win.size.x - pad * 2, statusH
        font "sans-serif", 11, 400, statusH, hLeft, vCenter
        fill (if t.dirty: "#e0a850" else: "#8a94a3")
        characters (if t.dirty: "● niezapisane zmiany -- " & t.statusMsg else: t.statusMsg)
