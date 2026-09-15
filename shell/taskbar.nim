import std/strutils
import fidget
import ../comp/comp
import state
import launcher_apps
import ../apps/session/session
import notifications
import desktopapps
import quicksettings
import clipboard

proc doLockScreen() = lockScreen()
proc doLogout() = logout()

## Rozbudowa v0.1 ("Aurora"): pasek zadań przestał być pełną, sztywną belwą
## od krawędzi do krawędzi -- teraz to "pływający" dok, wcięty marginesem
## od dołu/boków ekranu, półprzezroczysty, zaokrąglony, z ikonami zamiast
## gołego tekstu na przyciskach okien. Wysokość zarezerwowanego pasa u dołu
## ekranu (`TaskbarHeight` z `comp/types.nim`) NIE jest zmieniana -- inny
## kod (np. maksymalizacja okna w `comp/window.nim`) liczy z niej dostępną
## wysokość pulpitu, więc zmiana tej stałej miałaby dużo szerszy wpływ, niż
## chcemy przy czysto wizualnej rozbudowie. Zamiast tego dok jest nagle
## WCIĘTY o `DockMargin` w tym samym pasie.

const
  DockMargin = 8.0'f32     ## odstęp doku od lewej/prawej/dolnej krawędzi ekranu
  DockPad = 5.0'f32        ## wewnętrzny margines treści doku od jego własnej ramki

type
  ## Patrz duży komentarz przy `AppCatalog` niżej o tym, dlaczego pole
  ## `action` MUSI być `proc() {.closure.}` (nie samo `proc()`), i
  ## dlaczego lambdy przypisane do niego niżej też potrzebują tej samej
  ## jawnej pragmy na sobie -- to nie jest kosmetyka, kod bez tego nie
  ## kompilował się wcale.
  ## `iconPath` -- rozbudowa v0.1 ("Aurora" -- prawdziwe aplikacje
  ## systemowe): "" oznacza "użyj emoji z pola `icon`" (wbudowane
  ## aplikacje ZDE), niepusta wartość to bezwzględna ścieżka do PNG,
  ## którą `drawLauncherRow` renderuje przez `image(...)` zamiast emoji.
  AppEntry = tuple[icon: string, label: string, iconPath: string, action: proc() {.closure.}]

proc drawLauncherRow(e: AppEntry, iy, w, itemH: float32) =
  ## Wspólny rysownik jednego wiersza launchera -- używany zarówno dla
  ## wbudowanych aplikacji ZDE, jak i prawdziwych aplikacji systemowych
  ## (`desktopapps.nim`), żeby nie powielać tego samego bloku (i nie
  ## rozjeżdżać ich przy przyszłych zmianach wyglądu).
  group "launcher-item-" & e.label:
    box 6, iy, w - 12, itemH - 4
    cornerRadius RadiusSm
    fill "#000000", 0.0
    onHover: fill PanelBgHover
    onClick:
      e.action()
      compositor.launcherOpen = false
      compositor.launcherSearch = ""
    group "launcher-item-badge-" & e.label:
      box 6, 3, itemH - 10, itemH - 10
      cornerRadius RadiusSm
      fill "#242b34"
      if e.iconPath.len > 0:
        ## Rozbudowa v0.1: prawdziwa ikona aplikacji systemowej (PNG,
        ## odnaleziona przez `desktopapps.resolveIconPath`). `dataDir`
        ## jest ustawione na "/" w `shell.nim` (`when isMainModule`),
        ## więc przekazujemy ścieżkę BEZ wiodącego "/" -- patrz komentarz
        ## tam po wyjaśnienie. `image(...)` to WŁAŚCIWOŚĆ węzła (jak
        ## `fill`), nie osobny typ bloku -- stąd zwykły `rectangle`, nie
        ## nieistniejący blok "image".
        rectangle "launcher-item-image-" & e.label:
          box 0, 0, itemH - 10, itemH - 10
          image e.iconPath[1 .. ^1]
      else:
        text "launcher-item-icon-" & e.label:
          box 0, 0, itemH - 10, itemH - 10
          font "sans-serif", 14, 400, itemH - 10, hCenter, vCenter
          fill TextPrimary
          characters e.icon
    text "launcher-item-label-" & e.label:
      box itemH + 4, 0, w - itemH - 20, itemH - 4
      font "sans-serif", 13, 400, itemH - 4, hLeft, vCenter
      fill TextPrimary
      characters e.label

## Jedno źródło prawdy dla ikon i akcji aplikacji -- używane zarówno przez
## launcher (menu startowe), jak i przez `iconForTitle` niżej (żeby
## przyciski otwartych okien na docku pokazywały tę samą ikonkę, którą
## użytkownik kliknął w launcherze, zamiast osobnej, niezależnie
## utrzymywanej listy emoji, która łatwo rozjeżdża się z rzeczywistością).
##
## NAPRAWIONY BŁĄD KOMPILACJI (znaleziony realną kompilacją -- patrz
## README): gołe nazwy procedur (`action: launchTerminal`) i nawet
## anonimowe lambdy bez jawnej pragmy (`action: proc() = launchTerminal()`)
## NIE przechodziły type-checkingu jako `seq[AppEntry]`. Powód: `proc()`
## jako typ POLA domyślnie oznacza wywołanie przez zamknięcie
## (`{.closure.}`), ale lambda, która niczego nie przechwytuje z
## otoczenia (jak te niżej -- każda tylko woła jedną top-levelową
## procedurę), dostaje od Nima *optymalizowany* typ BEZ `{.closure.}`,
## bo faktycznie żadnego środowiska nie potrzebuje. Efekt: "prawie
## identyczne" typy proc, które Nim i tak traktuje jako niezgodne.
## Jawna pragma `{.closure.}` na każdej lambdzie (nie na typie pola --
## to już było wypróbowane i nie wystarczało) wymusza właściwy typ.
let AppCatalog: seq[AppEntry] = @[
  AppEntry (icon: "🖥", label: "Terminal", iconPath: "", action: (proc() {.closure.} = launchTerminal())),
  AppEntry (icon: "📁", label: "Menedżer plików", iconPath: "", action: (proc() {.closure.} = launchFileManager())),
  AppEntry (icon: "🕐", label: "Zegar", iconPath: "", action: (proc() {.closure.} = launchClock())),
  AppEntry (icon: "📝", label: "Edytor tekstu", iconPath: "", action: (proc() {.closure.} = launchTextEditor())),
  AppEntry (icon: "🧮", label: "Kalkulator", iconPath: "", action: (proc() {.closure.} = launchCalculator())),
  AppEntry (icon: "📊", label: "Monitor systemu", iconPath: "", action: (proc() {.closure.} = launchSysMonitor())),
  AppEntry (icon: "⚙", label: "Ustawienia", iconPath: "", action: (proc() {.closure.} = launchSettings())),
]
let SystemCatalog: seq[AppEntry] = @[
  AppEntry (icon: "🔒", label: "Zablokuj ekran", iconPath: "", action: (proc() {.closure.} = doLockScreen())),
  AppEntry (icon: "⏻", label: "Wyloguj", iconPath: "", action: (proc() {.closure.} = doLogout())),
  AppEntry (icon: "ℹ", label: "O systemie", iconPath: "", action: (proc() {.closure.} = launchAbout())),
]

