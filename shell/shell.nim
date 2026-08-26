import std/[times, sequtils]
import fidget
import fidget/opengl/base as fidgetBase  # dla MainLoopMode (nie re-eksportowane przez `fidget`)
import ../comp/comp
import ../apps/terminal/term
import ../apps/file-manager/files

# ---------------------------------------------------------------------------
# Stan globalny shellu
# ---------------------------------------------------------------------------

var
  compositor = newCompositor(vec2(1280, 800))
  clockText = "--:--:--"
  lastClockUpdate = 0.0
  terminals: seq[TerminalState] = @[]  ## rejestr żywych terminali do odpytywania w tick()

const
  Bg1 = "#0f1115"
  Bg2 = "#151920"
  PanelBg = "#1b2027"
  PanelBgHover = "#242b34"
  AccentColor = "#5fb0ff"
  TitlebarH = 30.0'f32

# ---------------------------------------------------------------------------
# Uruchamianie aplikacji
# ---------------------------------------------------------------------------

proc launchTerminal() =
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

proc launchFileManager() =
  let fs = newFileManager()
  discard compositor.openWindow(
    "Menedżer plików", wkFileManager,
    size = vec2(620, 440),
    drawBody = proc(w: ZdeWindow) = drawFileManager(fs, w),
  )

proc launchAbout() =
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

# ---------------------------------------------------------------------------
# Pulpit / tło
# ---------------------------------------------------------------------------

proc drawWallpaper() =
  frame "wallpaper":
    box 0, 0, windowSize.x, windowSize.y
    fill Bg1
    # Delikatny gradient zastępczy -- pasek u góry ciut jaśniejszy niż reszta,
    # żeby pulpit nie wyglądał jak jednolita plama.
    rectangle "wallpaper-band":
      box 0, 0, windowSize.x, windowSize.y * 0.55
      fill Bg2

    text "wallpaper-label":
      box 24, windowSize.y - 64, 400, 30
      font "sans-serif", 13, 400, 20, hLeft, vBottom
      fill "#3c4753"
      characters "Zenit Linux -- ZDE"

# ---------------------------------------------------------------------------
# Chrome pojedynczego okna (pasek tytułu, obramowanie, uchwyt resize)
# ---------------------------------------------------------------------------

proc drawWindowChrome(win: ZdeWindow) =
  let isFocused = win.id == compositor.focusedId
  let borderColor = if isFocused: AccentColor else: "#2a2f36"

  group "win-" & $win.id:
    box win.pos.x, win.pos.y, win.size.x, win.size.y
    fill "#000000", 0.0
    stroke borderColor
    strokeWeight (if isFocused: 1.5 else: 1.0)
    zLevel win.zIndex

    onMouseDown:
      if compositor.focusedId != win.id:
        compositor.focus(win.id)

    # -- pasek tytułu -----------------------------------------------------
    group "titlebar":
      box 0, 0, win.size.x, TitlebarH
      fill (if isFocused: PanelBgHover else: PanelBg)

      onMouseDown:
        if not compositor.isDragging:
          compositor.beginMove(win.id, mouse.pos)

      text "title":
        box 10, 0, win.size.x - 110, TitlebarH
        font "sans-serif", 12, 600, TitlebarH, hLeft, vCenter
        fill "#e8ecf0"
        characters win.title

      # przycisk minimalizacji
      group "btn-min":
        box win.size.x - 90, 4, 26, TitlebarH - 8
        cornerRadius 3
        fill "#2c333c"
        onHover: fill "#3a424d"
        onClick: compositor.minimizeWindow(win.id)
        text "min-label":
          box 0, 0, 26, TitlebarH - 8
          font "sans-serif", 13, 700, TitlebarH - 8, hCenter, vCenter
          fill "#e8ecf0"
          characters "–"

      # przycisk maksymalizacji (tylko gdy okno jest resizable)
      if win.resizable:
        group "btn-max":
          box win.size.x - 60, 4, 26, TitlebarH - 8
          cornerRadius 3
          fill "#2c333c"
          onHover: fill "#3a424d"
          onClick: compositor.toggleMaximize(win.id)
          text "max-label":
            box 0, 0, 26, TitlebarH - 8
            font "sans-serif", 12, 700, TitlebarH - 8, hCenter, vCenter
            fill "#e8ecf0"
            characters (if win.maximized: "❐" else: "☐")

      # przycisk zamknięcia
      if win.closable:
        group "btn-close":
          box win.size.x - 30, 4, 26, TitlebarH - 8
          cornerRadius 3
          fill "#2c333c"
          onHover: fill "#c0392b"
          onClick: compositor.closeWindow(win.id)
          text "close-label":
            box 0, 0, 26, TitlebarH - 8
            font "sans-serif", 13, 700, TitlebarH - 8, hCenter, vCenter
            fill "#e8ecf0"
            characters "×"

    # -- treść okna (ciało aplikacji) --------------------------------------
    group "body":
      box 0, TitlebarH, win.size.x, win.size.y - TitlebarH
      clipContent true
      if not win.drawBody.isNil:
        win.drawBody(win)

    # -- uchwyt do zmiany rozmiaru (róg dolno-prawy) -----------------------
    if win.resizable and not win.maximized:
      group "resize-handle":
        box win.size.x - 14, win.size.y - 14, 14, 14
        fill "#000000", 0.0
        onMouseDown:
          if not compositor.isDragging:
            compositor.beginResize(win.id, mouse.pos, reBottomRight)

