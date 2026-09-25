import std/[os, osproc, strutils, tables, algorithm, times, posix, sets, sequtils]
import pixie
import pixie/fileformats/svg as pixieSvg

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
## - ikony: PNG bezpośrednio, oraz SVG od v0.2 -- rasteryzowane do PNG i
##   podręcznie zbuforowane (patrz `rasterizeSvgIcon` niżej), ale TYLKO
##   dla SVG mieszczących się w podzbiorze obsługiwanym przez Pixie
##   5.0.7 (proste kształty, bez gradientów z transformacją, bez
##   `clipPath`) -- w praktyce spora część nowoczesnych motywów ikon
##   (Adwaita, Humanity) tego nie spełnia i dalej dostaje ikonę
##   zastępczą, patrz uczciwa notatka z testów przy `rasterizeSvgIcon`.
##   Rezolucja Icon Theme Spec (dziedziczenie motywów przez `Inherits=`,
##   indeksy `.theme`, od rundy 14 też `Scale=`/katalogi @2x) jest od
##   rundy 6 zaimplementowana -- patrz duży komentarz przy
##   `IconThemeSeeds` niżej po pełny opis zakresu i świadomych uproszczeń.
##   Aplikacja bez znalezionej ikony dostaje ikonę zastępczą wg kategorii
##   (patrz `categoryOf`/`categoryIcon` niżej) -- nigdy nie zostaje bez
##   ikony.

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
  ##
  ## Rozbudowa v0.2 (runda 6 -- prawdziwa rezolucja Icon Theme Spec):
  ## od teraz to TYLKO siatka bezpieczeństwa NA WYPADEK, gdyby
  ## `resolveViaThemeSpec` niżej zawiodło (np. żaden `index.theme` się
  ## nie sparsował) -- główną ścieżką jest odtąd właściwa rezolucja przez
  ## `[Icon Theme]`/`Directories=`/`Inherits=`, patrz duży komentarz przy
  ## `IconThemeSeeds` niżej.
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
  ## Rozbudowa v0.2 (ikony SVG): sprawdzane DOPIERO, gdy ani rezolucja
  ## przez Icon Theme Spec, ani `IconSearchTemplates` wyżej nie trafi.
  IconSearchTemplatesSvg = [
    "/usr/share/icons/hicolor/scalable/apps/$1.svg",
    "/usr/share/icons/Adwaita/scalable/apps/$1.svg",
    "/usr/share/icons/breeze/apps/scalable/$1.svg",
    "/usr/share/pixmaps/$1.svg",
  ]
  ## Rozmiar rasteryzacji SVG -- pomiędzy najczęściej używanymi
  ## rozmiarami w `IconSearchTemplates` wyżej (64/128), wystarczająco
  ## duży, żeby wyglądać ostro nawet przy ewentualnym future HiDPI, bez
  ## przesadnie dużych plików w cache'u.
  SvgRasterSize = 128
  ## Preferowany rozmiar ikony przy wyborze między kilkoma dopasowaniami
  ## w OBRĘBIE jednego motywu (patrz `pickBestDir` niżej) -- typowy
  ## rozmiar ikony aplikacji w większości środowisk, dobry kompromis
  ## między ostrością a rozmiarem pliku/kosztem rasteryzacji SVG.
  PreferredIconSize = 48
  ## Katalogi bazowe motywów ikon przeszukiwane w tej kolejności (patrz
  ## `themeBaseDir` niżej) -- `~/.icons` i `~/.local/share/icons` to
  ## MIEJSCA UŻYTKOWNIKA z Icon Theme Spec (motywy zainstalowane ręcznie,
  ## bez uprawnień administratora) sprawdzane PRZED katalogami systemowymi,
  ## zgodnie ze specyfikacją (nadpisanie systemowego motywu przez
  ## użytkownika powinno wygrywać).
  IconThemeBaseDirsRel = ["/.icons", "/.local/share/icons"]
  IconThemeBaseDirsAbs = ["/usr/share/icons", "/usr/local/share/icons"]
  ## Rozbudowa v0.2 (runda 6): ZDE nie ma dziś żadnego ustawienia "motyw
  ## ikon" (nie ma odpowiednika gsettings/kconfig) -- te nazwy to
  ## rozsądne PUNKTY STARTOWE łańcucha dziedziczenia (patrz
  ## `themeSearchChain`), nie założenie "użytkownik na pewno ma jeden z
  ## nich". Kolejność celowo faworyzuje warianty CIEMNE jako pierwsze --
  ## reszta interfejsu ZDE (patrz `shell/theme.nim` i kolory w całym
  ## `shell/`) jest konsekwentnie ciemna, więc ciemny wariant motywu ikon
  ## (gdy istnieje) pasuje wizualnie lepiej niż jasny. Każda nazwa, której
  ## nie ma na dysku, jest po prostu pomijana (patrz `loadThemeMeta`) --
  ## nieszkodliwie, nie wymaga, żeby WSZYSTKIE tu wymienione istniały.
  IconThemeSeeds = ["Humanity-Dark", "ubuntu-mono-dark", "Yaru-dark",
                     "Humanity", "Adwaita", "breeze-dark", "breeze",
                     "Papirus-Dark", "Papirus", "Yaru", "gnome"]

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

