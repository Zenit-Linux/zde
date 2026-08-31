import fidget
import state

proc drawWallpaper*() =
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
