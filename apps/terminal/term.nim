import std/[strutils, os, posix]
import fidget
import ../../comp/comp
import ../../shell/clipboard

# ---------------------------------------------------------------------------
# PTY: FFI do pty_shim.c (openpty + fork + exec -- patrz duży komentarz tam)
# ---------------------------------------------------------------------------

{.passC: "-I" & currentSourcePath().parentDir().}
{.compile: "pty_shim.c".}
{.passL: "-lutil".}

proc zdePtySpawn(path: cstring, argv, envp: cstringArray, cwd: cstring,
                  cols, rows: cint, outMaster: ptr cint): cint
  {.importc: "zde_pty_spawn", header: "pty_shim.h".}
proc zdePtyResize(master, cols, rows: cint): cint
  {.importc: "zde_pty_resize", header: "pty_shim.h".}

# ---------------------------------------------------------------------------
# Model: linia jako sekwencja kolorowych fragmentów (wynik parsowania ANSI)
# ---------------------------------------------------------------------------

type
  AnsiSpan* = object
    text*: string
    color*: string   ## kolor hex np. "#5fd7a7"; "" = domyślny (jasnoszary)

  AnsiParseState = object
    ## Stan parsera ANSI przenoszony MIĘDZY wywołaniami `feed` -- dane z PTY
    ## przychodzą w dowolnych porcjach bajtów, więc pojedyncza linia albo
    ## nawet pojedyncza sekwencja ucieczki mogą być rozbite na kilka
    ## odczytów. Bez tego stanu np. `\x1b` na końcu jednego odczytu i `[32m`
    ## na początku następnego wyświetliłyby się jako śmieci zamiast koloru.
    inEscape: bool          ## właśnie w środku sekwencji ESC...
    escBuf: string          ## bajty sekwencji zebrane od ESC
    curColor: string        ## aktualny kolor SGR (trwa między liniami, jak w prawdziwym terminalu)
    curText: string         ## bieżąco budowany fragment tekstu bieżącej linii
    curSpans: seq[AnsiSpan] ## ukończone fragmenty bieżącej (jeszcze niedomkniętej) linii

  TerminalState* = ref object of RootObj
    master: cint             ## deskryptor masterowej strony PTY
    pid: Pid
    buffer*: seq[seq[AnsiSpan]]  ## scrollback, jedna linia = sekwencja kolorowych fragmentów
    input*: string            ## bieżąco wpisywana linia
    scrollOffset*: int        ## 0 = na dole (najnowsze), rośnie w górę
    cwd*: string
    alive*: bool
    lastCols, lastRows: int   ## ostatni rozmiar wysłany przez resizePty (żeby nie spamować ioctl co klatkę)
    ansi: AnsiParseState
    clipMsg: string           ## krótki komunikat zwrotny po Kopiuj/Wklej (patrz shell/clipboard.nim)

const
  MaxScrollback = 4000
  PromptLabel = "zde$ "
  DefaultTextColor = "#d6dbe0"
  ## Przybliżone wymiary komórki znaku dla fontu "monospace" @ 13px, jak
  ## używanego w drawTerminal -- niedokładne (brak dostępu do prawdziwych
  ## metryk fontu na tym poziomie), ale wystarczające, żeby SIGWINCH niósł
  ## sensowny rozmiar zamiast sztywnego 80x24 niezależnie od okna.
  ApproxCharW = 7.8'f32
  ApproxCharH = 18.0'f32

  ## Podstawowe kolory SGI (30-37 / 90-97) -- paleta zbliżona do typowych
  ## motywów terminali ciemnych (żeby pasowało do reszty ZDE, patrz
  ## shell/state.nim).
  AnsiColors: array[8, string] = [
    "#3b4048", # 30 czarny  (stonowany, żeby był czytelny na ciemnym tle)
    "#e5666b", # 31 czerwony
    "#7fbf7f", # 32 zielony
    "#e0c060", # 33 żółty
    "#6ea8dd", # 34 niebieski
    "#c98adb", # 35 magenta
    "#5fc9c9", # 36 cyan
    "#d6dbe0", # 37 biały/domyślny
  ]
  AnsiColorsBright: array[8, string] = [
    "#6b7280", "#ff8a8f", "#a3e0a3", "#f0d878",
    "#8fc4f5", "#e2a8f0", "#8fe5e5", "#ffffff",
  ]