proc svgCacheDir(): string =
  ## `$XDG_CACHE_HOME/zde/icons`, z tym samym fallbackiem co reszta ZDE
  ## używa dla katalogów stanu/configu, gdy zmienna nie jest ustawiona.
  let base =
    if existsEnv("XDG_CACHE_HOME"): getEnv("XDG_CACHE_HOME")
    else: getHomeDir() / ".cache"
  base / "zde" / "icons"

proc rasterizeSvgIcon(svgPath: string): string =
  ## Rasteryzuje `svgPath` do PNG o boku `SvgRasterSize` i zwraca ścieżkę
  ## do WYNIKOWEGO pliku w cache'u (albo "" przy porażce).
  ##
  ## **Uczciwa notatka z testów w tej rundzie:** podzbiór SVG obsługiwany
  ## przez Pixie 5.0.7 jest węższy niż mogłoby się wydawać -- w praktyce
  ## na tym systemie WIĘKSZOŚĆ realnych ikon motywów (Adwaita, Humanity)
  ## kończy się `PixieError` (`"Unsupported gradient transform"`,
  ## `"Unsupported SVG tag: clipPath"`, a czasem wręcz błędem parsowania
  ## `viewBox`), bo używają gradientów z transformacją, `clipPath`, albo
  ## innych elementów spoza tego, co Pixie potrafi narysować. Prosty,
  ## płaski SVG (podstawowe kształty, jednolite kolory, bez `clipPath`/
  ## gradientów) rasteryzuje się poprawnie -- zweryfikowane w tej rundzie
  ## zarówno na syntetycznym przykładzie (sukces, prawdziwy PNG na
  ## dysku), jak i na czterech prawdziwych ikonach systemowych z tej
  ## maszyny (wszystkie cztery zawiodły z konkretnym, odczytanym błędem
  ## Pixie, nie cichym "coś nie działa"). Innymi słowy: ta funkcja
  ## POSZERZA pokrycie ikon (niektóre SVG się uda), ale nie jest to
  ## "SVG zawsze działa" -- dla ikon systemowych z nowoczesnych motywów
  ## współczynnik trafień bywa niski. Awaria jest zawsze CICHA i
  ## BEZPIECZNA (patrz `except CatchableError` niżej) -- aplikacja po
  ## prostu dostaje ikonę zastępczą kategorii, dokładnie jak przed tą
  ## rozbudową, nigdy pustego miejsca ani wywrócenia skanu.
  ##
  ## Podręcznie buforowane na dysku (nazwa pliku = nazwa źródłowa +
  ## rozmiar, więc różne ikony o tej samej nazwie bazowej z różnych
  ## motywów nie nadpisują się nawzajem) -- rasteryzacja SVG jest
  ## zauważalnie droższa niż zwykłe wczytanie PNG, a `resolveIconPath`
  ## wywołuje się przy KAŻDYM skanie launchera (patrz `rescanSystemAppsIfChanged`
  ## w `shell/taskbar.nim`, co ok. sekundę, gdy coś się zmieniło) -- bez
  ## cache'u ta sama ikona byłaby rasteryzowana od nowa za każdym razem.
  ## Ponowna rasteryzacja następuje TYLKO, gdy plik źródłowy SVG jest
  ## nowszy niż istniejący cache (aktualizacja motywu ikon w systemie) --
  ## ten sam wzorzec "sprawdź mtime źródła" co `appDirsSignature` wyżej.
  try:
    let cacheDir = svgCacheDir()
    let cachedPath = cacheDir / (extractFilename(svgPath).changeFileExt("") &
      "-" & $SvgRasterSize & ".png")
    if fileExists(cachedPath) and
       getLastModificationTime(cachedPath) >= getLastModificationTime(svgPath):
      return cachedPath
    let svg = pixieSvg.parseSvg(readFile(svgPath), SvgRasterSize, SvgRasterSize)
    let image = pixieSvg.newImage(svg)
    createDir(cacheDir)
    image.writeFile(cachedPath)
    cachedPath
  except CatchableError:
    ## Uszkodzony SVG, nieobsługiwany element/atrybut spoza podzbioru
    ## Pixie, albo brak uprawnień do zapisu w cache'u -- traktujemy
    ## dokładnie tak jak nieudekodowalny PNG w `isDecodablePng`: cicho
    ## pomijamy, aplikacja dostaje ikonę zastępczą kategorii zamiast
    ## wywalić cały skan launchera.
    ""

