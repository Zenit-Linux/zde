import std/[os, osproc, strutils, tables, algorithm, times]
import pixie

## Rozbudowa v0.1 ("Aurora" -- prawdziwe aplikacje systemowe). Do tej pory
## launcher ZDE pokazywał WYŁĄCZNIE 7 wbudowanych aplikacji shellu
## (terminal, menedżer plików, zegar...) -- żaden realnie zainstalowany w
## systemie program (przeglądarka, LibreOffice, GIMP, cokolwiek
## zainstalowane przez menedżera pakietów) nigdy się tam nie pojawiał.
## Ten moduł skanuje standardowe katalogi XDG (`/usr/share/applications`
## i pochodne) w poszukiwaniu plików `.desktop` -- dokładnie tego samego
## mechanizmu, którego używają GNOME, KDE i każdy inny "poważny" launcher
## na Linuksie -- parsuje je i wystawia jako listę gotową do pokazania w
## `shell/taskbar.nim`.
##
## Celowo NIE jest to pełna implementacja specyfikacji Desktop Entry ani
## Icon Theme Specification (freedesktop.org) -- to byłyby osobne, duże
## projekty same w sobie. Zakres świadomie ograniczony do tego, co
## faktycznie pokrywa zdecydowaną większość realnych `.desktop` plików:
## - TYLKO `Type=Application` (pomijamy `Link`/`Directory`),
## - pomijamy `NoDisplay=true`/`Hidden=true` (standardowa konwencja "nie
##   pokazuj w menu"),
## - TYLKO pole `Name=` bez sufiksu językowego (`Name[pl]=` ignorowane --
##   ZDE jest jednojęzyczne po polsku w UI, ale nazwy aplikacji i tak
##   zwykle nie są tłumaczone w praktyce, np. "Firefox" zostaje "Firefox"),
## - ikony TYLKO rastrowe (PNG) znalezione w kilku najpopularniejszych
##   lokalizacjach motywów ikon -- bez pełnej rezolucji Icon Theme Spec
##   (dziedziczenie motywów, indeksy `.theme`, SVG). Aplikacja bez
##   znalezionej ikony dostaje ikonę zastępczą wg kategorii (patrz
##   `categoryOf`/`categoryIcon` niżej) -- nigdy nie zostaje bez ikony.

type
  DesktopApp* = object
    name*: string
    comment*: string
    exec*: string        ## surowa komenda z pliku .desktop, PRZED oczyszczeniem z %-kodów
    iconPath*: string     ## bezwzględna ścieżka do PNG, albo "" (użyj ikony zastępczej kategorii)
    category*: string     ## nasza własna, znormalizowana kategoria (patrz `categoryOf`)
    terminal*: bool        ## czy uruchomić w terminalu (Terminal=true w .desktop)

const
  ## Kolejność ma znaczenie -- pierwszy katalog wygrywa przy duplikatach
  ## nazwy pliku (tak jak w prawdziwej specyfikacji XDG: lokalne
  ## nadpisania w `~/.local` mają pierwszeństwo przed systemowymi).
  AppDirs = [
    "~/.local/share/applications",
    "/usr/local/share/applications",
    "/usr/share/applications",
  ]
  ## Kilka najpopularniejszych lokalizacji motywów ikon w typowej
  ## dystrybucji Linuksa -- sprawdzane w tej kolejności, pierwsze
  ## trafienie wygrywa. `$1` = nazwa ikony z pliku .desktop.
  IconSearchTemplates = [
    "/usr/share/icons/hicolor/64x64/apps/$1.png",
    "/usr/share/icons/hicolor/128x128/apps/$1.png",
    "/usr/share/icons/hicolor/48x48/apps/$1.png",
    "/usr/share/icons/hicolor/32x32/apps/$1.png",
    "/usr/share/icons/hicolor/256x256/apps/$1.png",
    "/usr/share/icons/Humanity/apps/64/$1.png",
    "/usr/share/icons/Humanity/apps/48/$1.png",
    "/usr/share/icons/Adwaita/64x64/apps/$1.png",
    "/usr/share/icons/Adwaita/48x48/apps/$1.png",
    "/usr/share/icons/breeze/apps/64/$1.png",
    "/usr/share/icons/breeze/apps/48/$1.png",
    "/usr/share/pixmaps/$1.png",
  ]