proc setNonBlocking(fd: cint) =
  ## Patrz duży komentarz przy `canReadNow` niżej -- ten sam powód co
  ## przy poprzedniej wersji na potokach: bez tego czytanie z PTY mogłoby
  ## zawiesić cały zde-shell.
  let flags = fcntl(fd, F_GETFL, 0)
  if flags != -1:
    discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

proc canReadNow(fd: cint): bool =
  ## Nieblokujące sprawdzenie "czy jest coś do odczytania" przez `select()`
  ## z zerowym timeoutem -- patrz analogiczny, dużo bardziej szczegółowy
  ## komentarz w poprzedniej wersji tego pliku (i w NAPRAWY.md) o tym, że
  ## `Process.hasData` z `std/osproc` na POSIX-ie BLOKUJE (timeout `nil`)
  ## mimo nazwy sugerującej nieblokujące sprawdzenie. Tu robimy to samo na
  ## surowym deskryptorze PTY, poprawnie, z timeoutem `{0, 0}`.
  var rd: TFdSet
  FD_ZERO(rd)
  FD_SET(fd, rd)
  var tv = Timeval(tv_sec: Time(0), tv_usec: Suseconds(0))
  result = select(fd + 1, addr rd, nil, nil, addr tv) > 0

# ---------------------------------------------------------------------------
# Parser ANSI/SGR -- przyrostowy, bajt po bajcie, stan trwa między odczytami
# ---------------------------------------------------------------------------

proc sgrToColor(codes: seq[int]): string =
  ## Zwraca NOWY kolor po zastosowaniu sekwencji kodów SGR, albo "@RESET@"
  ## jako specjalny znacznik "wróć do domyślnego" (żeby odróżnić od "nie
  ## zmieniaj", bo pusty string też oznacza domyślny -- potrzebujemy je
  ## rozróżnić w `feed`, gdzie pusty string oznacza "brak zmiany").
  result = ""
  if codes.len == 0:
    return "@RESET@"
  for c in codes:
    case c
    of 0: return "@RESET@"
    of 30..37: result = AnsiColors[c - 30]
    of 90..97: result = AnsiColorsBright[c - 90]
    of 39: return "@RESET@"  # domyślny kolor pierwszoplanowy
    else: discard  # pogrubienie/podkreślenie/tło itd. -- pomijamy (brak odpowiednika w Fidget bez custom renderowania)

proc flushSpan(st: var AnsiParseState) =
  if st.curText.len > 0:
    st.curSpans.add(AnsiSpan(text: st.curText, color: st.curColor))
    st.curText = ""

proc flushLine(t: TerminalState) =
  flushSpan(t.ansi)
  t.buffer.add(t.ansi.curSpans)
  t.ansi.curSpans = @[]
  if t.buffer.len > MaxScrollback:
    t.buffer.delete(0)

proc processEscape(t: TerminalState, seqStr: string) =
  ## `seqStr` to zawartość sekwencji BEZ wiodącego ESC, np. "[32m" albo
  ## "[2J" albo "]0;tytul\x07" (OSC). Interpretujemy TYLKO CSI-SGR (kolor);
  ## resztę świadomie i po cichu pomijamy -- to właśnie ta granica, którą
  ## opisuje komentarz na górze pliku (brak pełnej emulacji VT100).
  if seqStr.len == 0: return
  if seqStr[0] == '[':
    let body = seqStr[1 ..^ 1]
    if body.len > 0 and body[^1] == 'm':
      let params = body[0 ..< body.len-1]
      var codes: seq[int] = @[]
      if params.len == 0:
        codes = @[0]
      else:
        for p in params.split(';'):
          if p.len == 0: codes.add(0)
          else:
            try: codes.add(parseInt(p))
            except ValueError: discard
      let newColor = sgrToColor(codes)
      if newColor.len > 0:
        flushSpan(t.ansi)
        t.ansi.curColor = (if newColor == "@RESET@": "" else: newColor)
    # inne sekwencje CSI (ruch kursora, czyszczenie ekranu itd.) -- pomijamy.
  # sekwencje OSC/inne (zaczynające się od ']', '(', ')' itd.) -- pomijamy.

