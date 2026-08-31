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
    result = &"{x:.0f}"
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

proc drawCalculator*(cs: CalculatorState, win: ZdeWindow) =
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