## Mapowanie surowych kategorii XDG (`Categories=Office;WordProcessor;`)
## na nasze własne, dużo krótsze i przetłumaczone grupy. Kolejność w tej
## tabeli to też PRIORYTET -- pierwsza pasująca wygrywa, gdy aplikacja ma
## kilka kategorii naraz (np. LibreOffice Writer ma "Office;WordProcessor").
const CategoryRules = [
  ("Settings", "System"), ("System", "System"),
  ("Development", "Programowanie"), ("IDE", "Programowanie"),
  ("WebBrowser", "Internet"), ("Network", "Internet"), ("Email", "Internet"),
  ("Office", "Biuro"), ("WordProcessor", "Biuro"), ("Spreadsheet", "Biuro"),
  ("Presentation", "Biuro"),
  ("Graphics", "Grafika"), ("Photography", "Grafika"), ("2DGraphics", "Grafika"),
  ("AudioVideo", "Multimedia"), ("Audio", "Multimedia"), ("Video", "Multimedia"),
  ("Player", "Multimedia"), ("Recorder", "Multimedia"),
  ("Game", "Gry"),
  ("Education", "Edukacja"), ("Science", "Edukacja"),
  ("Utility", "Narzędzia"), ("Accessibility", "Narzędzia"), ("System", "Narzędzia"),
]

const CategoryIcons = {
  "System": "⚙", "Programowanie": "💻", "Internet": "🌐", "Biuro": "📄",
  "Grafika": "🎨", "Multimedia": "🎵", "Gry": "🎮", "Edukacja": "📚",
  "Narzędzia": "🛠", "Inne": "📦",
}.toTable

proc categoryIcon*(category: string): string =
  CategoryIcons.getOrDefault(category, "📦")

proc categoryOf(rawCategories: string): string =
  let cats = rawCategories.split(';')
  for (xdgCat, ourCat) in CategoryRules:
    if xdgCat in cats:
      return ourCat
  "Inne"

proc isDecodablePng(path: string): bool =
  ## NAPRAWIONY BUG (znaleziony realnym uruchomieniem pod Xvfb -- launcher
  ## potrafił CAŁKOWICIE SIĘ WYWALIĆ, czarny ekran, proces martwy): Fidget
  ## renderuje `image(...)` przez Pixie, a Pixie w tej wersji nie
  ## obsługuje np. PNG 16-bit/kanał (spotykane naprawdę, np. ikona
  ## ImageMagicka w tym systemie) -- i rzuca wyjątkiem, którego NIC w
  ## całej bibliotece Fidget nie łapie (pętla renderowania nie ma ani
  ## jednego `try`/`except`), więc cały proces `zde-shell` umiera w
  ## trakcie klatki. Zamiast ufać samemu `fileExists` (jak poprzednio),
  ## PRÓBUJEMY realnie zdekodować kandydata TU, w czasie skanowania --
  ## gdzie MY kontrolujemy obsługę wyjątków -- i odrzucamy każdy plik,
  ## który się nie da, zamiast dowiedzieć się o tym dopiero w trakcie
  ## rysowania klatki (gdzie jest już za późno).
  try:
    discard pixie.readImage(path)
    true
  except CatchableError:
    false

