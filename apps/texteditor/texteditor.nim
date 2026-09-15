import std/[os, strutils, times]
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
    findMatches: seq[tuple[line, col: int]]
    findCurrentIdx: int  ## indeks w `findMatches` aktualnie "wycelowanego" dopasowania, -1 = brak
    findLastQuery: string  ## poprzednia wartość `findQuery` -- do odróżnienia "nowe zapytanie" od "ta sama treść, inny dokument", patrz `computeFindMatches`
    ## Rozbudowa (Zamień): tekst, na który zamieniane są dopasowania --
    ## osobne pole od `findQuery`, bo to logicznie dwie różne rzeczy
    ## (czego szukamy vs. na co zamieniamy), mimo że w UI stoją obok
    ## siebie w tym samym pasku.
    replaceQuery: string

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
  ## w przeglądarce), bez rozróżniania wielkości liter (świadome
  ## uproszczenie -- przełącznik "uwzględniaj wielkość liter" to możliwa
  ## przyszła rozbudowa).
  t.findMatches.setLen(0)
  if t.findQuery.len == 0:
    t.findCurrentIdx = -1
    t.findLastQuery = t.findQuery
    return
  let lines = t.content.splitLines()
  let queryLower = t.findQuery.toLowerAscii()
  for i, line in lines:
    let lineLower = line.toLowerAscii()
    var startPos = 0
    while true:
      let idx = lineLower.find(queryLower, startPos)
      if idx < 0: break
      t.findMatches.add((i, idx))
      startPos = idx + max(1, queryLower.len)
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
  if t.findQuery != t.findLastQuery:
    t.findCurrentIdx = -1
    t.findLastQuery = t.findQuery
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

proc doReplaceCurrent(t: Tab): bool =
  ## Zamienia TYLKO aktualnie "wycelowane" dopasowanie (patrz
  ## `findCurrentIdx`) -- resztę zostawia bez zmian. Zwraca `false` (i nic
  ## nie zmienia), gdy nie ma aktualnego dopasowania ALBO gdy pod
  ## obliczonym przesunięciem nie ma faktycznie tego, czego szukamy --
  ## ten drugi przypadek nie powinien się zdarzyć, jeśli `lineColToOffset`
  ## jest poprawne, ale lepiej ODMÓWIĆ zamiany niż zaryzykować nadpisanie
  ## niewłaściwego fragmentu pliku, gdyby jednak było inaczej (np. przez
  ## nietypowe/mieszane zakończenia linii, których nie przewidzieliśmy).
  if t.findCurrentIdx < 0 or t.findCurrentIdx >= t.findMatches.len: return false
  let m = t.findMatches[t.findCurrentIdx]
  let offset = lineColToOffset(t.content, m.line, m.col)
  if offset < 0 or offset + t.findQuery.len > t.content.len: return false
  let actual = t.content[offset ..< offset + t.findQuery.len]
  if actual.toLowerAscii() != t.findQuery.toLowerAscii(): return false
  t.content = t.content[0 ..< offset] & t.replaceQuery & t.content[offset + t.findQuery.len .. ^1]
  t.dirty = true
  true

proc doReplaceAll(t: Tab): int =
  ## Zwraca liczbę wykonanych zamian. W odróżnieniu od
  ## `doReplaceCurrent` pracuje BEZPOŚREDNIO na `t.content` jako całości
  ## (bez konwersji linia/kolumna w ogóle) -- prostszy i z automatu
  ## bezpieczny dla dowolnego stylu zakończeń linii, bo nigdy nie dzieli
  ## treści na linie ani jej z powrotem nie składa.
  if t.findQuery.len == 0: return 0
  let queryLower = t.findQuery.toLowerAscii()
  let contentLower = t.content.toLowerAscii()
  var res = ""
  var pos = 0
  var count = 0
  while true:
    let idx = contentLower.find(queryLower, pos)
    if idx < 0:
      res.add(t.content[pos .. ^1])
      break
    res.add(t.content[pos ..< idx])
    res.add(t.replaceQuery)
    pos = idx + t.findQuery.len
    inc count
  if count > 0:
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
                float32(t.findQuery.len) * ApproxCharW, LineH
            ## Aktualnie "wycelowane" dopasowanie (strzałki ◀/▶ w pasku
            ## Znajdź) dostaje wyraźnie wyższą nieprzezroczystość niż
            ## pozostałe -- ten sam pomysł co podświetlenie "current
            ## match" w każdym innym edytorze z funkcją wyszukiwania,
            ## tylko przez różnicę intensywności zamiast dwóch osobnych
            ## kolorów (prostsze, a wciąż jednoznacznie czytelne).
            fill "#e0a850", (if mIdx == t.findCurrentIdx: 0.55 else: 0.25)

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

  frame "editor-root":
    box 0, 0, win.size.x, win.size.y
    fill "#14171c"

    drawTabBar(es, win.size.x)

    # -- pasek ścieżki + przyciski --------------------------------------------
    group "toolbar":
      box 0, TabBarH, win.size.x, toolbarH
      fill "#1b2027"

      text "path-field":
        box pad, 4, win.size.x - 350, toolbarH - 8
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
          box pad, 3, win.size.x - 230, 26
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

        text "find-count":
          box win.size.x - 220, 3, 80, 26
          font "sans-serif", 11, 400, 26, hLeft, vCenter
          fill "#8a94a3"
          characters (
            if t.findQuery.len == 0: ""
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
          box pad, 35, win.size.x - 230, 26
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
