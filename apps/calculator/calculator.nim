import std/[strformat, strutils, math]
import fidget
import ../../comp/comp

type
  CalcOp = enum opNone, opAdd, opSub, opMul, opDiv

  CalculatorState* = ref object of RootObj
    display*: string      ## to, co widać na wyświetlaczu
    accumulator: float64   ## wynik częściowy
    pendingOp: CalcOp
    freshEntry: bool        ## czy następna cyfra zaczyna nową liczbę

proc newCalculatorState*(): CalculatorState =
  CalculatorState(display: "0", accumulator: 0.0, pendingOp: opNone, freshEntry: true)

proc trimZeros(s: string): string =
  ## Usuwa końcowe zera po przecinku (ale zostawia samą liczbę całkowitą bez kropki).
  if '.' notin s: return s
  var res = s
  while res.endsWith("0"):
    res = res[0 ..< ^1]
  if res.endsWith("."):
    res = res[0 ..< ^1]
  res

proc formatNumber(x: float64): string =
  if x == x.trunc and abs(x) < 1e15:
    ## Rozbudowa v0.2 (odkryte podczas testowania klawiatury fizycznej,
    ## NIE związane z samą klawiaturą -- ten sam błąd występował już
    ## wcześniej przy kliknięciu myszą w "=", po prostu nikt wcześniej
    ## nie przetestował rzeczywistego działania na tyle dokładnie, żeby
    ## to zauważyć): `&"{x:.0f}"` w tej wersji Nim/strformat zostawia
    ## KROPKĘ na końcu nawet przy zerze miejsc po przecinku (`4.0` →
    ## `"4."`, nie `"4"`) -- potwierdzone bezpośrednim testem
    ## izolowanym. `.strip(chars = {'.'})` usuwa ją bezpiecznie z OBU
    ## stron (liczby ujemne jak "-12." nie mają kropki na początku, więc
    ## nie ma ryzyka obcięcia czegoś innego).
    result = (&"{x:.0f}").strip(chars = {'.'})
  else:
    let raw = &"{x:.8f}"
    result = raw.trimZeros().strip(chars = {'.'})

proc inputDigit(cs: CalculatorState, d: string) =
  if cs.freshEntry or cs.display == "0":
    cs.display = d
    cs.freshEntry = false
  else:
    if cs.display.len < 16:
      cs.display.add(d)

proc inputDot(cs: CalculatorState) =
  if cs.freshEntry:
    cs.display = "0."
    cs.freshEntry = false
  elif '.' notin cs.display:
    cs.display.add(".")

proc currentValue(cs: CalculatorState): float64 =
  try: parseFloat(cs.display)
  except ValueError: 0.0

proc applyPending(cs: CalculatorState) =
  let v = cs.currentValue()
  case cs.pendingOp
  of opNone: cs.accumulator = v
  of opAdd: cs.accumulator += v
  of opSub: cs.accumulator -= v
  of opMul: cs.accumulator *= v
  of opDiv:
    if v == 0.0:
      cs.display = "Błąd: dzielenie przez 0"
      cs.accumulator = 0.0
      cs.pendingOp = opNone
      cs.freshEntry = true
      return
    cs.accumulator /= v

proc setOp(cs: CalculatorState, op: CalcOp) =
  if cs.display.startsWith("Błąd"):
    return
  applyPending(cs)
  cs.pendingOp = op
  cs.display = formatNumber(cs.accumulator)
  cs.freshEntry = true

proc equals(cs: CalculatorState) =
  if cs.display.startsWith("Błąd"):
    return
  applyPending(cs)
  cs.pendingOp = opNone
  cs.display = formatNumber(cs.accumulator)
  cs.freshEntry = true

proc clearAll(cs: CalculatorState) =
  cs.display = "0"
  cs.accumulator = 0.0
  cs.pendingOp = opNone
  cs.freshEntry = true

proc toggleSign(cs: CalculatorState) =
  if cs.display.startsWith("Błąd"): return
  if cs.display.startsWith("-"):
    cs.display = cs.display[1 .. ^1]
  elif cs.display != "0":
    cs.display = "-" & cs.display

proc percent(cs: CalculatorState) =
  if cs.display.startsWith("Błąd"): return
  cs.display = formatNumber(cs.currentValue() / 100.0)

