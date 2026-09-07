import std/[times, os, osproc, strutils, algorithm]
import fidget
import fidget/opengl/base as fidgetBase  # dla MainLoopMode (nie re-eksportowane przez `fidget`)
import ../comp/comp
import ../apps/session/session
import waylandlink
import state
import wallpaper
import chrome
import taskbar
import launcher_apps
import shortcuts

proc dispatchShortcut(a: ShortcutAction) =
  case a
  of actToggleLauncher: compositor.launcherOpen = not compositor.launcherOpen
  of actCycleFocus: compositor.cycleFocus()
  of actOpenTerminal: launchTerminal()
  of actOpenFileManager: launchFileManager()
  of actOpenEditor: launchTextEditor()
  of actOpenSettings: launchSettings()
  of actCloseWindow:
    let w = compositor.focusedWindow()
    if w != nil: compositor.closeWindow(w.id)
  of actLockScreen: lockScreen()
  of actLogout: logout()

proc drawMain() =
  compositor.setScreenSize(vec2(windowSize.x, windowSize.y))

  ## Ekran blokady ma pierwszeństwo nad WSZYSTKIM -- nie tylko wizualnie
  ## (zadeklarowany jako pierwszy, patrz duży komentarz niżej o odwróconej
  ## kolejności rysowania Fidget), ale też przez wczesny `return`: Fidget
  ## NIE blokuje automatycznie kliknięć do elementów pod spodem tylko
  ## dlatego, że coś innego renderuje się nad nimi wizualnie (każdy
  ## element sam sprawdza, czy mysz go dotyka, niezależnie od z-order) --
  ## więc same "narysowanie nakładki na wierzchu" NIE wystarczyłoby, żeby
  ## zablokować interakcję z paskiem zadań/oknami pod spodem. Wczesny
  ## `return` (w ogóle nie deklarujemy tamtych elementów tej klatki)
  ## całkowicie i niezawodnie to załatwia.
  drawLockOverlay(lockState, clockText)
  if lockState.locked: return

  ## UWAGA O KOLEJNOŚCI RYSOWANIA (naprawiony bug -- ekran był pusty poza
  ## tłem): silnik rysujący Fidget (`fidget/openglbackend.draw`) renderuje
  ## dzieci danej ramki w kolejności ODWRÓCONEJ względem deklaracji --
  ## `for j in 1 .. node.nodes.len: node.nodes[^j].draw()` -- czyli element
  ## zadeklarowany JAKO PIERWSZY w danej klatce ląduje NA WIERZCHU, a
  ## zadeklarowany później -- pod spodem (odwrotność zwykłego malowania
  ## "co rysujesz później, zakrywa wcześniejsze"). Zweryfikowane
  ## empirycznie osobnym minimalnym programem testowym pod Xvfb.
  ##
  ## Stąd kolejność wywołań poniżej musi iść od "wizualnie najwyższej"
  ## warstwy do "wizualnie najniższej" (odwrotnie niż mogłoby się
  ## intuicyjnie wydawać):
  ##   1. launcher (menu, gdy otwarte)         -- najwyżej
  ##   2. pasek zadań
  ##   3. okna aplikacji, od najwyższego z-index do najniższego
  ##   4. tło pulpitu                           -- najniżej
  ## Poprzednia kolejność (tło zadeklarowane jako pierwsze) powodowała, że
  ## nieprzezroczysty prostokąt tła renderował się NA WIERZCHU wszystkiego
  ## -- w efekcie widoczne było wyłącznie tło, bez paska zadań, okien i
  ## launchera, niezależnie od stanu kompozytora.

  if compositor.launcherOpen:
    drawLauncher()

  drawTaskbar()

  # windowsInZOrder() zwraca okna rosnąco po z-index (dokumentacja w
  # comp/window.nim celowo tego nie zmienia -- to naturalna, "logiczna"
  # kolejność z-index). Odwracamy ją TYLKO tutaj, w warstwie rysującej, bo
  # to Fidget -- a nie sam z-order -- wymaga takiej kolejności deklaracji,
  # żeby okno o najwyższym z-index (czyli aktywne/najświeższe) faktycznie
  # renderowało się na wierzchu pozostałych, a nie pod spodem.
  for win in compositor.windowsInZOrder().reversed():
    drawWindowChrome(win)

  drawWallpaper()

  # -- globalna obsługa przeciągania/zmiany rozmiaru okien -----------------
  if compositor.isDragging:
    compositor.updateDrag(mouse.pos)
    if not mouse.down:
      compositor.endDrag()

  # -- Skróty klawiszowe (konfigurowalne, patrz shortcuts.nim + Ustawienia) -
  # Escape zamykający launcher zostaje zaszyty na sztywno -- to zachowanie
  # UI (jak w każdym menu), nie "skrót" w sensie akcji do przypisania.
  for a in ShortcutAction:
    if matches(parseCombo(activeShortcuts[a])):
      dispatchShortcut(a)

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