proc resolveIconPath(iconField: string): string =
  ## Zwraca bezwzględną ścieżkę do pliku PNG, albo "", gdy nie znaleziono
  ## (wtedy launcher pokazuje ikonę zastępczą kategorii -- patrz
  ## `categoryIcon`). Pole `Icon=` w .desktop bywa albo już gotową
  ## bezwzględną ścieżką (rzadziej), albo -- zdecydowanie częściej --
  ## samą nazwą motywu bez rozszerzenia (np. `firefox`), którą trzeba
  ## dopiero odnaleźć w jednym z katalogów motywów.
  if iconField.len == 0:
    return ""
  if iconField.isAbsolute():
    ## Plik .desktop czasem wskazuje SVG wprost (`Icon=/usr/share/.../x.svg`)
    ## -- celowo pomijamy takie (patrz komentarz na górze pliku o
    ## rastrowych ikonach), bo Fidget/Pixie w tej wersji nie rasteryzuje
    ## SVG przez zwykłe `image(...)`.
    if iconField.toLowerAscii().endsWith(".png") and isDecodablePng(iconField):
      return iconField
    return ""
  for tmpl in IconSearchTemplates:
    let candidate = tmpl % [iconField]
    if fileExists(candidate) and isDecodablePng(candidate):
      return candidate
  ""

proc parseDesktopFile(path: string): DesktopApp =
  ## Parsuje TYLKO sekcję `[Desktop Entry]` -- plik może zawierać dalej
  ## `[Desktop Action ...]` (dodatkowe podkomendy w menu kontekstowym
  ## prawdziwych DE, np. "Nowy dokument") -- ZDE ich nie pokazuje (poza
  ## zakresem tej rozbudowy), więc przestajemy czytać na pierwszym
  ## kolejnym nagłówku sekcji.
  result.category = ""
  var inEntry = false
  var sawEntry = false
  var noDisplay = false
  var isApplication = false
  for line in lines(path):
    let l = line.strip()
    if l.len == 0 or l[0] == '#': continue
    if l[0] == '[':
      if sawEntry: break  ## koniec [Desktop Entry], nie interesują nas dalsze sekcje
      inEntry = l == "[Desktop Entry]"
      if inEntry: sawEntry = true
      continue
    if not inEntry: continue
    let eq = l.find('=')
    if eq < 0: continue
    let key = l[0 ..< eq]
    let value = l[eq + 1 .. ^1]
    case key
    of "Name": result.name = value          ## TYLKO klucz bez [locale] -- patrz komentarz na górze pliku
    of "Comment": result.comment = value
    of "Exec": result.exec = value
    of "Icon": result.iconPath = resolveIconPath(value)
    of "Categories": result.category = categoryOf(value)
    of "Terminal": result.terminal = value.toLowerAscii() == "true"
    of "NoDisplay": noDisplay = value.toLowerAscii() == "true"
    of "Hidden": (if value.toLowerAscii() == "true": noDisplay = true)
    of "Type": isApplication = value == "Application"
  if result.category.len == 0: result.category = "Inne"
  if noDisplay or not isApplication or result.name.len == 0 or result.exec.len == 0:
    result.name = ""  ## sygnał dla `scanDesktopApps`, żeby pominąć ten wpis

proc appDirsSignature*(): int64 =
  ## Rozbudowa: tani, "wystarczająco dobry" zamiennik pełnego `inotify` do
  ## wykrywania, że lista aplikacji systemowych mogła się zmienić (nowy
  ## pakiet zainstalowany/odinstalowany) -- BEZ trzymania osobnego wątku
  ## ani deskryptora inotify przez cały czas życia `zde-shell`. Sumujemy
  ## czasy modyfikacji (mtime) katalogów z `AppDirs`, które faktycznie
  ## istnieją: instalacja/usunięcie pliku `.desktop` zawsze dotyka mtime
  ## katalogu, który go zawiera (to podstawowa własność systemu plików,
  ## niezależna od typu FS) -- więc zmiana tej sygnatury jest niezawodnym
  ## (choć nie granularnym co do PLIKU) sygnałem "coś w AppDirs się
  ## ruszyło". `shell/taskbar.nim` (`rescanSystemAppsIfChanged`) woła to
  ## raz na sekundę (ten sam rytm co zegar/monitor systemu w `shell.nim`)
  ## i pełny `scanDesktopApps()` tylko wtedy, gdy sygnatura faktycznie się
  ## zmieniła -- realny `inotify` dałby powiadomienie o pojedynczym
  ## pliku od razu, ale wymagałby integracji z pętlą zdarzeń Fidget/GLFW,
  ## czego dziś `zde-shell` nigdzie nie robi (cała reszta stanu, patrz
  ## `state.nim`, jest odpytywana, nie subskrybowana) -- ten kompromis
  ## trzyma się istniejącej architektury zamiast wprowadzać drugi,
  ## niezależny mechanizm powiadamiania tylko dla tej jednej funkcji.
  for dirTmpl in AppDirs:
    let dir = expandTilde(dirTmpl)
    if not dirExists(dir): continue
    try:
      result += getLastModificationTime(dir).toUnix()
    except OSError:
      discard