## Rozbudowa v0.2 (runda 6 -- prawdziwa rezolucja Icon Theme Spec):
## dotąd `resolveIconPath` przeszukiwało PŁASKĄ, ręcznie wypisaną listę
## ścieżek (`IconSearchTemplates`) -- to działało dla kilku najbardziej
## oczywistych przypadków, ale w ogóle nie rozumiało ISTNIEJĄCEGO na
## dysku łańcucha dziedziczenia motywów. Przykład realny z TEJ maszyny:
## `ubuntu-mono-dark` dziedziczy `Humanity-Dark,Adwaita,hicolor`, a
## `Humanity-Dark` dziedziczy `Humanity,Adwaita,hicolor` -- czyli ikona
## dostarczona TYLKO w `Humanity-Dark` (a nie w `Humanity`/`Adwaita`/
## `hicolor` osobno) nigdy nie była wcześniej znajdowana, bo stara lista
## nie wiedziała, że `Humanity-Dark` w ogóle istnieje ani że coś go
## dziedziczy. To poniżej implementuje realny, choć uproszczony,
## algorytm ze specyfikacji freedesktop.org "Icon Theme Specification":
## dla każdego motywu z listy startowej (`IconThemeSeeds`) zbuduj pełny
## łańcuch dziedziczenia (`themeSearchChain`), i dla KAŻDEGO motywu w tym
## łańcuchu (po kolei -- pierwsze trafienie w danym motywie wygrywa,
## zanim przejdziemy do następnego) przeszukaj jego katalogi z sekcji
## `Context=Applications` w `index.theme`, wybierając najbliższy
## `PreferredIconSize` rozmiar.
##
## **Runda 34 -- domknięcie punktu, jeszcze do tej rundy jawnie
## wypisanego jako uproszczenie: dokładne reguły `Type=Fixed/Scalable/
## Threshold` z `MinSize`/`MaxSize`/`Threshold`.** `dirSizeDistance`
## niżej implementuje teraz FORMALNĄ funkcję odległości rozmiaru ze
## specyfikacji (`DirectorySizeDistance`) zamiast jednego, uniwersalnego
## `abs(size - PreferredIconSize)`: katalog `Type=Fixed` musi mieć
## DOKŁADNIE żądany rozmiar, żeby liczyć się jako "dopasowany" (inaczej
## kara = różnica); `Type=Scalable` dopasowuje CAŁY zakres `MinSize..
## MaxSize` bez kary (poza zakresem kara = odległość od najbliższej
## granicy); `Type=Threshold` (domyślny, gdy `Type=` w ogóle nie
## występuje w sekcji -- tak mówi specyfikacja) dopasowuje zakres `Size ±
## Threshold` (domyślnie `Threshold=2`) bez kary. Poprzednia, jednolita
## `abs(size - Preferred)` traktowała katalog `Scalable` o `MinSize=16,
## MaxSize=256` tak samo surowo jak `Fixed` o `Size=16` -- w praktyce
## niepotrzebnie odrzucając/degradując katalogi skalowalne, które wg
## specyfikacji POWINNY dopasować się do szerokiego zakresu rozmiarów
## bez żadnej kary. `ScaledDirectories=`/`Scale=` (katalogi @2x/@3x na
## HiDPI) SĄ od tej rundy parsowane i brane pod uwagę (patrz `pickBestDir`
## niżej -- `Scale=1` jest zawsze preferowane, bo ZDE nie zna dziś skali
## monitora), ale to WCIĄŻ nie jest pełne, prawdziwe wsparcie HiDPI:
## kompozytor nigdzie nie przekazuje do shellu rzeczywistego współczynnika
## skalowania monitora, więc katalog `@2x` nigdy faktycznie nie zostanie
## WYBRANY na potrzeby HiDPI -- ta zmiana tylko naprawia to, że ikony ze
## `Scale=1` przestały być mylone z ikonami `@2x`/`@3x` o tym samym
## nominalnym `Size=` w tym samym motywie. To i tak realna, testowalna
## poprawa względem płaskiej listy -- pełna zgodność ze specyfikacją
## day-1 nie była celem.