proc feedByte(t: TerminalState, b: char) =
  var st = addr t.ansi
  if st.inEscape:
    st.escBuf.add(b)
    # CSI kończy się bajtem "końcowym" w zakresie 0x40-0x7E (np. 'm', 'J',
    # 'H'...); OSC (]) kończy się BEL (\x07) albo ST (ESC \). Upraszczamy:
    # traktujemy pierwszy bajt >= 0x40 (poza samym '[') jako koniec, oraz
    # \x07 jako awaryjny terminator dla OSC.
    let isCsiTerm = st.escBuf.len >= 2 and b in {'\x40'..'\x7E'} and b != '['
    let isOscTerm = b == '\x07'
    if isCsiTerm or isOscTerm:
      processEscape(t, st.escBuf)
      st.inEscape = false
      st.escBuf = ""
    elif st.escBuf.len > 128:
      # sekwencja podejrzanie długa -- porzuć, żeby nie rosła bez końca
      st.inEscape = false
      st.escBuf = ""
    return

  case b
  of '\x1b':
    st.inEscape = true
    st.escBuf = ""
  of '\n':
    flushLine(t)
  of '\r':
    discard  # brak śledzenia kolumny -- traktujemy jak nic (log liniowy)
  of '\x08':  # backspace -- usuń ostatni znak z bieżącego fragmentu
    if st.curText.len > 0:
      st.curText.setLen(st.curText.len - 1)
    elif st.curSpans.len > 0 and st.curSpans[^1].text.len > 0:
      st.curSpans[^1].text.setLen(st.curSpans[^1].text.len - 1)
  of '\x07', '\x00', '\x0e', '\x0f':
    discard  # BEL i inne pojedyncze bajty sterujące -- pomijamy po cichu
  else:
    st.curText.add(b)

proc feed(t: TerminalState, data: string) =
  for b in data:
    feedByte(t, b)

# ---------------------------------------------------------------------------
# Uruchamianie / zamykanie procesu na PTY
# ---------------------------------------------------------------------------

proc buildEnv(): seq[string] =
  result = @[]
  var hasTerm = false
  for k, v in envPairs():
    if k == "TERM":
      result.add("TERM=xterm-256color")
      hasTerm = true
    else:
      result.add(k & "=" & v)
  if not hasTerm:
    result.add("TERM=xterm-256color")

proc newTerminal*(startDir = ""): TerminalState =
  result = TerminalState(cwd: (if startDir.len > 0: startDir else: getHomeDir()))
  result.ansi.curColor = ""

  let shellPath = "/bin/bash"
  var argv = @[shellPath, "--login"]
  let envList = buildEnv()

  var argvC = allocCStringArray(argv)
  var envC = allocCStringArray(envList)
  defer:
    deallocCStringArray(argvC)
    deallocCStringArray(envC)

  var master: cint = -1
  let pid = zdePtySpawn(shellPath.cstring, argvC, envC, result.cwd.cstring,
                         80.cint, 24.cint, addr master)
  if pid < 0:
    result.alive = false
    result.buffer.add(@[AnsiSpan(text: "Nie udało się uruchomić powłoki na PTY (openpty/fork nieudane).", color: "#e5666b")])
    return

  result.master = master
  result.pid = Pid(pid)
  result.alive = true
  result.lastCols = 80
  result.lastRows = 24
  setNonBlocking(result.master)

  result.buffer.add(@[AnsiSpan(text: "Zenit Desktop Environment -- terminal na prawdziwym PTY", color: "#5fd7a7")])
  result.buffer.add(@[AnsiSpan(text: "Katalog startowy: " & result.cwd, color: "")])
  result.buffer.add(@[AnsiSpan(text: "", color: "")])

proc mapToString(arr: openArray[char]): string =
  ## Pomocniczy konwerter openArray[char] -> string (Nim nie ma tego wprost
  ## dla surowych buforów odczytanych przez `posix.read`).
  result = newString(arr.len)
  for i, c in arr: result[i] = c

proc pollOutput*(t: TerminalState) =
  if not t.alive: return

  # Sprawdź, czy dziecko wciąż żyje (WNOHANG -- nie czekaj).
  var status: cint = 0
  let r = waitpid(t.pid, status, WNOHANG)
  if r == t.pid:
    t.alive = false
    flushLine(t)  # domknij ewentualną niedokończoną ostatnią linię
    t.buffer.add(@[AnsiSpan(text: "", color: "")])
    t.buffer.add(@[AnsiSpan(text: "[powłoka zakończona]", color: "#8a94a3")])
    return

  var raw: array[4096, char]
  try:
    while canReadNow(t.master):
      let n = posix.read(t.master, addr raw[0], raw.len)
      if n > 0:
        feed(t, raw.toOpenArray(0, n - 1).mapToString())
      else:
        break
  except IOError:
    discard