## Rozbudowa v0.1 ("Aurora" -- prawdziwe aplikacje systemowe): skanujemy
## `.desktop` pliki przy starcie `zde-shell` (moduł ładuje się raz, na
## starcie procesu) I odświeżamy w tle -- patrz
## `rescanSystemAppsIfChanged`/`SystemAppGroups` niżej oraz
## `shell/desktopapps.nim` po pełne uzasadnienie i ograniczenia.
proc makeSystemAppAction(app: DesktopApp): proc() {.closure.} =
  ## Zwykła procedura zwracająca zamknięcie, NIE zamknięcie zadeklarowane
  ## wprost w pętli niżej -- `app` jest tu WŁASNYM parametrem tej
  ## procedury (świeża kopia przy każdym wywołaniu), więc nie ma ryzyka
  ## klasycznej pułapki "wszystkie domknięcia w pętli współdzielą tę samą
  ## zmienną pętli", na którą Nim jest podatny poza makrami DSL-a Fidget
  ## (tam, wewnątrz `onClick` itp., jest to bezpieczne inaczej -- patrz
  ## komentarz przy pętli `for win in compositor.windows` w `drawTaskbar`).
  proc() = launchDesktopApp(app)

proc buildSystemAppGroups(): seq[tuple[category: string, apps: seq[AppEntry]]] =
  ## `scanDesktopApps()` już zwraca posortowane po kategorii -- tu tylko
  ## rozbijamy tę płaską listę na grupy z zachowaniem kolejności, żeby
  ## `drawLauncher()` mogło pokazać nagłówek kategorii przed każdą grupą.
  var current = ""
  for app in scanDesktopApps():
    let entry: AppEntry = (icon: categoryIcon(app.category), label: app.name,
                           iconPath: app.iconPath, action: makeSystemAppAction(app))
    if app.category != current or result.len == 0:
      result.add((category: app.category, apps: @[entry]))
      current = app.category
    else:
      result[^1].apps.add(entry)

var SystemAppGroups = buildSystemAppGroups()
## Rozbudowa: sygnatura katalogów `.desktop` w momencie ostatniego
## skanowania -- patrz `rescanSystemAppsIfChanged` niżej i
## `desktopapps.appDirsSignature` po pełne uzasadnienie tego mechanizmu.
var lastAppDirsSignature = appDirsSignature()

proc rescanSystemAppsIfChanged*() =
  ## Wołane raz na sekundę z `tickMain()` w `shell/shell.nim` (ten sam
  ## rytm co zegar/monitor systemu) -- przebudowuje `SystemAppGroups`
  ## TYLKO wtedy, gdy `appDirsSignature()` faktycznie się zmieniło (nowy
  ## pakiet zainstalowany/usunięty), więc w normalnej pracy to tylko
  ## tania sumaryczna operacja na kilku `stat()`, nie pełne, kosztowne
  ## parsowanie wszystkich plików `.desktop` w systemie co sekundę.
  let sig = appDirsSignature()
  if sig != lastAppDirsSignature:
    lastAppDirsSignature = sig
    SystemAppGroups = buildSystemAppGroups()

proc iconForTitle(title: string): string =
  for e in AppCatalog:
    if e.label == title: return e.icon
  for e in SystemCatalog:
    if e.label == title: return e.icon
  "▢"  ## ikona zastępcza dla okien bez dopasowania (np. przyszłe aplikacje zewnętrzne)

var launcherScrollY: float32 = 0.0  ## przewinięcie listy launchera, patrz `drawLauncher`
var selectedCategory: string = ""  ## "" = "Wszystkie" -- wybrana kategoria w filtrze launchera (patrz `drawLauncher`)

## Kolejność prezentacji kategorii w pasku filtrów -- ta sama, "sensowna"
## kolejność co `CategoryIcons` w `desktopapps.nim` (najpierw to, czego
## użytkownik szuka najczęściej), NIE alfabetyczna (w jakiej
## `SystemAppGroups` trzyma je do samego wyświetlania listy).
const CategoryOrder = ["Internet", "Biuro", "Grafika", "Multimedia",
  "Programowanie", "Gry", "Edukacja", "Narzędzia", "System", "Inne"]