type
  ThemeDirEntry = object
    relPath: string    ## np. "48x48/apps" albo "scalable/apps"
    size: int          ## `Size=` z sekcji (0, gdy brak/nie do sparsowania)
    isScalable: bool    ## `Type=Scalable` (albo katalog literally nazwany "scalable/...")
    ## Rozbudowa (ScaledDirectories/HiDPI): `Scale=` z sekcji, WEDŁUG
    ## SPECYFIKACJI domyślnie `1`, gdy klucz w ogóle nie występuje (patrz
    ## `loadThemeMeta` niżej) -- katalogi typu `apps@2/48` (Scale=2,
    ## przeznaczone na ekrany HiDPI) mają TEN SAM `Size=` co zwykłe
    ## `apps/48` (Scale=1), więc bez tego pola `pickBestDir` nie miał jak
    ## ich w ogóle odróżnić.
    scale: int
    ## Runda 34 -- pełne reguły dopasowania rozmiaru wg specyfikacji,
    ## patrz duży komentarz wyżej i `dirSizeDistance`.
    dirType: IconDirType
    minSize: int        ## `MinSize=` (Scalable); domyślnie = `size`, gdy brak/nie-Scalable
    maxSize: int         ## `MaxSize=` (Scalable); domyślnie = `size`
    threshold: int        ## `Threshold=` (Threshold); domyślnie 2 wg specyfikacji

  IconDirType = enum
    idtFixed, idtScalable, idtThreshold

  ThemeMeta = object
    found: bool         ## czy w ogóle odnaleziono `index.theme` dla tej nazwy
    basePath: string     ## katalog zawierający `index.theme` (i podkatalogi z ikonami)
    inherits: seq[string]
    appDirs: seq[ThemeDirEntry]  ## tylko katalogi z Context=Applications (albo bez Context -- patrz loadThemeMeta)

var gThemeMetaCache = initTable[string, ThemeMeta]()

proc themeBaseDir(themeName: string): string =
  ## Pierwszy katalog bazowy (w kolejności: użytkownika, potem systemowe,
  ## patrz `IconThemeBaseDirsRel`/`IconThemeBaseDirsAbs`), w którym
  ## istnieje `<baza>/<themeName>/index.theme`. "" gdy nigdzie nie ma.
  for rel in IconThemeBaseDirsRel:
    let cand = getHomeDir().strip(chars = {'/'}) & rel / themeName
    if fileExists(cand / "index.theme"): return cand
  for base in IconThemeBaseDirsAbs:
    let cand = base / themeName
    if fileExists(cand / "index.theme"): return cand
  ""

proc parseIniLoose(path: string): OrderedTable[string, OrderedTable[string, string]] =
  ## Hand-rolled, TOLERANT INI-style parser -- świadomie NIE używa
  ## `std/parsecfg.loadConfig`, mimo że to oczywisty pierwszy wybór dla
  ## "sparsuj plik INI" w Nim.
  ##
  ## Powód, znaleziony REALNYM testem w tej rundzie, nie w dokumentacji:
  ## `parsecfg`'s wewnętrzny tokenizer nie akceptuje `@` jako znaku w
  ## nazwie sekcji -- a nagłówki w stylu `[actions@2/22]` (katalogi
  ## HiDPI "@2x", część specyfikacji `ScaledDirectories=`) są
  ## ZUPEŁNIE STANDARDOWE w prawdziwych plikach `index.theme` (ten
  ## konkretny plik, `Humanity/index.theme`, ma ich dziesiątki). Gdy
  ## `parsecfg` trafi na taki nagłówek, zwraca `cfgError`, a
  ## `loadConfig` na to `break`-uje z GŁÓWNEJ pętli parsowania,
  ## CICHO PORZUCAJĄC RESZTĘ PLIKU -- bez wyjątku, bez ostrzeżenia.
  ## Efekt: z ~250 sekcji w `Humanity/index.theme` `loadConfig` widziało
  ## dosłownie JEDNĄ (`actions/16`) -- każda ikona w `apps/*` (w tym
  ## wszystkie ikony aplikacji) była NIEWIDOCZNA, mimo że plik parsował
  ## się "bez błędu" (żadnego wyjątku, `except CatchableError` nie miało
  ## czego złapać -- to nie była awaria, to była CICHA UTRATA DANYCH).
  ## Odkryte i naprawione DOPIERO dzięki testowi na tym konkretnym,
  ## prawdziwym pliku w tej rundzie -- na syntetycznym/uproszczonym pliku
  ## testowym bez sekcji `@2` ten bug nigdy by się nie ujawnił.
  ##
  ## Ten parser NIE waliduje formatu -- po prostu dzieli po pierwszym
  ## `=` w każdej linii i traktuje `[cokolwiek]` jako nagłówek sekcji,
  ## bez żadnych ograniczeń na dozwolone znaki. Linie zaczynające się od
  ## `#`/`;` i puste są pomijane. To jest WŁAŚNIE to, czego potrzebujemy
  ## tutaj (proste `klucz=wartość` w sekcjach) -- nie potrzebujemy reszty
  ## możliwości `parsecfg` (opcje `--flag`, ciągi w cudzysłowach itd.).
  result = initOrderedTable[string, OrderedTable[string, string]]()
  var curSection = "Icon Theme"  ## klucze przed pierwszym `[...]` (nietypowe, ale bezpieczny domyślny)
  result[curSection] = initOrderedTable[string, string]()
  for rawLine in lines(path):
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#") or line.startsWith(";"): continue
    if line.startsWith("[") and line.endsWith("]"):
      curSection = line[1 ..< line.len - 1]
      if curSection notin result:
        result[curSection] = initOrderedTable[string, string]()
      continue
    let eqIdx = line.find('=')
    if eqIdx < 0: continue  ## linia bez "=" (i nie nagłówek sekcji) -- ignorujemy, nie wywalamy całego pliku
    let key = line[0 ..< eqIdx].strip()
    let value = line[eqIdx + 1 .. ^1].strip()
    result[curSection][key] = value