proc sendLine*(t: TerminalState, line: string) =
  if not t.alive:
    t.buffer.add(@[AnsiSpan(text: "(powłoka nie działa -- nie ma do kogo wysłać polecenia)", color: "#e5666b")])
    return
  let toWrite = line & "\n"
  var written = 0
  while written < toWrite.len:
    let n = posix.write(t.master, unsafeAddr toWrite[written], toWrite.len - written)
    if n <= 0: break
    written += n

proc resizePty*(t: TerminalState, cols, rows: int) =
  ## Wołane z drawTerminal, gdy rozmiar okna się zmienił -- wysyła
  ## TIOCSWINSZ (jądro samo dostarczy SIGWINCH procesom w grupie terminala).
  ## Ograniczone do faktycznej zmiany, żeby nie robić syscall co klatkę.
  if not t.alive: return
  if cols == t.lastCols and rows == t.lastRows: return
  if zdePtyResize(t.master.cint, cols.cint, rows.cint) == 0:
    t.lastCols = cols
    t.lastRows = rows

proc close*(t: TerminalState) =
  if t.alive:
    discard kill(t.pid, SIGTERM)
  if t.master >= 0:
    discard posix.close(t.master)
    t.master = -1

proc copyHistory(t: TerminalState) =
  ## NAPRAWIONY BRAK: Ctrl+C/Ctrl+V JUŻ działały na polu wpisywania
  ## (`editableText true` + `selectable true` -- obsługiwane automatycznie
  ## przez Fidget, patrz `fidget/opengl/base.nim`), ale nie było jak
  ## skopiować HISTORII wyjścia terminala -- to zwykłe, nieedytowalne
  ## węzły `text`, nie pole tekstowe z mechanizmem zaznaczania. Ten
  ## przycisk łączy pełen bufor scrollbacku w zwykły tekst (bez kolorów
  ## ANSI -- schowek systemowy i tak ich nie przenosi) i wysyła do
  ## prawdziwego schowka systemowego przez zewnętrzne narzędzie (patrz
  ## `shell/clipboard.nim` -- Fidget nie eksponuje uchwytu GLFW publicznie,
  ## więc bezpośrednie wywołanie `setClipboardString` nie jest możliwe z
  ## kodu aplikacji).
  var lines: seq[string] = @[]
  for spans in t.buffer:
    var line = ""
    for sp in spans: line.add(sp.text)
    lines.add(line)
  if copyToClipboard(lines.join("\n")):
    t.clipMsg = "Skopiowano historię do schowka (" & $lines.len & " linii)"
  else:
    t.clipMsg = "Brak wl-copy/xclip -- nie można skopiować do schowka systemowego"

proc pasteIntoInput(t: TerminalState) =
  let (text, ok) = pasteFromClipboard()
  if ok:
    t.input.add(text)
    keyboard.input = t.input
    t.clipMsg = ""
  else:
    t.clipMsg = "Brak wl-paste/xclip -- nie można wkleić ze schowka systemowego"

# --- Rysowanie ------------------------------------------------------------

