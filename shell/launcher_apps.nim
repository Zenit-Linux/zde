import std/sequtils
import fidget
import ../comp/comp
import ../apps/terminal/term
import ../apps/filemanager/files
import ../apps/clock/clockapp
import ../apps/texteditor/texteditor
import ../apps/calculator/calculator
import ../apps/sysmonitor/sysmonitor
import ../apps/settings/settings
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

proc launchClock*() =
  let cs = newClockState()
  clocks.add(cs)  ## rejestr do odliczania alarmów/minutnika w tle, patrz state.nim
  let win = compositor.openWindow(
    "Zegar", wkGeneric,
    size = vec2(320, 420),
    drawBody = proc(w: ZdeWindow) = drawClock(cs, w),
  )
  win.onClose = proc(w: ZdeWindow) =
    clocks.keepItIf(it != cs)

proc launchTextEditor*(startPath = "") =
  ## Rozbudowa (otwieranie plików z menedżera plików): parametr
  ## `startPath` -- domyślnie pusty (dokładnie dawne zachowanie: pusta,
  ## nowa zakładka), ale `launchFileManager` niżej podaje bezwzględną
  ## ścieżkę przy podwójnym kliknięciu na pliku. `newEditorState`/`newTab`
  ## (`apps/texteditor/texteditor.nim`) już wcześniej wspierały wczytanie
  ## startowej ścieżki -- brakowało tylko przekazania jej AŻ TUTAJ z
  ## menedżera plików.
  let es = newEditorState(startPath)
  texteditors.add(es)  ## rejestr do wykrywania zmian pliku na dysku w tle, patrz state.nim
  let win = compositor.openWindow(
    "Edytor tekstu", wkGeneric,
    size = vec2(640, 460),
    drawBody = proc(w: ZdeWindow) = drawEditor(es, w),
  )
  win.onClose = proc(w: ZdeWindow) =
    texteditors.keepItIf(it != es)

proc launchFileManager*() =
  let fs = newFileManager()
  ## Rozbudowa (otwieranie plików z menedżera): `files.nim` celowo NIE
  ## importuje tego modułu (uniknięcie cyklu -- to WŁAŚNIE ten moduł
  ## importuje `files.nim`), więc podłączamy akcję "otwórz w edytorze"
  ## tutaj, z zewnątrz, przez zwykłe domknięcie zapisane na stanie.
  ## Musi być zdefiniowane PO `launchTextEditor` powyżej -- Nim (w
  ## przeciwieństwie do C) NIE pozwala tu na odwołanie w przód do proc
  ## zadeklarowanego niżej w tym samym module bez osobnej deklaracji
  ## wyprzedzającej, więc kolejność tych dwóch procedur w pliku jest
  ## istotna, nie przypadkowa.
  fs.openFile = proc(path: string) = launchTextEditor(path)
  discard compositor.openWindow(
    "Menedżer plików", wkFileManager,
    size = vec2(620, 440),
    drawBody = proc(w: ZdeWindow) = drawFileManager(fs, w),
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

proc launchSettings*() =
  let ss = newSettingsState()
  discard compositor.openWindow(
    "Ustawienia", wkSettings,
    size = vec2(620, 620),
    drawBody = proc(w: ZdeWindow) = drawSettings(ss, w),
  )

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