proc loadThemeMeta(themeName: string): ThemeMeta =
  ## Memoizowane (patrz `gThemeMetaCache`) -- ten sam motyw jest
  ## odpytywany dla KAŻDEJ ikony w KAŻDYM skanie launchera (patrz
  ## `rescanSystemAppsIfChanged`), więc parsowanie `index.theme` od nowa
  ## za każdym razem byłoby zauważalnie marnotrawne, gdy w systemie jest
  ## kilkadziesiąt zainstalowanych aplikacji.
  if gThemeMetaCache.hasKey(themeName): return gThemeMetaCache[themeName]
  result = ThemeMeta(found: false)
  let base = themeBaseDir(themeName)
  if base.len == 0:
    gThemeMetaCache[themeName] = result
    return result
  result.found = true
  result.basePath = base
  try:
    let cfg = parseIniLoose(base / "index.theme")
    if "Icon Theme" in cfg:
      let inheritsRaw = cfg["Icon Theme"].getOrDefault("Inherits", "")
      result.inherits = inheritsRaw.split(',').mapIt(it.strip()).filterIt(it.len > 0)
    for section, kv in cfg.pairs:
      if section == "Icon Theme": continue
      ## Wg specyfikacji brak `Context=` w ogóle też jest dopuszczalny
      ## (niektóre motywy go pomijają) -- traktujemy brakujący klucz jak
      ## "Applications", żeby nie odrzucać takich katalogów; to nieco
      ## szersze niż litera specyfikacji, ale bezpieczniejsze niż
      ## przeoczyć realną ikonę przez brakujące pole w cudzym pliku.
      let context = kv.getOrDefault("Context", "Applications")
      if context != "Applications": continue
      var entry = ThemeDirEntry(relPath: section)
      try: entry.size = parseInt(kv.getOrDefault("Size", "0"))
      except ValueError: entry.size = 0
      try: entry.scale = parseInt(kv.getOrDefault("Scale", "1"))
      except ValueError: entry.scale = 1
      if entry.scale <= 0: entry.scale = 1  ## broniona wartość -- "Scale=0" w cudzym pliku nie powinno się zdarzyć, ale nie ufamy ślepo
      entry.isScalable = kv.getOrDefault("Type", "") == "Scalable" or
                          "scalable" in section.toLowerAscii()
      ## Runda 34 -- Type=/MinSize=/MaxSize=/Threshold= dla pełnych reguł
      ## dopasowania rozmiaru (patrz `dirSizeDistance`). Domyślny `Type`
      ## wg specyfikacji, gdy klucz nie występuje w ogóle, to "Threshold".
      let typeStr = kv.getOrDefault("Type", "Threshold")
      entry.dirType =
        if typeStr == "Fixed": idtFixed
        elif typeStr == "Scalable": idtScalable
        else: idtThreshold
      try: entry.minSize = parseInt(kv.getOrDefault("MinSize", $entry.size))
      except ValueError: entry.minSize = entry.size
      try: entry.maxSize = parseInt(kv.getOrDefault("MaxSize", $entry.size))
      except ValueError: entry.maxSize = entry.size
      if entry.minSize <= 0: entry.minSize = entry.size
      if entry.maxSize <= 0: entry.maxSize = entry.size
      try: entry.threshold = parseInt(kv.getOrDefault("Threshold", "2"))
      except ValueError: entry.threshold = 2
      if entry.threshold < 0: entry.threshold = 2
      result.appDirs.add(entry)
  except CatchableError:
    discard  ## uszkodzony/nietypowy index.theme -- ten motyw po prostu nie wnosi katalogów, ale nie wywraca reszty
  gThemeMetaCache[themeName] = result