# ---------------------------------------------------------------------------
# Pasek zadań + launcher
# ---------------------------------------------------------------------------

proc drawTaskbar() =
  let y = windowSize.y - TaskbarHeight
  frame "taskbar":
    box 0, y, windowSize.x, TaskbarHeight
    fill PanelBg
    zLevel 10_000  # zawsze na wierzchu, ponad wszystkimi oknami

    group "launcher-btn":
      box 6, 4, 90, TaskbarHeight - 8
      cornerRadius 4
      fill (if compositor.launcherOpen: AccentColor else: PanelBgHover)
      onHover:
        if not compositor.launcherOpen:
          fill "#2f3844"
      onClick:
        compositor.launcherOpen = not compositor.launcherOpen
      text "launcher-label":
        box 0, 0, 90, TaskbarHeight - 8
        font "sans-serif", 12, 700, TaskbarHeight - 8, hCenter, vCenter
        fill "#0f1115"
        characters "☰ ZDE"

    # przyciski otwartych okien
    var x = 104.0'f32
    for win in compositor.windows:
      let isActive = win.id == compositor.focusedId and not win.minimized
      let w = 160.0'f32
      group "task-" & $win.id:
        box x, 4, w, TaskbarHeight - 8
        cornerRadius 4
        fill (if isActive: "#2c333c" elif win.minimized: "#1c2026" else: "#232830")
        onHover: fill "#323a44"
        onClick:
          if win.minimized or compositor.focusedId != win.id:
            compositor.restoreWindow(win.id)
          else:
            compositor.minimizeWindow(win.id)
        text "task-label-" & $win.id:
          box 8, 0, w - 16, TaskbarHeight - 8
          font "sans-serif", 11, 500, TaskbarHeight - 8, hLeft, vCenter
          fill (if win.minimized: "#767c85" else: "#e8ecf0")
          characters win.title
      x += w + 4

    # zegar
    text "clock":
      box windowSize.x - 100, 0, 90, TaskbarHeight
      font "monospace", 13, 500, TaskbarHeight, hRight, vCenter
      fill "#cfd6dd"
      characters clockText

proc drawLauncher() =
  let w = 220.0'f32
  let itemH = 34.0'f32
  let items = [
    ("🖥  Terminal", launchTerminal),
    ("📁  Menedżer plików", launchFileManager),
    ("ℹ  O systemie", launchAbout),
  ]
  let h = float32(items.len) * itemH + 12
  let y = windowSize.y - TaskbarHeight - h - 6

  frame "launcher":
    box 6, y, w, h
    fill PanelBg
    stroke "#333b45"
    strokeWeight 1
    cornerRadius 6
    zLevel 20_000

    onClickOutside:
      compositor.launcherOpen = false

    var iy = 6.0'f32
    for (label, action) in items:
      group "launcher-item-" & label:
        box 6, iy, w - 12, itemH - 4
        cornerRadius 4
        fill "#000000", 0.0
        onHover: fill PanelBgHover
        onClick:
          action()
          compositor.launcherOpen = false
        text "launcher-item-label-" & label:
          box 10, 0, w - 32, itemH - 4
          font "sans-serif", 13, 400, itemH - 4, hLeft, vCenter
          fill "#e8ecf0"
          characters label
      iy += itemH

# ---------------------------------------------------------------------------
# Główna pętla rysowania
# ---------------------------------------------------------------------------

proc drawMain() =
  compositor.setScreenSize(vec2(windowSize.x, windowSize.y))

  drawWallpaper()

  for win in compositor.windowsInZOrder():
    drawWindowChrome(win)

  drawTaskbar()

  if compositor.launcherOpen:
    drawLauncher()

  # -- globalna obsługa przeciągania/zmiany rozmiaru okien -----------------
  if compositor.isDragging:
    compositor.updateDrag(mouse.pos)
    if not mouse.down:
      compositor.endDrag()

  # -- Alt+Tab: przełączanie focusu -----------------------------------------
  if keyboard.altKey and buttonPress[TAB]:
    compositor.cycleFocus()

  # -- Escape zamyka launcher ------------------------------------------------
  if compositor.launcherOpen and buttonPress[ESCAPE]:
    compositor.launcherOpen = false

proc tickMain() =
  # Odpytujemy wyjście wszystkich terminali co klatkę (nieblokująco).
  for ts in terminals:
    pollOutput(ts)

  let t = epochTime()
  if t - lastClockUpdate >= 1.0:
    lastClockUpdate = t
    clockText = now().format("HH:mm:ss")

when isMainModule:
  loadFont("sans-serif", "IBMPlexSans-Regular.ttf")
  loadFont("monospace", "IBMPlexMono-Regular.ttf")
  setTitle("Zenit Desktop Environment")
  startFidget(
    drawMain,
    tick = tickMain,
    fullscreen = true,
    mainLoopMode = fidgetBase.RepaintOnFrame,
  )