## Rozbudowa v0.2 (klawiatura fizyczna): dotąd kalkulator w OGÓLE nie
## obsługiwał klawiatury -- jedynym sposobem interakcji było klikanie
## przycisków myszą (`grep buttonPress apps/calculator/calculator.nim`
## przed tą rundą nie dawało ŻADNEGO wyniku). To był realny, dotkliwy
## brak: każdy inny kalkulator na pulpicie (GNOME, KDE, macOS, Windows)
## przyjmuje wpisywanie z klawiatury jako podstawowy sposób obsługi, nie
## dodatek. `backspace` to NOWA operacja, bez odpowiednika wśród
## przycisków myszą -- kasuje OSTATNIĄ cyfrę (w przeciwieństwie do "C",
## które czyści WSZYSTKO), dokładnie tak jak Backspace działa w każdym
## innym polu tekstowym w ZDE.
proc backspace(cs: CalculatorState) =
  if cs.display.startsWith("Błąd"):
    cs.display = "0"
    cs.freshEntry = true
    return
  if cs.freshEntry: return  ## nic nie zaczęto wpisywać -- nie ma czego kasować
  if cs.display.len <= 1 or (cs.display.len == 2 and cs.display[0] == '-'):
    cs.display = "0"
    cs.freshEntry = true
  else:
    cs.display = cs.display[0 ..< ^1]