proc themeSearchChain(seeds: openArray[string]): seq[string] =
  ## BFS po `Inherits=`, scalając WSZYSTKIE punkty startowe z
  ## `IconThemeSeeds` w jedną, spłaszczoną, pozbawioną duplikatów
  ## kolejność -- z "hicolor" (uniwersalny fallback wg specyfikacji)
  ## zawsze DOPISANYM na końcu, nawet jeśli żaden motyw go jawnie nie
  ## dziedziczy (niektóre index.theme tego nie robią, mimo że powinny).
  var seen = initHashSet[string]()
  var queue: seq[string] = @[]
  for s in seeds:
    if s notin seen:
      seen.incl(s)
      queue.add(s)
  var i = 0
  while i < queue.len:
    let name = queue[i]
    inc i
    result.add(name)
    let meta = loadThemeMeta(name)
    for parent in meta.inherits:
      if parent notin seen:
        seen.incl(parent)
        queue.add(parent)
  if "hicolor" notin seen:
    result.add("hicolor")

proc dirSizeDistance(d: ThemeDirEntry, iconsize: int): int =
  ## Runda 34 -- `DirectorySizeDistance` ze specyfikacji Icon Theme,
  ## zależna od `Type=` katalogu (patrz duży komentarz na górze bloku).
  ## Zwraca 0, gdy katalog DOPASOWUJE się do `iconsize` bez żadnej kary
  ## (`DirectoryMatchesSize` ze specyfikacji to dokładnie `result == 0`).
  case d.dirType
  of idtFixed:
    abs(d.size - iconsize)
  of idtScalable:
    if iconsize < d.minSize: d.minSize - iconsize
    elif iconsize > d.maxSize: iconsize - d.maxSize
    else: 0
  of idtThreshold:
    if iconsize < d.size - d.threshold: (d.size - d.threshold) - iconsize
    elif iconsize > d.size + d.threshold: iconsize - (d.size + d.threshold)
    else: 0

proc pickBestDir(dirs: seq[ThemeDirEntry], wantSvg: bool): seq[ThemeDirEntry] =
  ## Filtruje po typie (SVG vs rastrowe -- rozbudowa woła to osobno dla
  ## obu, patrz `resolveViaThemeSpec`) i sortuje wg `dirSizeDistance`
  ## względem `PreferredIconSize` -- od rundy 34 to PEŁNA funkcja
  ## odległości ze specyfikacji (`Fixed`/`Scalable`/`Threshold`), nie
  ## jednolite `abs(size - Preferred)` używane wcześniej.
  ##
  ## Rozbudowa (ScaledDirectories/HiDPI): PRZED sortowaniem po odległości,
  ## katalogi `Scale=1` są zawsze stawiane PRZED katalogami o wyższej
  ## skali (`@2x`/`@3x`) o tym samym `Size=` -- bez tego dwa katalogi w
  ## TYM SAMYM motywie mogące zawierać RÓŻNE pliki pod tymi samymi
  ## nazwami (np. w prawdziwym `Humanity/index.theme`, zainstalowanym w
  ## tej sandboxie: `[apps/48]` obok `[apps@2/48]`, oba `Size=48`, ale
  ## drugi ma `Scale=2` i jest przeznaczony na ekrany HiDPI) miały
  ## IDENTYCZNĄ odległość od `PreferredIconSize` (zero różnicy), więc to,
  ## który zostanie wybrany, było czystym przypadkiem kolejności w pliku
  ## `index.theme`, nie świadomą decyzją. ZDE nie zna dziś skali
  ## monitora (kompozytor jej nie przekazuje do shellu -- to osobne,
  ## znacznie większe zadanie), więc `Scale=1` jest jedynym rozsądnym,
  ## SPÓJNYM domyślnym wyborem -- katalog o wyższej skali jest brany pod
  ## uwagę TYLKO, gdy w danym motywie nie ma żadnego pasującego katalogu
  ## `Scale=1` (nigdy gorzej niż wcześniej: motyw, który miał tylko
  ## katalogi `@2x`, nadal je znajdzie).
  result = dirs.filterIt(it.isScalable == wantSvg)
  result.sort(proc(a, b: ThemeDirEntry): int =
    let aScale1 = ord(a.scale != 1)
    let bScale1 = ord(b.scale != 1)
    if aScale1 != bScale1: return cmp(aScale1, bScale1)
    cmp(dirSizeDistance(a, PreferredIconSize), dirSizeDistance(b, PreferredIconSize)))

