import std/sequtils
import fidget
import ../comp/comp
import ../apps/terminal/term
import ../apps/filemanager/files
import ../apps/clock/clockapp
import ../apps/texteditor/texteditor
import ../apps/calculator/calculator
import ../apps/sysmonitor/sysmonitor
import state

proc launchTerminal*() =
  let ts = newTerminal()
  terminals.add(ts)
  let win = compositor.openWindow(
    "Terminal", wkTerminal,
    size = vec2(700, 420),
    drawBody = proc(w: ZdeWindow) = drawTerminal(ts, w),
  )
  win.onClose = proc(w: ZdeWindow) =
    term.close(ts)
    terminals.keepItIf(it != ts)

proc launchFileManager*() =
  let fs = newFileManager()
  discard compositor.openWindow(
    "Menedżer plików", wkFileManager,
    size = vec2(620, 440),
    drawBody = proc(w: ZdeWindow) = drawFileManager(fs, w),
  )

proc launchClock*() =
  let cs = newClockState()
  discard compositor.openWindow(
    "Zegar", wkGeneric,
    size = vec2(320, 380),
    drawBody = proc(w: ZdeWindow) = drawClock(cs, w),
  )

proc launchTextEditor*() =
  let es = newEditorState()
  discard compositor.openWindow(
    "Edytor tekstu", wkGeneric,
    size = vec2(640, 460),
    drawBody = proc(w: ZdeWindow) = drawEditor(es, w),
  )

proc launchCalculator*() =
  let cs = newCalculatorState()
  discard compositor.openWindow(
    "Kalkulator", wkGeneric,
    size = vec2(300, 420),
    resizable = false,
    drawBody = proc(w: ZdeWindow) = drawCalculator(cs, w),
  )

proc launchSysMonitor*() =
  let sm = newSysMonState()
  sysmonitors.add(sm)
  let win = compositor.openWindow(
    "Monitor systemu", wkGeneric,
    size = vec2(360, 320),
    drawBody = proc(w: ZdeWindow) = drawSysMonitor(sm, w),
  )
  win.onClose = proc(w: ZdeWindow) =
    sysmonitors.keepItIf(it != sm)

proc launchAbout*() =
  discard compositor.openWindow(
    "O systemie", wkAbout,
    size = vec2(420, 260),
    resizable = false,
    drawBody = proc(w: ZdeWindow) =
      frame "about-root":
        box 0, 0, w.size.x, w.size.y
        fill "#181c22"
        text "logo":
          box 20, 20, w.size.x - 40, 36
          font "sans-serif", 22, 700, 30, hLeft, vTop
          fill AccentColor
          characters "Zenit Desktop Environment"
        text "body":
          box 20, 66, w.size.x - 40, w.size.y - 90
          font "sans-serif", 13, 400, 20, hLeft, vTop
          fill "#cfd6dd"
          characters "ZDE -- środowisko graficzne dla Zenit Linux, " &
            "napisane w 100% w Nimie z użyciem biblioteki Fidget. " &
            "Kompozytor okien, terminal i menedżer plików to natywne " &
            "aplikacje ZDE, bez zależności od X11/GTK/Qt."
  )