proc drawCalculator*(cs: CalculatorState, win: ZdeWindow) =
  ## Rozbudowa v0.2 (klawiatura fizyczna, patrz duży komentarz przy
  ## `backspace` wyżej): tylko gdy TO okno jest aktywne (`win.focused`,
  ## ten sam sprawdzony wzorzec co Ctrl+F w `apps/texteditor/texteditor.nim`
  ## -- bez tego wpisywanie cyfr wpływałoby na WSZYSTKIE otwarte okna
  ## kalkulatora naraz, nie tylko na to, na które faktycznie patrzy
  ## użytkownik). Obsługuje zarówno górny rząd cyfr, jak i klawiaturę
  ## numeryczną (`NUMBER_*`/`KP_*`) -- to dwa fizycznie różne zestawy
  ## klawiszy na większości klawiatur, więc oba warte wsparcia równolegle,
  ## nie tylko jeden z nich.
  if win.focused:
    let shiftHeld = buttonDown[LEFT_SHIFT] or buttonDown[RIGHT_SHIFT]
    if buttonPress[NUMBER_0] or buttonPress[KP_0]: inputDigit(cs, "0")
    if buttonPress[NUMBER_1] or buttonPress[KP_1]: inputDigit(cs, "1")
    if buttonPress[NUMBER_2] or buttonPress[KP_2]: inputDigit(cs, "2")
    if buttonPress[NUMBER_3] or buttonPress[KP_3]: inputDigit(cs, "3")
    if buttonPress[NUMBER_4] or buttonPress[KP_4]: inputDigit(cs, "4")
    if buttonPress[NUMBER_5] or buttonPress[KP_5]:
      ## Shift+5 = "%" na typowym układzie US -- ten sam symbol co na
      ## klawiszu fizycznym, więc naturalny gest, nie coś do zapamiętania.
      if shiftHeld: percent(cs)
      else: inputDigit(cs, "5")
    if buttonPress[NUMBER_6] or buttonPress[KP_6]: inputDigit(cs, "6")
    if buttonPress[NUMBER_7] or buttonPress[KP_7]: inputDigit(cs, "7")
    if buttonPress[NUMBER_8] or buttonPress[KP_8]: inputDigit(cs, "8")
    if buttonPress[NUMBER_9] or buttonPress[KP_9]: inputDigit(cs, "9")
    if buttonPress[PERIOD] or buttonPress[KP_DECIMAL]: inputDot(cs)
    if buttonPress[MINUS] or buttonPress[KP_SUBTRACT]: setOp(cs, opSub)
    if buttonPress[KP_MULTIPLY] or buttonPress[LETTER_X]: setOp(cs, opMul)
    if buttonPress[SLASH] or buttonPress[KP_DIVIDE]: setOp(cs, opDiv)
    if buttonPress[KP_ADD]: setOp(cs, opAdd)
    ## Klawisz "=" bez Shift to "=" (policz), ze Shift to "+" (dodaj) --
    ## dokładnie te dwa symbole widoczne fizycznie na TYM SAMYM klawiszu
    ## typowej klawiatury US, więc to odwzorowanie 1:1, nie umowna
    ## konwencja do zapamiętania.
    if buttonPress[EQUAL]:
      if shiftHeld: setOp(cs, opAdd)
      else: equals(cs)
    if buttonPress[ENTER] or buttonPress[KP_ENTER]: equals(cs)
    if buttonPress[BACKSPACE]: backspace(cs)
    if buttonPress[ESCAPE]: clearAll(cs)

  let dispH = 70.0'f32
  let pad = 6.0'f32
  let rows = 5
  let cols = 4
  let gridH = win.size.y - dispH - pad * 2
  let cellW = (win.size.x - pad * (cols.float32 + 1)) / cols.float32
  let cellH = (gridH - pad * (rows.float32 - 1)) / rows.float32

  # etykieta, akcja, kolor-tła, kolor-tekstu, kolumna, wiersz, szerokość(w komórkach)
  let buttons = [
    ("C", proc() = clearAll(cs), "#3a4048", "#ffffff", 0, 0, 1),
    ("±", proc() = toggleSign(cs), "#3a4048", "#ffffff", 1, 0, 1),
    ("%", proc() = percent(cs), "#3a4048", "#ffffff", 2, 0, 1),
    ("÷", proc() = setOp(cs, opDiv), "#d78a3d", "#ffffff", 3, 0, 1),
    ("7", proc() = inputDigit(cs, "7"), "#2a2f36", "#ffffff", 0, 1, 1),
    ("8", proc() = inputDigit(cs, "8"), "#2a2f36", "#ffffff", 1, 1, 1),
    ("9", proc() = inputDigit(cs, "9"), "#2a2f36", "#ffffff", 2, 1, 1),
    ("×", proc() = setOp(cs, opMul), "#d78a3d", "#ffffff", 3, 1, 1),
    ("4", proc() = inputDigit(cs, "4"), "#2a2f36", "#ffffff", 0, 2, 1),
    ("5", proc() = inputDigit(cs, "5"), "#2a2f36", "#ffffff", 1, 2, 1),
    ("6", proc() = inputDigit(cs, "6"), "#2a2f36", "#ffffff", 2, 2, 1),
    ("−", proc() = setOp(cs, opSub), "#d78a3d", "#ffffff", 3, 2, 1),
    ("1", proc() = inputDigit(cs, "1"), "#2a2f36", "#ffffff", 0, 3, 1),
    ("2", proc() = inputDigit(cs, "2"), "#2a2f36", "#ffffff", 1, 3, 1),
    ("3", proc() = inputDigit(cs, "3"), "#2a2f36", "#ffffff", 2, 3, 1),
    ("+", proc() = setOp(cs, opAdd), "#d78a3d", "#ffffff", 3, 3, 1),
    ("0", proc() = inputDigit(cs, "0"), "#2a2f36", "#ffffff", 0, 4, 2),
    (".", proc() = inputDot(cs), "#2a2f36", "#ffffff", 2, 4, 1),
    ("=", proc() = equals(cs), "#5fb0ff", "#0f1115", 3, 4, 1),
  ]

  frame "calc-root":
    box 0, 0, win.size.x, win.size.y
    fill "#14171c"

    text "display":
      box pad, 0, win.size.x - pad * 2, dispH
      font "monospace", 30, 500, dispH, hRight, vCenter
      fill "#e8ecf0"
      characters cs.display

    for (label, action, bg, fg, col, row, span) in buttons:
      let bx = pad + col.float32 * (cellW + pad)
      let by = dispH + pad + row.float32 * (cellH + pad)
      let bw = cellW * span.float32 + pad * float32(span - 1)
      group "btn-" & label & "-" & $col & "-" & $row:
        box bx, by, bw, cellH
        cornerRadius 8
        fill bg
        onHover: fill "#4a5058"
        onClick: action()
        text "btn-label-" & label & "-" & $col & "-" & $row:
          box 0, 0, bw, cellH
          font "sans-serif", 18, 500, cellH, hCenter, vCenter
          fill fg
          characters label