proc drawTaskbar*() =
  let dockH = TaskbarHeight - DockMargin * 2
  ## NAPRAWIONY BUG (znaleziony realnym uruchomieniem pod Xvfb + zrzutem
  ## ekranu -- dok był całkowicie niewidoczny, wyrenderowany ~750px pod
  ## dolną krawędzią ekranu): `box x, y, ...` w Fidget jest ZAWSZE
  ## względem WŁASNEGO RODZICA (`node.screenBox = node.box +
  ## parent.screenBox`, patrz `fidget/common.nim`), nie względem ekranu.
  ## "dock" jest DZIECKIEM ramki "taskbar" (patrz niżej), której własny
  ## `screenBox.y` to już `windowSize.y - TaskbarHeight` -- więc lokalne
  ## `y` dziecka powinno liczyć się OD TEGO punktu (czyli po prostu
  ## `DockMargin`), a nie od (0,0) całego ekranu. Poprzedni kod liczył
  ## `dockY` tak, jakby "dock" był dzieckiem ekranu wprost, przez co
  ## przesunięcie rodzica ("taskbar") doliczało się PONOWNIE.
  let dockY = DockMargin
  let dockX = DockMargin
  let dockW = windowSize.x - DockMargin * 2

  frame "taskbar":
    ## Ramka `frame` obejmuje cały zarezerwowany pas (nie tylko sam dok),
    ## żeby kliknięcia poza dokiem (na goły pulpit tuż nad nim) przechodziły
    ## normalnie dalej -- sam dok jest mniejszą, wciętą grupą poniżej.
    box 0, windowSize.y - TaskbarHeight, windowSize.x, TaskbarHeight
    fill "#000000", 0.0

    group "dock":
      box dockX, dockY, dockW, dockH
      fill Glass, GlassAlpha
      stroke GlassBorder
      strokeWeight 1
      cornerRadius RadiusLg
      ## Jw. -- `zLevel` w Fidget to no-op (patrz duży komentarz w
      ## `shell.nim` przy `drawMain()`). Prawdziwy z-order doku ponad
      ## oknami zapewnia kolejność wywołań w `drawMain()`.

      rectangle "dock-highlight":
        box 1, 1, dockW - 2, 1
        fill "#ffffff", 0.06

      group "launcher-btn":
        box DockPad, DockPad, dockH - DockPad * 2, dockH - DockPad * 2
        cornerRadius RadiusMd
        fill (if compositor.launcherOpen: AccentColor else: PanelBgHover)
        onHover:
          if not compositor.launcherOpen:
            fill "#2f3844"
        onClick:
          compositor.launcherOpen = not compositor.launcherOpen
          compositor.launcherSearch = ""
          launcherScrollY = 0.0
          if compositor.launcherOpen:
            compositor.notifCenterOpen = false
            compositor.quickSettingsOpen = false
            compositor.clipboardHistoryOpen = false
        text "launcher-label":
          box 0, 0, dockH - DockPad * 2, dockH - DockPad * 2
          font "sans-serif", 15, 700, dockH - DockPad * 2, hCenter, vCenter
          fill (if compositor.launcherOpen: "#0f1115" else: TextPrimary)
          characters "◆"

      rectangle "dock-divider-1":
        box dockH + 2, DockPad, 1, dockH - DockPad * 2
        fill "#ffffff", 0.06

      # -- przełącznik pulpitów wirtualnych (rozbudowa v0.1 "Aurora") --------
      # Cztery kwadraciki z numerem pulpitu; aktywny podświetlony akcentem,
      # pozostałe dostają małą kropkę, gdy mają na sobie choć jedno okno
      # (żeby dało się zobaczyć "gdzie coś zostało otwarte" bez przełączania).
      const wsSize = 24.0'f32
      const wsGap = 3.0'f32
      group "workspace-switcher":
        box dockH + 12, DockPad, float32(WorkspaceCount) * (wsSize + wsGap) - wsGap, dockH - DockPad * 2
        for ws in 0 ..< WorkspaceCount:
          let active = ws == compositor.currentWorkspace
          var hasWindows = false
          for win in compositor.windows:
            if win.workspace == ws: hasWindows = true; break
          group "workspace-btn-" & $ws:
            box float32(ws) * (wsSize + wsGap), 0, wsSize, dockH - DockPad * 2
            cornerRadius RadiusSm
            fill (if active: AccentColor else: "#20262f")
            onHover:
              if not active: fill "#2a313c"
            onClick:
              compositor.switchWorkspace(ws)
            text "workspace-btn-label-" & $ws:
              box 0, 0, wsSize, dockH - DockPad * 2
              font "sans-serif", 11, 700, dockH - DockPad * 2, hCenter, vCenter
              fill (if active: "#0f1115" else: TextMuted)
              characters $(ws + 1)
            if hasWindows and not active:
              rectangle "workspace-btn-dot-" & $ws:
                box wsSize / 2 - 2, (dockH - DockPad * 2) - 6, 4, 4
                fill AccentColor
                cornerRadius 2

      rectangle "dock-divider-ws":
        box dockH + 18 + float32(WorkspaceCount) * (wsSize + wsGap), DockPad, 1, dockH - DockPad * 2
        fill "#ffffff", 0.06

      # -- przyciski otwartych okien (tylko z BIEŻĄCEGO pulpitu, rozbudowa
      # v0.1 "Aurora" -- pulpity wirtualne; zminimalizowane NADAL się
      # pokazują -- to jedyny sposób, żeby je przywrócić) --------------------
      var x = dockH + 24 + float32(WorkspaceCount) * (wsSize + wsGap)
      let btnH = dockH - DockPad * 2
      for win in compositor.windows:
        if win.workspace != compositor.currentWorkspace: continue
        let isActive = win.id == compositor.focusedId and not win.minimized
        let w = 168.0'f32
        group "task-" & $win.id:
          box x, DockPad, w, btnH
          cornerRadius RadiusMd
          fill (if isActive: PanelBgHover elif win.minimized: "#15181e" else: "#1e232b")
          if isActive:
            stroke AccentColor
            strokeWeight 1
          onHover: fill "#2a323d"
          onClick:
            if win.minimized or compositor.focusedId != win.id:
              compositor.restoreWindow(win.id)
            else:
              compositor.minimizeWindow(win.id)
          text "task-icon-" & $win.id:
            box 8, 0, 22, btnH
            font "sans-serif", 13, 400, btnH, hLeft, vCenter
            fill (if win.minimized: TextFaint else: TextPrimary)
            characters iconForTitle(win.title)
          text "task-label-" & $win.id:
            box 30, 0, w - 38, btnH
            font "sans-serif", 11, 500, btnH, hLeft, vCenter
            fill (if win.minimized: TextFaint else: TextMuted)
            characters win.title
          if isActive:
            rectangle "task-active-dot-" & $win.id:
              box w - 12, btnH / 2 - 2, 4, 4
              fill AccentColor
              cornerRadius 2
        x += w + 6

      ## Prawa strona doku: [divider][quick settings][divider][dzwonek]
      ## [divider][schowek][divider][zegar]. Rozbudowa (historia schowka)
      ## dołożyła kolejny przycisk do tej strefy -- podobnie jak quick
      ## settings wcześniej, policzone jako zmienne, nie kolejne magiczne
      ## literały, żeby nie trzeba było ręcznie przeliczać wszystkich
      ## sąsiednich pozycji przy każdej zmianie.
      let rightBtnW = dockH - DockPad * 2
      let clockW = 92.0'f32
      let rightZoneW = 8.0'f32 + rightBtnW + 8.0'f32 + rightBtnW + 8.0'f32 +
        rightBtnW + 8.0'f32 + clockW
      let rightZoneX = dockW - rightZoneW

      rectangle "dock-divider-2":
        box rightZoneX, DockPad, 1, dockH - DockPad * 2
        fill "#ffffff", 0.06

      # -- głośność/jasność (rozbudowa v0.1 "Aurora" -- quick settings) -------
      group "quicksettings-btn":
        box rightZoneX + 8, DockPad, rightBtnW, rightBtnW
        cornerRadius RadiusMd
        fill (if compositor.quickSettingsOpen: AccentColor else: PanelBgHover)
        onHover:
          if not compositor.quickSettingsOpen: fill "#2f3844"
        onClick:
          compositor.quickSettingsOpen = not compositor.quickSettingsOpen
          if compositor.quickSettingsOpen:
            compositor.launcherOpen = false
            compositor.notifCenterOpen = false
            compositor.clipboardHistoryOpen = false
        text "quicksettings-label":
          box 0, 0, rightBtnW, rightBtnW
          font "sans-serif", 14, 400, rightBtnW, hCenter, vCenter
          fill (if compositor.quickSettingsOpen: "#0f1115" else: TextPrimary)
          characters "🔊"

      rectangle "dock-divider-qs":
        box rightZoneX + 8 + rightBtnW + 8, DockPad, 1, dockH - DockPad * 2
        fill "#ffffff", 0.06

      # -- dzwonek (centrum powiadomień) --------------------------------------
      group "bell-btn":
        box rightZoneX + 16 + rightBtnW, DockPad, rightBtnW, rightBtnW
        cornerRadius RadiusMd
        fill (if compositor.notifCenterOpen: AccentColor else: PanelBgHover)
        onHover:
          if not compositor.notifCenterOpen:
            fill "#2f3844"
        onClick:
          compositor.notifCenterOpen = not compositor.notifCenterOpen
          if compositor.notifCenterOpen:
            compositor.launcherOpen = false
            compositor.quickSettingsOpen = false
            compositor.clipboardHistoryOpen = false
        text "bell-label":
          box 0, 0, rightBtnW, rightBtnW
          font "sans-serif", 14, 400, rightBtnW, hCenter, vCenter
          fill (if compositor.notifCenterOpen: "#0f1115" else: TextPrimary)
          characters (if isDndEnabled(): "🔕" else: "🔔")
        if not compositor.notifCenterOpen and historySnapshot().len > 0:
          rectangle "bell-badge":
            box rightBtnW - 8, 2, 6, 6
            fill (if isDndEnabled(): TextFaint else: AccentColor)
            cornerRadius 3

      rectangle "dock-divider-3":
        box rightZoneX + 24 + rightBtnW * 2, DockPad, 1, dockH - DockPad * 2
        fill "#ffffff", 0.06

      # -- schowek (historia kopiowanych fragmentów, rozbudowa) ---------------
      group "clipboard-btn":
        box rightZoneX + 32 + rightBtnW * 2, DockPad, rightBtnW, rightBtnW
        cornerRadius RadiusMd
        fill (if compositor.clipboardHistoryOpen: AccentColor else: PanelBgHover)
        onHover:
          if not compositor.clipboardHistoryOpen: fill "#2f3844"
        onClick:
          compositor.clipboardHistoryOpen = not compositor.clipboardHistoryOpen
          if compositor.clipboardHistoryOpen:
            compositor.launcherOpen = false
            compositor.quickSettingsOpen = false
            compositor.notifCenterOpen = false
        text "clipboard-label":
          box 0, 0, rightBtnW, rightBtnW
          font "sans-serif", 14, 400, rightBtnW, hCenter, vCenter
          fill (if compositor.clipboardHistoryOpen: "#0f1115" else: TextPrimary)
          characters "📋"
        if not compositor.clipboardHistoryOpen and clipboardHistorySnapshot().len > 0:
          rectangle "clipboard-badge":
            box rightBtnW - 8, 2, 6, 6
            fill AccentColor
            cornerRadius 3

      rectangle "dock-divider-4":
        box rightZoneX + 40 + rightBtnW * 3, DockPad, 1, dockH - DockPad * 2
        fill "#ffffff", 0.06

      # -- zegar (godzina) -----------------------------------------------------
      text "clock":
        box dockW - clockW - 8, 0, clockW, dockH
        font "monospace", 14, 600, dockH, hRight, vCenter
        fill TextPrimary
        characters clockText