proc drawTerminal*(t: TerminalState, win: ZdeWindow) =
  let lineH = ApproxCharH
  let inputH = 28.0'f32
  let toolbarH = 24.0'f32
  let pad = 8.0'f32
  let bodyH = win.size.y - inputH - toolbarH - pad * 4
  let visibleLines = max(1, int(bodyH / lineH))

  # Powiadom PTY o bieżącym rozmiarze okna (w "znakach", przybliżenie --
  # patrz stała ApproxCharW/ApproxCharH). Robimy to tutaj, nie w osobnym
  # tick(), bo drawTerminal i tak jest wołane co klatkę z chrome.nim, a
  # `resizePty` sam ogranicza się do faktycznych zmian.
  let cols = max(10, int((win.size.x - pad * 2) / ApproxCharW))
  let rows = max(3, visibleLines)
  resizePty(t, cols, rows)

  frame "term-root":
    box 0, 0, win.size.x, win.size.y
    fill "#101418"

    group "term-toolbar":
      box pad, pad, win.size.x - pad * 2, toolbarH
      group "btn-copy-history":
        box 0, 0, 90, toolbarH
        cornerRadius 4
        fill "#1f2530"
        onHover: fill "#2a323f"
        onClick:
          copyHistory(t)
        text "btn-copy-history-label":
          box 0, 0, 90, toolbarH
          font "sans-serif", 11, 600, toolbarH, hCenter, vCenter
          fill "#dbe1e8"
          characters "Kopiuj"
      text "clip-msg":
        box 98, 0, win.size.x - pad * 2 - 98, toolbarH
        font "sans-serif", 11, 400, toolbarH, hLeft, vCenter
        fill "#8a94a3"
        characters t.clipMsg

    group "scrollback":
      box pad, pad + toolbarH + pad, win.size.x - pad * 2, bodyH
      clipContent true

      ## NAPRAWIONY BRAK (scroll działający tylko czasami): `mouse.wheelDelta`
      ## jest ustawiane przez Fidget TYLKO gdy ŻADNE pole tekstowe nie ma
      ## fokusu klawiatury -- patrz `onScroll` w `fidget/opengl/base.nim`
      ## (`if keyboard.focusNode != nil: textBox.scrollBy(...) else:
      ## mouse.wheelDelta += yoffset`). W terminalu pole wpisywania poleceń
      ## ma fokus niemal caly czas w normalnym użyciu -- więc scroll po
      ## scrollbacku w ogóle by nie działał, dopóki ktoś by explicite nie
      ## kliknął gdzieś, żeby "zgubić" fokus. Zwalniamy fokus, gdy mysz
      ## wjeżdża nad scrollback (jedyne inne focusowalne pole w tym oknie
      ## to input-row poniżej -- rozłączny obszar, więc to bezpieczne: nie
      ## zwalnia fokusu, gdy user wciąż najeżdża na pole wpisywania).
      ## Koszt: samo najechanie myszą nad historię (bez scrollowania) też
      ## zwalnia fokus -- trzeba kliknąć pole wpisywania jeszcze raz, żeby
      ## dalej pisać. Rozsądny kompromis jak na terminal v1.
      onHover:
        if keyboard.focusNode != nil:
          keyboard.focusNode = nil
        if mouse.wheelDelta != 0:
          t.scrollOffset = clamp(
            t.scrollOffset - int(mouse.wheelDelta),
            0,
            max(0, t.buffer.len - visibleLines),
          )

      let total = t.buffer.len
      let lastIdx = max(0, total - t.scrollOffset)
      let firstIdx = max(0, lastIdx - visibleLines)
      var y = 0.0'f32
      for i in firstIdx ..< lastIdx:
        # Każda linia to sekwencja kolorowych fragmentów (AnsiSpan) --
        # renderujemy je jako kolejne text-node'y obok siebie, z x
        # przesuwanym o przybliżoną szerokość znaku razy długość
        # fragmentu (fonty monospace -- przybliżenie wystarczające, bez
        # dostępu do prawdziwych metryk fontu na tym poziomie).
        var x = 0.0'f32
        let spans = t.buffer[i]
        if spans.len == 0:
          text "line" & $i & "-empty":
            box 0, y, 1, lineH
            font "monospace", 13, 400, lineH, hLeft, vTop
            fill DefaultTextColor
            characters ""
        for j, sp in spans:
          if sp.text.len == 0: continue
          text "line" & $i & "-" & $j:
            box x, y, win.size.x - pad * 2 - x, lineH
            font "monospace", 13, 400, lineH, hLeft, vTop
            fill (if sp.color.len > 0: sp.color else: DefaultTextColor)
            characters sp.text
          x += float32(sp.text.len) * ApproxCharW
        y += lineH

    group "input-row":
      box pad, win.size.y - inputH - pad, win.size.x - pad * 2 - 60, inputH
      fill "#1a2027"
      cornerRadius 4

      text "prompt":
        box 8, 0, 60, inputH
        font "monospace", 13, 700, inputH, hLeft, vCenter
        fill "#5fd7a7"
        characters PromptLabel

      text "input-field":
        box 60, 0, win.size.x - pad * 2 - 60 - 68, inputH
        font "monospace", 13, 400, inputH, hLeft, vCenter
        fill "#ffffff"
        editableText true
        selectable true
        if not current.hasKeyboardFocus():
          characters t.input
        onClick:
          keyboard.focus(current)
        onInput:
          if buttonPress[ENTER]:
            let cmd = t.input
            t.input = ""
            keyboard.input = ""
            if cmd.strip().len > 0:
              sendLine(t, cmd)
          else:
            t.input = keyboard.input

    group "btn-paste":
      box win.size.x - pad - 52, win.size.y - inputH - pad, 52, inputH
      cornerRadius 4
      fill "#1f2530"
      onHover: fill "#2a323f"
      onClick:
        pasteIntoInput(t)
      text "btn-paste-label":
        box 0, 0, 52, inputH
        font "sans-serif", 11, 600, inputH, hCenter, vCenter
        fill "#dbe1e8"
        characters "Wklej"
