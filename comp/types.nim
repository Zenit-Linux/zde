import vmath

type
  WindowKind* = enum
    wkTerminal
    wkFileManager
    wkAbout
    wkSettings
    wkGeneric

  ## Rozbudowa v0.1 ("Aurora"): do jakiej krawędzi ekranu okno jest
  ## aktualnie przyciągnięte skrótem Super+Left/Right (`comp/window.nim`,
  ## `snapWindow`) -- `seNone`, gdy okno nie jest przyciągnięte (w tym
  ## zwykłe `maximized` przez `toggleMaximize`, które tego pola nie
  ## ustawia). Osobne od `maximized: bool` (poniżej) -- `maximized` mówi
  ## TYLKO "czy geometria jest inna niż `savedPos`/`savedSize`", `snapEdge`
  ## dodatkowo mówi DO CZEGO, żeby drugie Super+Left mogło rozpoznać "już
  ## tu jesteś" i przywrócić oryginalny rozmiar zamiast bezczynnie
  ## przyciągać ponownie.
  SnapEdge* = enum
    seNone, seLeft, seRight

  ResizeEdge* = enum
    reNone
    reLeft, reRight, reTop, reBottom
    reTopLeft, reTopRight, reBottomLeft, reBottomRight

  DrawBodyProc* = proc(win: ZdeWindow) {.closure.}

  ZdeWindow* = ref object
    id*: int
    title*: string
    kind*: WindowKind
    pos*: Vec2
    size*: Vec2
    minSize*: Vec2
    savedPos*: Vec2       ## pozycja sprzed maximize, do przywrócenia
    savedSize*: Vec2      ## rozmiar sprzed maximize
    zIndex*: int
    minimized*: bool
    maximized*: bool
    snapEdge*: SnapEdge
    closable*: bool
    resizable*: bool
    drawBody*: DrawBodyProc
    onClose*: proc(win: ZdeWindow) {.closure.}
    userData*: RootRef     ## uchwyt na stan konkretnej appki (TerminalState, FilesState, ...)
    ## Rozbudowa v0.1 ("Aurora" -- pulpity wirtualne): na którym z
    ## `WorkspaceCount` pulpitów żyje to okno. 0-indeksowane (pulpit "1"
    ## w UI to `workspace == 0`) -- patrz `comp/window.nim` i
    ## `shell/taskbar.nim` (przełącznik pulpitów w doku).
    workspace*: int
    ## Rozbudowa (skróty klawiszowe per-aplikacja, np. Ctrl+F w edytorze
    ## tekstu): czy TO okno jest właśnie aktywne. Ustawiane raz na klatkę
    ## przez `drawWindowChrome` (`shell/chrome.nim`, które i tak liczy
    ## `win.id == compositor.focusedId` na własny użytek -- podświetlenie
    ## ramki) TUŻ PRZED wywołaniem `win.drawBody(win)`. Istnieje jako pole
    ## na `ZdeWindow`, a nie jako coś odczytywanego przez `compositor`
    ## bezpośrednio z poziomu aplikacji, bo część aplikacji (np.
    ## `apps/texteditor/texteditor.nim`) jest importowana PRZEZ
    ## `shell/state.nim` -- gdyby chciały same zaimportować `state.nim`
    ## po `compositor`, powstałby cykl importów. Odczyt pola na już i tak
    ## przekazywanym argumencie `win` omija ten problem całkowicie, bez
    ## dokładania nowych zależności.
    focused*: bool
  DragKind* = enum
    dkNone, dkMove, dkResize

  DragState* = object
    kind*: DragKind
    windowId*: int
    edge*: ResizeEdge
    grabOffset*: Vec2       ## offset kursora względem lewego-górnego rogu okna
    startPos*: Vec2
    startSize*: Vec2

  Compositor* = ref object
    windows*: seq[ZdeWindow]
    nextId*: int
    focusedId*: int
    screenSize*: Vec2
    drag*: DragState
    launcherOpen*: bool
    ## Rozbudowa v0.1 ("Aurora" -- centrum powiadomień): czy panel historii
    ## powiadomień (`shell/taskbar.nim`, `drawNotificationCenter`) jest
    ## akurat otwarty. Trzymane tutaj, nie w `shell/notifications.nim`, z
    ## tego samego powodu co `launcherOpen` -- ten typ już jest tym
    ## "trwałym między klatkami" miejscem na stan UI shellu, a
    ## `notifications.nim` celowo nie zależy od `comp`/`state` (patrz duży
    ## komentarz na górze tamtego pliku, o cyklu importów).
    notifCenterOpen*: bool
    ## Rozbudowa v0.1 ("Aurora" -- quick settings): panel głośności/
    ## jasności (dzwonek ma swój, ten ma swój -- oba wykluczają się
    ## wzajemnie i z launcherem, ten sam wzorzec co `notifCenterOpen`).
    quickSettingsOpen*: bool
    ## Rozbudowa (historia schowka, `shell/clipboard.nim` +
    ## `drawClipboardHistory` w `shell/taskbar.nim`): panel z listą
    ## ostatnio skopiowanych fragmentów tekstu -- ten sam wzorzec
    ## wzajemnego wykluczania co `notifCenterOpen`/`quickSettingsOpen`
    ## powyżej (wszystkie cztery panele -- launcher, powiadomienia, quick
    ## settings, schowek -- są rysowane jako nakładki na cały ekran, więc
    ## dwa naraz otwarte nakładałyby się wizualnie i myliły hit-testing).
    clipboardHistoryOpen*: bool
    ## Rozbudowa v0.1 ("Aurora"): tekst wpisany w polu wyszukiwania
    ## launchera (patrz `shell/launcher_apps.nim` / `shell/taskbar.nim`) --
    ## trzymany tutaj, nie lokalnie w `drawLauncher()`, z tego samego
    ## powodu co `t.path`/`t.content` w `apps/texteditor/texteditor.nim`:
    ## Fidget odtwarza całe drzewo UI co klatkę, więc jedyny stan, który
    ## przeżywa między klatkami, to ten trzymany w zwykłych polach obiektu,
    ## nie w lokalnych zmiennych funkcji rysującej.
    launcherSearch*: string
    ## Rozbudowa v0.1 ("Aurora" -- pulpity wirtualne): aktualnie aktywny
    ## pulpit (0-indeksowany, patrz `workspace` w `ZdeWindow`). Nowe okna
    ## (`openWindow` w `comp/window.nim`) lądują na TYM pulpicie.
    currentWorkspace*: int

const
  DefaultMinSize* = vec2(280, 180)
  ## Rozbudowa v0.1 ("Aurora"): podniesione z 40 na 56 -- nowy, "pływający"
  ## dok (patrz `shell/taskbar.nim`) chce mieć margines od góry i dołu
  ## zarezerwowanego pasa, a przy starych 40px zostawałoby na samą treść
  ## doku ledwie kilkanaście pikseli (za mało na czytelną ikonę+tekst).
  ## Wszystko, co liczy dostępną wysokość pulpitu na podstawie tej stałej
  ## (maksymalizacja okna, ograniczenie pozycji okna niżej w tym pliku),
  ## automatycznie dostaje więc też te dodatkowe piksele -- nic tu nie
  ## trzeba było zmieniać osobno.
  TaskbarHeight* = 56.0'f32
  SnapMargin* = 12.0'f32
