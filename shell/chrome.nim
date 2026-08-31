import fidget
import ../comp/comp
import state

proc drawWindowChrome*(win: ZdeWindow) =
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
