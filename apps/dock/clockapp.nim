import std/[times, strformat]
import fidget
import ../../comp/comp

type
  ClockState* = ref object of RootObj
    dummy: bool  ## stan nie jest tu potrzebny (czas czytamy na bieżąco z
                 ## `times.now()` przy każdym rysowaniu) -- typ zostaje dla
                 ## spójności z resztą aplikacji (`new*State` + `draw*`).

proc newClockState*(): ClockState =
  ClockState()

## Fidget nie ma osobnych prymitywów `ellipse`/`line` -- tylko `rectangle`
## (który z `cornerRadius >= połowa boku` staje się kołem) i `rotation`
## (obraca węzeł wokół lewego-górnego rogu jego boxa, w stopniach, zgodnie
## z ruchem wskazówek zegara). Każdą wskazówkę/kreskę rysujemy więc jako
## cienki prostokąt zaczynający się w środku tarczy, obrócony o properkąt.

proc drawRadialBar(idPrefix: string, cx, cy, length, thicknessPx, angleDeg: float32, color: string) =
  rectangle idPrefix:
    box cx, cy - thicknessPx / 2, length, thicknessPx
    fill color
    rotation angleDeg

proc drawClock*(cs: ClockState, win: ZdeWindow) =
  let now = now()
  let pad = 16.0'f32
  let dialSize = min(win.size.x - pad * 2, win.size.y - 120)
  let cx = win.size.x / 2
  let cy = pad + dialSize / 2
  let radius = dialSize / 2

  frame "clock-root":
    box 0, 0, win.size.x, win.size.y
    fill "#12161c"

    # -- tarcza (kwadrat z cornerRadius = promień -> koło) -------------------
    rectangle "dial":
      box cx - radius, cy - radius, dialSize, dialSize
      fill "#181f28"
      stroke "#3a4756"
      strokeWeight 2
      cornerRadius radius

    # -- znaczniki godzin (12 kresek, jako obrócone paski od środka) ---------
    for h in 0 ..< 12:
      let angle = float32(h) * 30.0'f32 - 90.0'f32
      drawRadialBar("tick-" & $h, cx, cy, radius - 6, 2, angle, "#5b6b7d")

    # -- wskazówki ------------------------------------------------------------
    let hour24 = now.hour
    let hour12 = float32(hour24 mod 12) + float32(now.minute) / 60.0'f32
    let hourAngle = hour12 * 30.0'f32 - 90.0'f32
    let minuteAngle = float32(now.minute) * 6.0'f32 - 90.0'f32
    let secondAngle = float32(now.second) * 6.0'f32 - 90.0'f32

    drawRadialBar("hand-hour", cx, cy, radius * 0.5, 5, hourAngle, "#e8ecf0")
    drawRadialBar("hand-minute", cx, cy, radius * 0.72, 3.5, minuteAngle, "#cfd6dd")
    drawRadialBar("hand-second", cx, cy, radius * 0.8, 1.5, secondAngle, "#e0685a")

    rectangle "hub":
      box cx - 4, cy - 4, 8, 8
      fill "#e8ecf0"
      cornerRadius 4

    # -- cyfrowy zegar + data pod tarczą --------------------------------------
    text "digital":
      box 0, cy + radius + 14, win.size.x, 32
      font "monospace", 22, 600, 32, hCenter, vTop
      fill "#e8ecf0"
      characters now.format("HH:mm:ss")

    const dniTygodnia = ["poniedziałek", "wtorek", "środa", "czwartek",
                         "piątek", "sobota", "niedziela"]
    let dow = dniTygodnia[ord(now.weekday)]
    text "date":
      box 0, cy + radius + 48, win.size.x, 24
      font "sans-serif", 13, 400, 20, hCenter, vTop
      fill "#8a94a3"
      characters &"{dow}, {now.monthday:02} {($now.month)} {now.year}"