proc drawLauncher*() =
  ## Filtrowanie na żywo po ikonie+etykiecie -- porównanie bez
  ## uwzględniania wielkości liter (ASCII -- spójnie z resztą kodu, patrz
  ## np. `apps/filemanager/files.nim`/`shell/shortcuts.nim`, które też
  ## używają `toLowerAscii`, nie przestarzałego/usuniętego `toLower`).
  ## Puste pole wyszukiwania pokazuje wszystko.
  let query = compositor.launcherSearch.toLowerAscii()
  proc matches(label: string): bool =
    query.len == 0 or label.toLowerAscii().contains(query)

  ## Rozbudowa v0.1 ("Aurora" -- filtr kategorii): pasek "chipów" pod
  ## wyszukiwarką -- "Wszystkie" + jedna na każdą kategorię, która
  ## faktycznie ma choć jedną aplikację (nie pokazujemy pustych filtrów).
  ## Fidget nie ma API do mierzenia szerokości tekstu przed narysowaniem,
  ## więc szerokość chipa jest PRZYBLIŻONA z długości etykiety (~6.5px/znak
  ## dla fontu 10px) -- niedoskonałe, ale dla krótkich, jednowyrazowych
  ## nazw kategorii wystarczająco dokładne, żeby chipy nie zachodziły na
  ## siebie ani nie zostawiały rażących dziur.
  const
    w = 280.0'f32
    chipH = 22.0'f32
    chipGap = 6.0'f32
    chipPadX = 10.0'f32
    chipsAreaW = w - 28.0'f32

  var presentCategories: seq[string] = @[]
  for cat in CategoryOrder:
    for g in SystemAppGroups:
      if g.category == cat and g.apps.len > 0:
        presentCategories.add(cat)
        break

  type ChipLayout = tuple[label: string, value: string, x, y, cw: float32]
  var chips: seq[ChipLayout] = @[]
  block layoutChips:
    var catPairs: seq[(string, string)] = @[("Wszystkie", "")]
    for cat in presentCategories:
      catPairs.add((cat, cat))
    var cx = 0.0'f32
    var cy = 0.0'f32
    for (label, value) in catPairs:
      let cw = float32(label.len).float32 * 6.5'f32 + chipPadX * 2
      if cx + cw > chipsAreaW and cx > 0:
        cx = 0
        cy += chipH + chipGap
      chips.add((label: label, value: value, x: cx, y: cy, cw: cw))
      cx += cw + chipGap
    ## Jeśli wcześniej wybrana kategoria zniknęła (np. wyszukiwanie ją
    ## wyfiltrowało do zera aplikacji), wracamy do "Wszystkie" zamiast
    ## pokazywać pusty, "osierocony" filtr.
    if selectedCategory.len > 0 and selectedCategory notin presentCategories:
      selectedCategory = ""
  let chipsH = (if chips.len == 0: 0.0'f32 else: chips[^1].y + chipH)

  var visibleApps: seq[AppEntry] = @[]
  var visibleSystem: seq[AppEntry] = @[]
  var visibleSystemGroups: seq[tuple[category: string, apps: seq[AppEntry]]] = @[]
  if selectedCategory.len == 0:
    for e in AppCatalog:
      if matches(e.label): visibleApps.add(e)
    for e in SystemCatalog:
      if matches(e.label): visibleSystem.add(e)
    ## Te same grupy co `SystemAppGroups` (zeskanowane przy starcie i
    ## odświeżane w tle -- patrz `rescanSystemAppsIfChanged`), ale
    ## przefiltrowane wg bieżącego zapytania -- grupa, w której nic
    ## nie pasuje, po prostu znika (nie pokazujemy pustych nagłówków).
    for g in SystemAppGroups:
      var matched: seq[AppEntry] = @[]
      for e in g.apps:
        if matches(e.label): matched.add(e)
      if matched.len > 0:
        visibleSystemGroups.add((category: g.category, apps: matched))
  else:
    ## Konkretna kategoria wybrana -- pokazujemy TYLKO ją (bez wbudowanych
    ## aplikacji ZDE, które nie mają przypisanej kategorii XDG, i bez
    ## sekcji "System"), żeby filtr faktycznie zawężał widok, a nie tylko
    ## dokładał nagłówek nad tym samym co zawsze.
    for g in SystemAppGroups:
      if g.category != selectedCategory: continue
      var matched: seq[AppEntry] = @[]
      for e in g.apps:
        if matches(e.label): matched.add(e)
      if matched.len > 0:
        visibleSystemGroups.add((category: g.category, apps: matched))

  const
    itemH = 38.0'f32
    baseHeaderH = 56.0'f32
    sectionGap = 8.0'f32
    catHeaderH = 22.0'f32
    ## Rozbudowa v0.1 ("Aurora" -- przewijanie): przy dziesiątkach
    ## prawdziwych aplikacji systemowych lista MUSI się przewijać, zamiast
    ## karty rosnącej poza ekran -- ten sam wzorzec co centrum powiadomień
    ## (`drawNotificationCenter`) i lista alarmów zegara.
    MaxBodyH = 400.0'f32

  ## Pasek chipów dostaje własny pas WYSOKOŚCI pod nagłówkiem (nie jest
  ## częścią przewijanej listy) -- filtr kategorii ma być zawsze widoczny,
  ## niezależnie od tego, jak daleko przewinięto listę pod nim.
  let headerH = baseHeaderH + chipsH + (if chips.len > 0: 10.0'f32 else: 0.0'f32)

  var systemAppCount = 0
  for g in visibleSystemGroups: systemAppCount += g.apps.len
  var bodyH = float32(visibleApps.len + visibleSystem.len) * itemH +
              (if visibleSystem.len > 0: sectionGap else: 0.0'f32) +
              float32(systemAppCount) * itemH +
              float32(visibleSystemGroups.len) * catHeaderH +
              (if visibleSystemGroups.len > 0 and (visibleApps.len > 0 or visibleSystem.len > 0): sectionGap else: 0.0'f32) + 8.0'f32
  if visibleApps.len == 0 and visibleSystem.len == 0 and systemAppCount == 0:
    bodyH = itemH + 8.0'f32

  let visibleBodyH = min(bodyH, MaxBodyH)
  let maxScroll = max(0.0'f32, bodyH - visibleBodyH)
  launcherScrollY = clamp(launcherScrollY, 0.0'f32, maxScroll)

  let h = headerH + visibleBodyH
  let y = windowSize.y - TaskbarHeight - h - DockMargin
  let x = DockMargin

  frame "launcher":
    box x, y, w, h
    fill Glass, 0.97
    stroke GlassBorder
    strokeWeight 1
    cornerRadius RadiusLg
    ## Jw. -- launcher jest na wierzchu paska zadań i okien, bo
    ## `drawMain()` woła `drawLauncher()` jako PIERWSZE (patrz shell.nim).

    onClickOutside:
      compositor.launcherOpen = false
      compositor.launcherSearch = ""

    # -- nagłówek: branding + pole wyszukiwania ------------------------------
    group "launcher-header":
      box 0, 0, w, baseHeaderH
      text "launcher-brand":
        box 14, 8, w - 28, 16
        font "sans-serif", 10, 700, 16, hLeft, vTop
        fill TextFaint
        characters "ZDE -- ZENIT DESKTOP ENVIRONMENT"

      group "launcher-search":
        box 14, 26, w - 28, 24
        cornerRadius RadiusSm
        fill "#0f1216"
        stroke GlassBorder
        strokeWeight 1
        text "launcher-search-field":
          box 10, 0, w - 28 - 20, 24
          font "sans-serif", 12, 400, 24, hLeft, vCenter
          fill TextPrimary
          editableText true
          selectable true
          ## Ten sam wzorzec co pole ścieżki w `apps/texteditor/texteditor.nim`:
          ## gdy pole NIE ma fokusu, sami ustawiamy `characters` na
          ## zapamiętaną wartość (albo placeholder, gdy pusta) -- silnik
          ## sam pokazuje żywy bufor `keyboard.input` TYLKO gdy pole jest
          ## akurat skupione.
          if not current.hasKeyboardFocus():
            characters (if compositor.launcherSearch.len > 0: compositor.launcherSearch
                        else: "Szukaj aplikacji...")
          onClick:
            keyboard.focus(current)
          onInput:
            compositor.launcherSearch = keyboard.input

    # -- pasek filtrów kategorii ---------------------------------------------
    if chips.len > 0:
      group "launcher-chips":
        box 14, baseHeaderH, w - 28, chipsH
        for chip in chips:
          let active = selectedCategory == chip.value
          group "launcher-chip-" & chip.label:
            box chip.x, chip.y, chip.cw, chipH
            cornerRadius 11
            fill (if active: AccentColor else: "#20262f")
            onHover:
              if not active: fill "#2a313c"
            onClick:
              selectedCategory = chip.value
              launcherScrollY = 0.0
            text "launcher-chip-label-" & chip.label:
              box 0, 0, chip.cw, chipH
              font "sans-serif", 10, 600, chipH, hCenter, vCenter
              fill (if active: "#0f1115" else: TextMuted)
              characters chip.label

    rectangle "launcher-header-divider":
      box 8, headerH, w - 16, 1
      fill "#ffffff", 0.06

    if visibleApps.len == 0 and visibleSystem.len == 0 and systemAppCount == 0:
      text "launcher-empty":
        box 14, headerH + 6, w - 28, itemH
        font "sans-serif", 12, 400, itemH, hLeft, vCenter
        fill TextFaint
        characters "Brak wyników dla \"" & compositor.launcherSearch & "\""
    else:
      group "launcher-body":
        box 0, headerH, w, visibleBodyH
        clipContent true
        onHover:
          if mouse.wheelDelta != 0:
            launcherScrollY = clamp(launcherScrollY - mouse.wheelDelta * 40.0'f32, 0.0'f32, maxScroll)

        var iy = 6.0'f32 - launcherScrollY

        for e in visibleApps:
          drawLauncherRow(e, iy, w, itemH)
          iy += itemH

        if visibleSystem.len > 0:
          if visibleApps.len > 0:
            rectangle "launcher-section-divider":
              box 8, iy + sectionGap / 2 - 0.5, w - 16, 1
              fill "#ffffff", 0.06
            iy += sectionGap

          for e in visibleSystem:
            drawLauncherRow(e, iy, w, itemH)
            iy += itemH

        ## Rozbudowa v0.1 ("Aurora" -- prawdziwe aplikacje systemowe):
        ## grupy wg kategorii XDG (Internet, Biuro, Grafika...), każda z
        ## małym nagłówkiem -- to jest ta część, która realnie odróżnia
        ## ten launcher od "listy 7 przycisków": każdy zainstalowany w
        ## systemie program z plikiem `.desktop` (patrz `desktopapps.nim`)
        ## ląduje tutaj automatycznie, z prawdziwą ikoną, gdy tylko da się
        ## ją znaleźć. Gdy filtr kategorii jest aktywny (`selectedCategory`),
        ## `visibleSystemGroups` ma już tylko JEDNĄ grupę -- nagłówek nadal
        ## się pokazuje, dla spójności z widokiem "Wszystkie".
        if visibleSystemGroups.len > 0:
          if visibleApps.len > 0 or visibleSystem.len > 0:
            iy += sectionGap
          for g in visibleSystemGroups:
            text "launcher-cat-" & g.category:
              box 14, iy, w - 28, catHeaderH
              font "sans-serif", 10, 700, catHeaderH, hLeft, vBottom
              fill TextFaint
              characters g.category.toUpperAscii()
            iy += catHeaderH
            for e in g.apps:
              drawLauncherRow(e, iy, w, itemH)
              iy += itemH

proc drawHistoryRow(e: HistoryEntry, idx: int, iy, w: float32): float32 =
  ## Rysuje jeden wiersz historii powiadomień i zwraca jego wysokość (te
  ## różnią się -- treść jednolinijkowa vs dwulinijkowa -- stąd zwracamy
  ## faktyczne zużyte miejsce zamiast zakładać stałą wysokość, tak jak
  ## `drawNotifications` w `notifications.nim` liczy `h` per-toast).
  let bodyLines = if e.body.len > 46: 2 else: 1
  let h = 40.0'f32 + float32(bodyLines) * 14.0'f32

  group "hist-row-" & $idx:
    box 8, iy, w - 16, h - 4
    cornerRadius RadiusSm
    fill "#171b22"

    rectangle "hist-accent-" & $idx:
      box 0, 0, 3, h - 4
      fill accentFor(e.kind)
      cornerRadius 1.5

    text "hist-title-" & $idx:
      box 12, 5, w - 16 - 24 - 12, 16
      font "sans-serif", 11, 700, 16, hLeft, vCenter
      fill TextPrimary
      characters iconFor(e.kind) & "  " & e.title

    text "hist-body-" & $idx:
      box 12, 21, w - 16 - 12, h - 4 - 23
      font "sans-serif", 10, 400, 13, hLeft, vTop
      fill TextMuted
      characters e.body

    text "hist-ago-" & $idx:
      box w - 16 - 78, 5, 74, 16
      font "sans-serif", 9, 400, 16, hRight, vCenter
      fill TextFaint
      characters formatAgo(e.at)

  h

var notifScrollY: float32 = 0.0  ## przewinięcie panelu historii, patrz `drawNotificationCenter`

proc drawNotificationCenter*() =
  ## Panel historii powiadomień -- otwierany dzwonkiem w doku
  ## (`drawTaskbar`). Ten sam wizualny język co `drawLauncher` (karta
  ## "szkła" z `RadiusLg`, nagłówek + treść + `onClickOutside`), tylko
  ## zakotwiczony do PRAWEJ krawędzi doku zamiast lewej.
  const
    w = 300.0'f32
    headerH = 60.0'f32
    rowGap = 4.0'f32
    ## Rozbudowa v0.1 ("Aurora" -- przewijanie): panel nie rośnie już bez
    ## ograniczeń w dół przy długiej historii -- powyżej tej wysokości
    ## treść się PRZEWIJA (kółkiem myszy, patrz `onHover` niżej), zamiast
    ## wypychać kartę poza ekran.
    MaxBodyH = 420.0'f32

  let items = historySnapshot()
  var bodyH = 8.0'f32
  for e in items:
    let bodyLines = if e.body.len > 46: 2 else: 1
    ## Musi dokładnie odzwierciedlać to, co rysuje `drawHistoryRow` +
    ## odstęp `rowGap` dodawany między wierszami w pętli niżej -- inaczej
    ## obliczony zakres przewijania (`maxScroll` niżej) się rozjeżdża.
    bodyH += 40.0'f32 + float32(bodyLines) * 14.0'f32 + rowGap
  if items.len == 0:
    bodyH = 60.0'f32

  let visibleBodyH = min(bodyH, MaxBodyH)
  let maxScroll = max(0.0'f32, bodyH - visibleBodyH)
  notifScrollY = clamp(notifScrollY, 0.0'f32, maxScroll)

  let h = headerH + visibleBodyH
  let x = windowSize.x - DockMargin - w
  let y = windowSize.y - TaskbarHeight - h - DockMargin

  frame "notif-center":
    box x, y, w, h
    fill Glass, 0.97
    stroke GlassBorder
    strokeWeight 1
    cornerRadius RadiusLg

    onClickOutside:
      compositor.notifCenterOpen = false

    group "notif-header":
      box 0, 0, w, headerH
      text "notif-title":
        box 14, 10, w - 28, 18
        font "sans-serif", 13, 700, 18, hLeft, vCenter
        fill TextPrimary
        characters "Powiadomienia"

      ## Przełącznik "Nie przeszkadzać" -- prosty prostokątny toggle
      ## (kropka po lewej/prawej stronie kapsułki), ten sam motyw co
      ## kropka włącz/wyłącz alarmu w `apps/clock/clockapp.nim`.
      group "dnd-toggle":
        box w - 84, 32, 70, 20
        cornerRadius 10
        fill (if isDndEnabled(): AccentColor else: "#2a2f36")
        onClick:
          setDnd(not isDndEnabled())
        text "dnd-label":
          box 6, 0, 40, 20
          font "sans-serif", 9, 700, 20, hLeft, vCenter
          fill (if isDndEnabled(): "#0f1115" else: TextMuted)
          characters "DND"
        rectangle "dnd-knob":
          box (if isDndEnabled(): 70 - 18 else: 2), 2, 16, 16
          fill (if isDndEnabled(): "#0f1115" else: TextFaint)
          cornerRadius 8

      if items.len > 0:
        group "notif-clear":
          box 14, 34, 60, 16
          fill "#000000", 0.0
          onClick:
            clearHistory()
          text "notif-clear-label":
            box 0, 0, 60, 16
            font "sans-serif", 10, 600, 16, hLeft, vCenter
            fill TextFaint
            characters "Wyczyść"

    rectangle "notif-header-divider":
      box 8, headerH, w - 16, 1
      fill "#ffffff", 0.06

    if items.len == 0:
      text "notif-empty":
        box 14, headerH + 8, w - 28, 40
        font "sans-serif", 12, 400, 18, hLeft, vTop
        fill TextFaint
        characters "Brak powiadomień."
    else:
      group "notif-body":
        ## `clipContent true` + ręczne przewijanie -- Fidget nie ma
        ## wbudowanego automatycznego scrolla dla zwykłych grup, ten sam
        ## sprawdzony wzorzec co lista plików w
        ## `apps/filemanager/files.nim` (`onHover` + `mouse.wheelDelta`).
        box 0, headerH, w, visibleBodyH
        clipContent true
        onHover:
          if mouse.wheelDelta != 0:
            notifScrollY = clamp(notifScrollY - mouse.wheelDelta * 40.0'f32, 0.0'f32, maxScroll)

        var iy = 4.0'f32 - notifScrollY
        for idx, e in items:
          let rowH = drawHistoryRow(e, idx, iy, w)
          iy += rowH + rowGap

proc drawClipboardRow(e: ClipboardEntry, idx: int, iy, w: float32): float32 =
  ## Rozbudowa (historia schowka): jeden wiersz listy. Tekst bywa
  ## wielolinijkowy w oryginale (np. skopiowany fragment kodu) -- tu
  ## zawsze pokazujemy go jako JEDNĄ linię z `\n`/`\r` zamienionymi na
  ## spację, żeby lista pozostała przewidywalnej wysokości (pełna,
  ## wieloliniowa treść i tak trafia do schowka systemowego po kliknięciu
  ## w wiersz -- to podgląd, nie edytor).
  const h = 40.0'f32
  let preview = e.text.replace("\r", " ").replace("\n", " ")
  ## Obcinanie po BAJTACH, nie runach Unicode -- ten sam kompromis co
  ## indeksowanie stringów gdzie indziej w tym pliku (`drawHistoryRow` i
  ## okolice). Dla czystego ASCII (najczęstszy przypadek -- URL-e, kod,
  ## polecenia) daje to poprawny wynik; dla tekstu z wielobajtowymi
  ## znakami UTF-8 (polskie znaki, emoji) na samej granicy obcięcia
  ## MOŻE w rzadkich przypadkach obciąć w środku znaku -- kosmetyczna
  ## usterka podglądu, nie utrata danych: pełna, nietknięta treść trafia
  ## do schowka systemowego po kliknięciu (patrz `onClick` niżej), nie
  ## ten skrócony podgląd.
  let shown = if preview.len > 60: preview[0 ..< 57] & "..." else: preview

  group "clip-row-" & $idx:
    box 8, iy, w - 16, h - 4
    cornerRadius RadiusSm
    fill "#171b22"
    onHover: fill "#20262f"
    onClick:
      ## Klik na wiersz kopiuje jego treść z powrotem do schowka
      ## systemowego i zamyka panel -- ten sam gest co kliknięcie pozycji
      ## launchera (patrz `drawLauncherRow`), żeby zachowanie "klik = od
      ## razu użyj tego" było spójne w całym shellu.
      discard copyToClipboard(e.text)
      compositor.clipboardHistoryOpen = false

    text "clip-text-" & $idx:
      box 12, 5, w - 16 - 12 - 78, 20
      font "monospace", 11, 400, 20, hLeft, vCenter
      fill TextPrimary
      characters shown

    text "clip-ago-" & $idx:
      box w - 16 - 78, 5, 74, h - 4 - 10
      font "sans-serif", 9, 400, h - 4 - 10, hRight, vTop
      fill TextFaint
      characters formatAgo(e.at)

  h

var clipScrollY: float32 = 0.0  ## przewinięcie panelu historii schowka, patrz `drawClipboardHistory`

proc drawClipboardHistory*() =
  ## Panel historii schowka -- otwierany ikoną 📋 w doku (`drawTaskbar`).
  ## Ten sam wizualny język i mechanizm przewijania co
  ## `drawNotificationCenter` -- patrz komentarze tam po pełne
  ## uzasadnienie `clipContent true` + ręczny scroll kółkiem myszy.
  const
    w = 320.0'f32
    headerH = 60.0'f32
    rowGap = 4.0'f32
    rowH = 40.0'f32
    MaxBodyH = 420.0'f32

  let items = clipboardHistorySnapshot()
  var bodyH = 8.0'f32 + float32(items.len) * (rowH + rowGap)
  if items.len == 0:
    bodyH = 60.0'f32

  let visibleBodyH = min(bodyH, MaxBodyH)
  let maxScroll = max(0.0'f32, bodyH - visibleBodyH)
  clipScrollY = clamp(clipScrollY, 0.0'f32, maxScroll)

  let h = headerH + visibleBodyH
  let x = windowSize.x - DockMargin - w
  let y = windowSize.y - TaskbarHeight - h - DockMargin

  frame "clipboard-history":
    box x, y, w, h
    fill Glass, 0.97
    stroke GlassBorder
    strokeWeight 1
    cornerRadius RadiusLg

    onClickOutside:
      compositor.clipboardHistoryOpen = false

    group "clip-header":
      box 0, 0, w, headerH
      text "clip-title":
        box 14, 10, w - 28, 18
        font "sans-serif", 13, 700, 18, hLeft, vCenter
        fill TextPrimary
        characters "Schowek"

      text "clip-subtitle":
        box 14, 32, w - 28, 16
        font "sans-serif", 10, 400, 16, hLeft, vCenter
        fill TextFaint
        characters "Kliknij pozycję, żeby ją znów skopiować"

      if items.len > 0:
        group "clip-clear":
          box w - 74, 34, 60, 16
          fill "#000000", 0.0
          onClick:
            clearClipboardHistory()
          text "clip-clear-label":
            box 0, 0, 60, 16
            font "sans-serif", 10, 600, 16, hRight, vCenter
            fill TextFaint
            characters "Wyczyść"

    rectangle "clip-header-divider":
      box 8, headerH, w - 16, 1
      fill "#ffffff", 0.06

    if items.len == 0:
      text "clip-empty":
        box 14, headerH + 8, w - 28, 40
        font "sans-serif", 12, 400, 18, hLeft, vTop
        fill TextFaint
        characters "Historia schowka jest pusta."
    else:
      group "clip-body":
        box 0, headerH, w, visibleBodyH
        clipContent true
        onHover:
          if mouse.wheelDelta != 0:
            clipScrollY = clamp(clipScrollY - mouse.wheelDelta * 40.0'f32, 0.0'f32, maxScroll)

        var iy = 4.0'f32 - clipScrollY
        for idx, e in items:
          let rh = drawClipboardRow(e, idx, iy, w)
          iy += rh + rowGap

## Rozbudowa: stan przeciągania suwaka (głośność/jasność) MIĘDZY klatkami --
## bez tego `drawSlider` obsługiwał tylko "kliknij, żeby ustawić" (patrz
## `onMouseDown` niżej), bo ten blok Fidget-owego DSL-a uruchamia się
## wyłącznie na przejściu "przycisk wciśnięty", nie co klatkę, dopóki jest
## trzymany. Żeby dostać PRAWDZIWE przeciąganie (jak w `comp/drag.nim` dla
## przenoszenia/zmiany rozmiaru okien), potrzeba dokładnie tego samego
## wzorca: zapamiętać stan przy wciśnięciu, potem co klatkę (w
## `updateSliderDrag`, wołanym z `shell.nim` obok analogicznego
## `compositor.updateDrag`) aktualizować wartość, dopóki przycisk myszy
## jest trzymany -- NIEZALEŻNIE od tego, czy kursor akurat mieści się w
## granicach paska (użytkownik naturalnie "wyjeżdża" myszą poza wąski
## 24px pasek przy szybkim przeciąganiu, dokładnie tak samo jak przy
## przenoszeniu okna za tytuł).
type SliderDragState = object
  active: bool
  trackX: float32     ## bezwzględna (ekranowa) współrzędna X lewej krawędzi paska
  trackW: float32      ## szerokość paska w pikselach (odpowiednik "100%")
  setValue: proc(v: int) {.closure.}

var sliderDrag: SliderDragState

proc updateSliderDrag*() =
  ## Wołane raz na klatkę z `drawMain()` w `shell/shell.nim`, obok
  ## analogicznego `compositor.updateDrag` dla okien -- patrz duży
  ## komentarz przy `SliderDragState` powyżej. Zamyka się sam (`active =
  ## false`), gdy przycisk myszy zostanie puszczony ALBO panel quick
  ## settings zostanie zamknięty w międzyczasie (np. kliknięciem poza
  ## panelem) -- bez tego drugiego warunku przeciąganie mogłoby "po cichu"
  ## dalej zmieniać głośność/jasność mimo zamkniętego panelu, gdyby
  ## przycisk myszy z jakiegoś powodu został trzymany dalej.
  if not sliderDrag.active: return
  if not mouse.down or not compositor.quickSettingsOpen:
    sliderDrag.active = false
    return
  let localX = mouse.pos.x - sliderDrag.trackX
  sliderDrag.setValue(clamp(int(localX / sliderDrag.trackW * 100.0'f32), 0, 100))

proc drawSlider(idPrefix: string, x, y, w: float32, value: int, icon, label: string,
                 setValue: proc(v: int) {.closure.}) =
  ## Rozbudowa v0.1 ("Aurora" -- quick settings): prosty suwak poziomy --
  ## Fidget nie ma wbudowanego widgetu suwaka. Trzy sposoby sterowania:
  ## klik gdziekolwiek na pasku ustawia wartość na tę pozycję,
  ## PRZECIĄGNIĘCIE (patrz `SliderDragState`/`updateSliderDrag` wyżej)
  ## płynnie dostraja wartość w trakcie ruchu myszy z wciśniętym
  ## przyciskiem, a kółko myszy nad paskiem dostraja o 5 punktów
  ## procentowych -- ten sam `mouse.wheelDelta`, co listy z przewijaniem
  ## gdzie indziej w tym pliku.
  const trackH = 8.0'f32
  const knobR = 8.0'f32
  const rowH = 44.0'f32

  group idPrefix & "-row":
    box x, y, w, rowH
    text idPrefix & "-icon":
      box 0, 0, 24, rowH
      font "sans-serif", 14, 400, rowH, hLeft, vCenter
      fill TextPrimary
      characters icon
    text idPrefix & "-value":
      box w - 40, 0, 40, 18
      font "sans-serif", 11, 600, 18, hRight, vTop
      fill TextMuted
      characters $value & "%"

    group idPrefix & "-track-area":
      ## Cały wiersz (nie tylko cienki pasek) reaguje na scroll/klik --
      ## łatwiej trafić myszą niż w idealnie 8px wysoki pasek.
      box 24, 16, w - 24, 24
      fill "#000000", 0.0
      onHover:
        if mouse.wheelDelta != 0:
          setValue(clamp(value + int(mouse.wheelDelta * 5.0'f32), 0, 100))
      onMouseDown:
        let localX = mouse.pos.x - (current.screenBox.x)
        setValue(clamp(int(localX / (w - 24) * 100.0'f32), 0, 100))
        ## Uzbrajamy globalny stan przeciągania (patrz `SliderDragState`
        ## wyżej) -- od tej klatki `updateSliderDrag()` w `shell.nim`
        ## przejmuje aktualizację wartości, dopóki przycisk myszy jest
        ## trzymany, nawet gdy kursor zjedzie poza ten wąski pasek.
        sliderDrag = SliderDragState(active: true, trackX: current.screenBox.x,
          trackW: w - 24, setValue: setValue)

      rectangle idPrefix & "-track-bg":
        box 0, 8, w - 24, trackH
        fill "#20262f"
        cornerRadius trackH / 2
      rectangle idPrefix & "-track-fill":
        box 0, 8, max(trackH, (w - 24) * (value.float32 / 100.0'f32)), trackH
        fill AccentColor
        cornerRadius trackH / 2
      rectangle idPrefix & "-knob":
        box (w - 24) * (value.float32 / 100.0'f32) - knobR, 8 + trackH / 2 - knobR, knobR * 2, knobR * 2
        fill "#ffffff"
        cornerRadius knobR

proc drawQuickSettings*() =
  ## Panel głośności/jasności -- otwierany ikoną 🔊 w doku. Sekcje
  ## pokazują się TYLKO gdy odpowiadający im backend faktycznie jest
  ## dostępny (`hasVolumeControl`/`hasBrightnessControl`, patrz
  ## `shell/quicksettings.nim`) -- nie ma sensu rysować suwaka, który
  ## nic by nie zmieniał.
  const w = 260.0'f32
  const headerH = 34.0'f32
  const rowH = 44.0'f32
  const pad = 14.0'f32

  let showVolume = hasVolumeControl()
  let showBrightness = hasBrightnessControl()
  var bodyH = 0.0'f32
  if showVolume: bodyH += rowH
  if showBrightness: bodyH += rowH
  if not showVolume and not showBrightness: bodyH = 40.0'f32

  let h = headerH + bodyH + 8.0'f32
  let x = windowSize.x - DockMargin - w
  let y = windowSize.y - TaskbarHeight - h - DockMargin

  frame "quicksettings":
    box x, y, w, h
    fill Glass, 0.97
    stroke GlassBorder
    strokeWeight 1
    cornerRadius RadiusLg

    onClickOutside:
      compositor.quickSettingsOpen = false

    text "qs-title":
      box pad, 8, w - pad * 2, 18
      font "sans-serif", 13, 700, 18, hLeft, vCenter
      fill TextPrimary
      characters "Głośność i jasność"

    rectangle "qs-header-divider":
      box 8, headerH, w - 16, 1
      fill "#ffffff", 0.06

    if not showVolume and not showBrightness:
      text "qs-empty":
        box pad, headerH + 8, w - pad * 2, 24
        font "sans-serif", 11, 400, 18, hLeft, vTop
        fill TextFaint
        characters "Brak sterowania audio/jasnością na tym systemie."
    else:
      var iy = headerH + 6.0'f32
      if showVolume:
        let (vol, muted) = getVolume()
        drawSlider("qs-volume", pad, iy, w - pad * 2,
          (if muted: 0 else: vol), (if muted: "🔇" else: "🔊"), "Głośność",
          proc(v: int) = setVolume(v))
        iy += rowH
      if showBrightness:
        drawSlider("qs-brightness", pad, iy, w - pad * 2,
          getBrightness(), "☀", "Jasność",
          proc(v: int) = setBrightness(v))
        iy += rowH
