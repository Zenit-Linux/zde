import fidget
import ../comp/comp
import state

## Rozbudowa v0.1 ("Aurora"): odświeżony wygląd ramki okna -- zaokrąglone
## rogi, cieńszy/spójniejszy zestaw kolorów z `state.nim`, subtelna jasna
## linia na górnej krawędzi paska tytułu (typowy "glass highlight" ze
## współczesnych systemów), oraz mały kolorowy wskaźnik aktywności zamiast
## samej zmiany koloru obramowania.
##
## Uwaga o zaokrągleniu: `cornerRadius` w tym silniku zaokrągla WSZYSTKIE
## 4 rogi grupy jednakowo (nie ma tu odpowiednika CSS-owego
## `border-radius: 8px 8px 0 0` na same górne rogi) i `clipContent` tnie do
## prostokątnego bounding-boxa, nie do zaokrąglonego kształtu rodzica --
## dlatego pasek tytułu i ciało okna zostają prostokątne, a promień
## zaokrąglenia jest tylko na zewnętrznej ramce/tle całego okna. Przy
## rozsądnym, niedużym promieniu (`RadiusMd`) różnica jest kosmetyczna
## (cieniutki, prawie niewidoczny róg tła w narożnikach), a unikamy przy
## tym zgadywania, czy silnik obsługuje zaokrąglone maskowanie.

proc drawWindowChrome*(win: ZdeWindow) =
  let isFocused = win.id == compositor.focusedId
  ## Rozbudowa (skróty klawiszowe per-aplikacja): patrz duży komentarz
  ## przy `ZdeWindow.focused` w `comp/types.nim` -- to JEDYNE miejsce,
  ## które to pole ustawia, tuż przed narysowaniem treści okna niżej.
  win.focused = isFocused
  let borderColor = if isFocused: AccentColor else: GlassBorder

  group "win-" & $win.id:
    box win.pos.x, win.pos.y, win.size.x, win.size.y
    ## Tło całej ramki (widoczne jako cienki rąbek w zaokrąglonych rogach,
    ## patrz komentarz wyżej) -- ton zbliżony do paska tytułu, żeby ten
    ## rąbek nie rzucał się w oczy jako osobny kolor.
    fill (if isFocused: PanelBgHover else: PanelBg)
    stroke borderColor
    strokeWeight (if isFocused: 1.5 else: 1.0)
    cornerRadius RadiusMd
    ## Jw. -- `zLevel win.zIndex` był no-opem (nic go nie czyta w silniku
    ## Fidget). Prawdziwy z-order między oknami zapewnia teraz kolejność
    ## iteracji `compositor.windowsInZOrder().reversed()` w `drawMain()`
    ## (shell.nim) -- najwyższe okno z-index deklarowane jako pierwsze.

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

      ## Cienka jaśniejsza linia na samej górze -- typowy "glass highlight",
      ## sugeruje delikatne oświetlenie z góry zamiast płaskiej, martwej
      ## powierzchni. Kosztuje jeden dodatkowy prostokąt na okno.
      rectangle "titlebar-highlight":
        box 0, 0, win.size.x, 1
        fill "#ffffff", (if isFocused: 0.08 else: 0.04)

      ## Mała kropka wskazująca aktywne okno -- czytelniejsza niż sam kolor
      ## obramowania, szczególnie gdy kilka okien leży blisko siebie.
      rectangle "titlebar-dot":
        box 10, TitlebarH / 2 - 3, 6, 6
        fill (if isFocused: AccentColor else: TextFaint)
        cornerRadius 3

      text "title":
        box 24, 0, win.size.x - 124, TitlebarH
        font "sans-serif", 12, 600, TitlebarH, hLeft, vCenter
        fill (if isFocused: TextPrimary else: TextMuted)
        characters win.title

      # przycisk minimalizacji
      group "btn-min":
        box win.size.x - 90, 4, 26, TitlebarH - 8
        cornerRadius RadiusSm
        fill "#2c333c"
        onHover: fill "#3a424d"
        onClick: compositor.minimizeWindow(win.id)
        text "min-label":
          box 0, 0, 26, TitlebarH - 8
          font "sans-serif", 13, 700, TitlebarH - 8, hCenter, vCenter
          fill TextPrimary
          characters "–"

      # przycisk maksymalizacji (tylko gdy okno jest resizable)
      if win.resizable:
        group "btn-max":
          box win.size.x - 60, 4, 26, TitlebarH - 8
          cornerRadius RadiusSm
          fill "#2c333c"
          onHover: fill "#3a424d"
          onClick: compositor.toggleMaximize(win.id)
          text "max-label":
            box 0, 0, 26, TitlebarH - 8
            font "sans-serif", 12, 700, TitlebarH - 8, hCenter, vCenter
            fill TextPrimary
            characters (if win.maximized: "❐" else: "☐")

      # przycisk zamknięcia
      if win.closable:
        group "btn-close":
          box win.size.x - 30, 4, 26, TitlebarH - 8
          cornerRadius RadiusSm
          fill "#2c333c"
          onHover: fill StateBad
          onClick: compositor.closeWindow(win.id)
          text "close-label":
            box 0, 0, 26, TitlebarH - 8
            font "sans-serif", 13, 700, TitlebarH - 8, hCenter, vCenter
            fill TextPrimary
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
