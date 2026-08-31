import std/[times, os, osproc, strutils]
import fidget
import fidget/opengl/base as fidgetBase  # dla MainLoopMode (nie re-eksportowane przez `fidget`)
import ../comp/comp
import waylandlink
import state
import wallpaper
import chrome
import taskbar

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
    # Monitor systemu -- odczyt /proc raz na sekundę w zupełności wystarczy.
    for sm in sysmonitors:
      poll(sm)

## Znajduje ścieżkę do prawdziwego pliku fontu na dysku dla podanej
## logicznej rodziny (np. "sans-serif", "monospace"). `fidget.loadFont`
## szuka plików w `<cwd>/data/...`, co u nas nigdy nie istniało -- stąd
## "File `data/IBMPlexSans-Regular.ttf` does not exist" przy pierwszym
## uruchomieniu na prawdziwym sprzęcie. Zamiast dołączać (i licencjonować)
## własne pliki .ttf, korzystamy z fontconfig (`fc-match`), które jest
## praktycznie zawsze dostępne na desktopowym Linuksie i samo znajdzie
## najlepszy zainstalowany font dla żądanej rodziny -- niezależnie od
## dystrybucji i tego, gdzie akurat trzyma swoje fonty.
proc findSystemFont(family: string): string =
  if findExe("fc-match").len > 0:
    try:
      let (output, code) = execCmdEx("fc-match -f \"%{file}\" " & family)
      let path = output.strip()
      if code == 0 and path.len > 0 and fileExists(path):
        return path
    except OSError:
      discard
  # Awaryjne, zaszyte na sztywno ścieżki -- na wypadek systemów bez
  # fontconfig (rzadkie na desktopie, ale nie niemożliwe).
  let fallbacks =
    if family == "monospace":
      @["/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf"]
    else:
      @["/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf"]
  for path in fallbacks:
    if fileExists(path):
      return path
  return ""

proc loadSystemFont(logicalName, family: string) =
  let path = findSystemFont(family)
  if path.len == 0:
    quit("zde-shell: nie znaleziono żadnego fontu dla rodziny '" & family &
      "' (ani przez fc-match, ani pod znanymi ścieżkami DejaVu) -- zainstaluj " &
      "fontconfig i przynajmniej jeden font, np. `sudo apt install fontconfig " &
      "fonts-dejavu-core`.")
  loadFontAbsolute(logicalName, path)

when isMainModule:
  loadSystemFont("sans-serif", "sans-serif")
  loadSystemFont("monospace", "monospace")
  setTitle("Zenit Desktop Environment")
  startFidget(
    drawMain,
    tick = tickMain,
    fullscreen = true,
    mainLoopMode = fidgetBase.RepaintOnFrame,
  )