proc resolveViaThemeSpec(iconName: string, wantSvg: bool): string =
  ## Główna ścieżka rezolucji ikon od tej rundy -- patrz duży komentarz
  ## na górze tego bloku. Zwraca "" (nie wyjątek), gdy nic nie znaleziono
  ## przez ŻADEN motyw w łańcuchu -- `resolveIconPath` spada wtedy na
  ## starą płaską listę (`IconSearchTemplates`/`IconSearchTemplatesSvg`)
  ## jako siatkę bezpieczeństwa.
  let chain = themeSearchChain(IconThemeSeeds)
  let ext = if wantSvg: ".svg" else: ".png"
  for themeName in chain:
    let meta = loadThemeMeta(themeName)
    if not meta.found: continue
    for d in pickBestDir(meta.appDirs, wantSvg):
      let candidate = meta.basePath / d.relPath / (iconName & ext)
      if fileExists(candidate):
        return candidate
  ""

proc resolveIconPath(iconField: string): string =
  ## Zwraca bezwzględną ścieżkę do pliku PNG (oryginalnego albo
  ## zrasteryzowanego z SVG do cache'u, patrz `rasterizeSvgIcon`), albo
  ## "", gdy nie znaleziono (wtedy launcher pokazuje ikonę zastępczą
  ## kategorii -- patrz `categoryIcon`). Pole `Icon=` w .desktop bywa
  ## albo już gotową bezwzględną ścieżką (rzadziej), albo -- zdecydowanie
  ## częściej -- samą nazwą motywu bez rozszerzenia (np. `firefox`),
  ## którą trzeba dopiero odnaleźć w jednym z katalogów motywów.
  if iconField.len == 0:
    return ""
  if iconField.isAbsolute():
    if iconField.toLowerAscii().endsWith(".png") and isDecodablePng(iconField):
      return iconField
    if iconField.toLowerAscii().endsWith(".svg") and fileExists(iconField):
      return rasterizeSvgIcon(iconField)
    return ""

  ## Rozbudowa v0.2 (runda 6): prawdziwa rezolucja przez Icon Theme Spec
  ## (`resolveViaThemeSpec`, patrz duży komentarz przy jej definicji)
  ## PRZED płaską listą -- ta ostatnia zostaje wyłącznie jako siatka
  ## bezpieczeństwa, na wypadek gdyby parsowanie `index.theme` zawiodło
  ## z jakiegoś nieprzewidzianego powodu.
  let viaPng = resolveViaThemeSpec(iconField, wantSvg = false)
  if viaPng.len > 0 and isDecodablePng(viaPng): return viaPng
  let viaSvg = resolveViaThemeSpec(iconField, wantSvg = true)
  if viaSvg.len > 0:
    let rasterized = rasterizeSvgIcon(viaSvg)
    if rasterized.len > 0: return rasterized

  for tmpl in IconSearchTemplates:
    let candidate = tmpl % [iconField]
    if fileExists(candidate) and isDecodablePng(candidate):
      return candidate
  for tmpl in IconSearchTemplatesSvg:
    let candidate = tmpl % [iconField]
    if fileExists(candidate):
      let rasterized = rasterizeSvgIcon(candidate)
      if rasterized.len > 0: return rasterized
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

