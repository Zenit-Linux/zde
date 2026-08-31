import fidget
import ../comp/comp
import state
import launcher_apps

proc drawTaskbar*() =
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

proc drawLauncher*() =
  let w = 220.0'f32
  let itemH = 34.0'f32
  let items = [
    ("🖥  Terminal", launchTerminal),
    ("📁  Menedżer plików", launchFileManager),
    ("🕐  Zegar", launchClock),
    ("📝  Edytor tekstu", launchTextEditor),
    ("🧮  Kalkulator", launchCalculator),
    ("📊  Monitor systemu", launchSysMonitor),
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