proc scanDesktopApps*(): seq[DesktopApp] =
  ## Skanuje standardowe katalogi XDG (patrz `AppDirs`) i zwraca listę
  ## aplikacji posortowaną alfabetycznie w obrębie kategorii. Wołane
  ## przy starcie `zde-shell` ORAZ ponownie za każdym razem, gdy
  ## `appDirsSignature()` wykryje zmianę (patrz `shell/taskbar.nim`,
  ## `rescanSystemAppsIfChanged`) -- nowo zainstalowany program pojawia
  ## się więc w launcherze bez restartu całego shellu, choć z opóźnieniem
  ## do ok. sekundy (kadencja tego samego tickera co zegar), nie
  ## natychmiast klatka-po-klatce.
  var seen = initTable[string, bool]()  ## nazwa pliku .desktop -> już widziana (deduplikacja między katalogami)
  for dirTmpl in AppDirs:
    let dir = expandTilde(dirTmpl)
    if not dirExists(dir): continue
    for path in walkFiles(dir / "*.desktop"):
      let base = extractFilename(path)
      if seen.hasKey(base): continue
      seen[base] = true
      try:
        let app = parseDesktopFile(path)
        if app.name.len > 0:
          result.add(app)
      except IOError, OSError:
        discard  ## uszkodzony/nieczytelny plik .desktop -- pomijamy, nie wywalamy całego skanu
  result.sort(proc(a, b: DesktopApp): int =
    if a.category != b.category: cmp(a.category, b.category)
    else: cmp(a.name, b.name))

proc launchDesktopApp*(app: DesktopApp) =
  ## Uruchamia aplikację systemową jako odłączony proces potomny (shell
  ## ZDE nie czeka na jej zakończenie ani nie przechwytuje jej wyjścia --
  ## dokładnie tak samo jak `startProcess` dla terminala w
  ## `apps/terminal/term.nim`). `%f`/`%F`/`%u`/`%U`/`%i`/`%c`/`%k` to pola
  ## podstawieniowe specyfikacji Desktop Entry (ścieżka pliku, URL, ikona,
  ## nazwa, ścieżka do samego .desktop) -- ZDE nie przekazuje żadnego
  ## konkretnego pliku/URL przy uruchamianiu z launchera, więc wszystkie
  ## po prostu usuwamy z linii poleceń.
  var cmd = app.exec
  for code in ["%f", "%F", "%u", "%U", "%i", "%c", "%k"]:
    cmd = cmd.replace(code, "")
  cmd = cmd.strip()
  if cmd.len == 0: return
  try:
    let parts = parseCmdLine(cmd)
    if parts.len == 0: return
    discard startProcess(parts[0], args = parts[1 ..^ 1],
      options = {poStdErrToStdOut, poUsePath, poDaemon})
  except OSError, ValueError:
    ## Zła linia poleceń albo brak uprawnień/pliku -- najlepsze, co można
    ## tu zrobić bez systemu powiadomień widocznego z tego modułu
    ## (`launcher_apps`/`taskbar` importują TEN plik, nie odwrotnie, więc
    ## wywołanie `notify(...)` stąd stworzyłoby cykl importów) to po
    ## cichu nie zrobić nic -- launcher i tak zamyka się od razu po
    ## kliknięciu, więc nie ma gdzie pokazać błędu w tym samym miejscu.
    discard