## Rozbudowa v0.2 (launcher -- realny `inotify`, nie tylko mtime): duży
## komentarz nad `appDirsSignature` wyżej (z POPRZEDNIEJ rundy) tłumaczy,
## dlaczego ZDE od dawna polega na sumie mtime katalogów zamiast na
## `inotify` -- integracja z pętlą zdarzeń Fidget/GLFW to osobny,
## niepewny projekt. Ale przy bliższym przyjrzeniu ta sama sygnatura ma
## też DRUGĄ, cichszą wadę, NIEZALEŻNĄ od opóźnienia: mtime KATALOGU
## zmienia się tylko przy zmianach jego STRUKTURY (dodanie/usunięcie/
## zmiana nazwy wpisu) -- edycja TREŚCI istniejącego pliku `.desktop` W
## MIEJSCU (np. aktualizacja pakietu nadpisująca `Name=`/`Icon=` bez
## usuwania i tworzenia pliku na nowo, co jest częstsze niż mogłoby się
## wydawać przy niektórych menedżerach pakietów) NIE dotyka mtime
## katalogu nadrzędnego -- taka zmiana była więc dotąd całkowicie
## NIEWYKRYWALNA przez `appDirsSignature()`, nie tylko wykrywana z
## opóźnieniem.
##
## To poniżej NIE integruje się z pętlą zdarzeń Fidget (wciąż ten sam,
## uzasadniony wyżej powód, żeby tego nie robić) -- zamiast tego otwiera
## deskryptor `inotify` RAZ, w trybie NIEBLOKUJĄCYM (`IN_NONBLOCK`), i
## `rescanSystemAppsIfChanged` w `shell/taskbar.nim` odpytuje go co tick
## (ten sam rytm co dotychczas) przez `read()`, który natychmiast wraca
## z `EAGAIN`, gdy nic się nie zmieniło -- czyli koszt per-tick zostaje
## dokładnie tak niski jak wcześniej (jeden nieblokujący `read()` zamiast
## kilku `stat()`), ale teraz TREŚĆ też jest objęta, nie tylko struktura
## katalogu. Opóźnienie rzędu sekundy (kadencja tickera) zostaje -- to
## wciąż nie jest "klatka po klatce" -- ale to była mniejsza z dwóch
## realnych wad i jaśniej udokumentowana już wcześniej; ta rozbudowa
## domyka tę drugą, cichszą.
const
  IN_NONBLOCK = 0o4000
  IN_CLOEXEC = 0o2000000
  ## Maska zdarzeń: struktura katalogu (tak jak dawało `appDirsSignature`)
  ## ORAZ treść plików w nim (`IN_MODIFY`/`IN_CLOSE_WRITE` -- oba, bo
  ## różne narzędzia zapisujące pliki kończą zapis różnie; interesuje nas
  ## TYLKO "czy cokolwiek się ruszyło", nie który dokładnie wariant).
  WatchMask: uint32 = 0x00000100'u32 or 0x00000200'u32 or 0x00000040'u32 or
                       0x00000080'u32 or 0x00000002'u32 or 0x00000008'u32
                       # IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_MODIFY | IN_CLOSE_WRITE

proc inotify_init1(flags: cint): cint {.importc, header: "<sys/inotify.h>".}
proc inotify_add_watch(fd: cint, pathname: cstring, mask: uint32): cint
  {.importc, header: "<sys/inotify.h>".}

var
  gInotifyFd = -1               ## -1 = jeszcze nie próbowano / próba się nie powiodła (patrz `ensureInotifyWatches`)
  gInotifyAttempted = false     ## odróżnia "jeszcze nie próbowano" od "próbowano, nie wyszło" -- żeby nie dobijać się do jądra co tick, gdy `inotify_init1` raz zawiedzie (np. wyczerpany limit deskryptorów w systemie)
  gWatchedDirs: seq[string]     ## katalogi z AppDirs, na które już założono watch -- unikamy podwójnego `inotify_add_watch` na tej samej ścieżce

proc ensureInotifyWatches() =
  if not gInotifyAttempted:
    gInotifyAttempted = true
    gInotifyFd = inotify_init1(cint(IN_NONBLOCK or IN_CLOEXEC))
    if gInotifyFd < 0:
      return  ## brak inotify (np. bardzo nietypowe jądro/kontener) -- appDirsSignature() zostaje jedynym mechanizmem, cicho
  if gInotifyFd < 0: return
  for dirTmpl in AppDirs:
    let dir = expandTilde(dirTmpl)
    if dir in gWatchedDirs: continue
    if not dirExists(dir): continue
    ## Katalog mógł nie istnieć przy starcie (np. `~/.local/share/applications`
    ## zanim użytkownik cokolwiek tam kiedykolwiek zainstalował) i pojawić
    ## się później -- dlatego to wołane co tick, nie tylko raz przy starcie,
    ## żeby taki katalog dostał watch, gdy tylko powstanie.
    if inotify_add_watch(gInotifyFd.cint, dir.cstring, WatchMask) >= 0:
      gWatchedDirs.add(dir)

proc appDirsChangedViaInotify*(): bool =
  ## Nieblokujący "czy COKOLWIEK się wydarzyło od ostatniego wywołania".
  ## Celowo nie parsujemy pojedynczych zdarzeń z bufora (ich dokładna
  ## treść, np. która nazwa pliku, i tak nas nie interesuje -- każde
  ## zdarzenie i tak kończy się tym samym pełnym `scanDesktopApps()`) --
  ## wystarczy wiedzieć, że bufor NIE BYŁ pusty, więc jeden `read()` do
  ## bufora na stosie w zupełności starcza, nawet jeśli w kolejce czeka
  ## więcej niż jedno zdarzenie (kolejny `read()` przy następnym ticku i
  ## tak by je osuszył, zanim ktokolwiek by to zauważył).
  ensureInotifyWatches()
  if gInotifyFd < 0: return false
  var buf: array[512, byte]
  let n = read(gInotifyFd.cint, addr buf[0], buf.len)
  n > 0

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
