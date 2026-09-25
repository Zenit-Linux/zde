import std/[times, sequtils, os, json, strutils]
import fidget
import sound
import dbusnotify

## Uwaga o zależnościach: ten moduł CELOWO nie importuje `state.nim` (mimo
## że mógłby stamtąd wziąć np. `PanelBg`/`AccentColor` do spójnego
## motywu) -- `state.nim` importuje aplikacje (zegar, terminal, monitor
## systemu) do swoich rejestrów (`clocks`, `terminals`, `sysmonitors`), a
## `apps/clock/clockapp.nim` importuje TEN moduł, żeby wywoływać `notify`
## z alarmów. Gdyby `notifications.nim` importował `state.nim`, powstałby
## cykl: state -> clockapp -> notifications -> state, którego Nim nie
## potrafi rozwiązać. Stąd kolory toastów są zaszyte lokalnie tutaj, a nie
## dzielone ze stałymi z `state.nim`.

## NOWA FUNKCJA (rozbudowa v0.1): natywny system powiadomień ZDE.
##
## Do tej pory żadna aplikacja shellu nie miała sposobu na poinformowanie
## użytkownika o czymś, co dzieje się w tle, w oknie, które akurat nie jest
## aktywne (albo w ogóle nie jest otwarte) -- np. zegar z alarmem, monitor
## systemu przy krytycznym obciążeniu, menedżer plików po zakończeniu
## operacji -- TA OSTATNIA ścieżka jest od kolejnej rozbudowy realna, nie
## tylko ilustracyjna: `apps/filemanager/files.nim` woła `notify(...)`
## po utworzeniu folderu/zmianie nazwy/usunięciu (i przy błędach tych
## operacji). Ten moduł daje jedno wspólne API (`notify`) i warstwę
## rysującą (`drawNotifications`) dokładaną do głównej pętli `shell.nim`.
##
## Zamierzenie było celowo proste (v0.1): nie było dźwięku, nie było
## integracji z zewnętrznym DBusowym `org.freedesktop.Notifications` --
## to drugie by wymagało osobnego demona i bindingów do DBus, wciąż poza
## zakresem tego projektu. Historia od pewnej rozbudowy PRZEŻYWA restart
## shellu -- patrz `historyFilePath`/`loadHistoryFromDisk`/
## `saveHistoryToDisk` niżej: zwykły plik JSON w katalogu stanu XDG, bez
## demona, bez trwałego procesu w tle. Dźwięk od kolejnej rozbudowy TEŻ
## istnieje -- `nkInfo`/`nkWarning` grają teraz krótki, subtelny dźwięk
## przez `shell/sound.nim` (`playNotifySound`/`playWarningSound`),
## niezależny od dźwięku alarmu zegara (`playAlarmSound`, głośniejszy i
## wybieralny przez użytkownika -- patrz `notify` niżej po uzasadnienie,
## dlaczego `nkAlarm` świadomie NIE gra tu drugiego dźwięku). W zamian:
## każda aplikacja ZDE (i sam shell) może wywołać `notify(...)` z
## dowolnego miejsca; toast sam się narysuje w prawym górnym rogu i
## zniknie po chwili (albo zostanie ręcznie zamknięty kliknięciem "×"), a
## krótka historia zostaje dostępna w panelu "centrum powiadomień" (dzwonek
## w doku, patrz `drawNotificationCenter` w `shell/taskbar.nim`) razem z
## przełącznikiem "Nie przeszkadzać".

type
  NotifyKind* = enum
    nkInfo    ## neutralna informacja (np. "zapisano plik")
    nkWarning ## coś wymaga uwagi, ale nie jest krytyczne
    nkAlarm   ## alarm/timer -- wisi dłużej i jest wizualnie odróżniony

  Notification = ref object
    id: int
    title: string
    body: string
    kind: NotifyKind
    createdAt: float

  ## Rozbudowa v0.1 ("Aurora" -- centrum powiadomień): w odróżnieniu od
  ## `Notification` powyżej (żyje tylko dopóki toast jest widoczny na
  ## ekranie, potem znika bezpowrotnie), `HistoryEntry` zostaje w
  ## `history` PO zniknięciu toastu -- żeby dało się sprawdzić "co mi
  ## umknęło", gdy nie było się akurat przy ekranie. To wciąż nie jest
  ## trwały dziennik w pełnym tego słowa znaczeniu (bez integracji z
  ## zewnętrznymi aplikacjami spoza ZDE, bez rotacji/kompresji) -- ale od
  ## tej rundy PRZEŻYWA restart `zde-shell` (patrz `saveHistoryToDisk`/
  ## `loadHistoryFromDisk` niżej) -- tylko dłuższa pamięć niż sam toast.
  HistoryEntry* = object
    title*: string
    body*: string
    kind*: NotifyKind
    at*: float

const
  ## Rozbudowa: katalog + plik trwałej historii powiadomień, zgodnie z
  ## XDG Base Directory Specification -- `$XDG_STATE_HOME` (albo
  ## `~/.local/state`, gdy zmienna nieustawiona) to własnie kategoria
  ## "stanu aplikacji, który powinien przetrwać restart, ale nie jest
  ## configiem ani cache'em" -- dokładnie nasz przypadek. Ten sam wzorzec
  ## mógłby kiedyś posłużyć innym częściom ZDE (np. zapamiętanym pozycjom
  ## okien), stąd nazwa katalogu "zde", nie "zde-shell".
  StateSubdir = "zde"
  HistoryFileName = "notifications.json"
  ToastW = 300.0'f32
  ToastPad = 10.0'f32
  ToastGap = 8.0'f32
  ToastMarginTop = 12.0'f32
  ToastMarginRight = 12.0'f32
  ## Czas życia zwykłego powiadomienia. Alarmy wiszą znacznie dłużej --
  ## sens alarmu to obudzić/przypomnieć, 6 sekund by nikt nie zdążył
  ## zareagować, gdyby akurat nie patrzył na ekran.
  InfoLifetimeSec = 6.0
  AlarmLifetimeSec = 45.0
  ## Ile wpisów historii pamiętamy -- wystarczy na "co przegapiłem",
  ## bez ryzyka, że lista urośnie bez końca w długo działającym `zde-shell`.
  MaxHistory = 30

var
  notifications: seq[Notification] = @[]
  nextNotifyId = 1
  history: seq[HistoryEntry] = @[]
  ## "Nie przeszkadzać" -- gdy włączone, `notify()` dalej ZAPISUJE do
  ## historii (patrz niżej), ale nie pokazuje wyskakującego toastu.
  ## Alarmy (`nkAlarm`) świadomie OMIJAJĄ to wyciszenie -- tak jak w
  ## telefonach, sens alarmu to obudzić/przypomnieć nawet w trybie
  ## "nie przeszkadzać", inaczej funkcja przestałaby robić to, do czego
  ## służy.
  dndEnabled = false

proc isDndEnabled*(): bool = dndEnabled
proc setDnd*(enabled: bool) = dndEnabled = enabled

proc historyFilePath(): string =
  ## `os.getConfigDir()` w Nim zwraca `$XDG_CONFIG_HOME`, nie
  ## `$XDG_STATE_HOME` -- stdlib nie ma gotowca dla katalogu stanu, więc
  ## odtwarzamy tę samą logikę fallbacku ręcznie (zmienna środowiskowa,
  ## a w jej braku `~/.local/state`), zamiast (błędnie) trzymać historię
  ## powiadomień razem z konfiguracją.
  let base =
    if existsEnv("XDG_STATE_HOME"): getEnv("XDG_STATE_HOME")
    else: getHomeDir() / ".local" / "state"
  base / StateSubdir / HistoryFileName

proc saveHistoryToDisk() =
  ## Best-effort, jak reszta integracji ZDE z otoczeniem systemowym
  ## (`quicksettings.nim`/`sound.nim`) -- brak uprawnień do zapisu, pełny
  ## dysk, albo cokolwiek innego nie powinno nigdy wywrócić `zde-shell`,
  ## tylko po cichu zostawić historię nietrwałą w tej jednej sesji.
  try:
    let path = historyFilePath()
    createDir(path.parentDir())
    var arr = newJArray()
    # Zapisujemy w kolejności "najstarszy pierwszy", żeby `loadHistoryFromDisk`
    # mogło po prostu `add` bez odwracania -- `history` w pamięci trzyma
    # najnowszy na indeksie 0 (patrz `notify`), więc iterujemy od końca.
    for i in countdown(history.len - 1, 0):
      let e = history[i]
      arr.add(%*{"title": e.title, "body": e.body, "kind": $e.kind, "at": e.at})
    writeFile(path, $arr)
  except CatchableError:
    discard

proc loadHistoryFromDisk(): seq[HistoryEntry] =
  ## Wołane RAZ przy starcie modułu (patrz `history = loadHistoryFromDisk()`
  ## niżej) -- brak pliku (pierwsze uruchomienie ZDE na tej maszynie) albo
  ## uszkodzona/niekompatybilna zawartość (np. z przyszłej wersji formatu)
  ## po prostu daje pustą historię zamiast wywalać start shellu.
  try:
    let path = historyFilePath()
    if not fileExists(path): return @[]
    let arr = parseJson(readFile(path))
    if arr.kind != JArray: return @[]
    for item in arr:
      try:
        result.insert(HistoryEntry(
          title: item["title"].getStr(),
          body: item["body"].getStr(),
          kind: parseEnum[NotifyKind](item["kind"].getStr(), nkInfo),
          at: item["at"].getFloat(),
        ), 0)
      except CatchableError:
        discard  ## pojedynczy uszkodzony wpis -- pomijamy go, nie całą historię
    if result.len > MaxHistory:
      result.setLen(MaxHistory)
  except CatchableError:
    result = @[]

## Wczytanie trwałej historii wykonuje się RAZ, w momencie ładowania tego
## modułu (a więc przy starcie `zde-shell`, zanim jakiekolwiek okno zdąży
## coś narysować) -- musi nastąpić PO definicji `loadHistoryFromDisk`
## powyżej (Nim wymaga, żeby proc był już zadeklarowany w miejscu
## wywołania na poziomie modułu), stąd nie może to być po prostu wartość
## początkowa w bloku `var` na górze pliku.
history = loadHistoryFromDisk()

proc notify*(title, body: string, kind: NotifyKind = nkInfo) =
  ## Dodaje nowe powiadomienie do kolejki (i zawsze do historii -- patrz
  ## `historySnapshot`). Bezpieczne do wołania z dowolnej aplikacji ZDE
  ## (patrz `apps/clock/clockapp.nim` dla przykładu użycia z alarmami,
  ## `apps/filemanager/files.nim` dla przykładu z operacjami na plikach).
  history.insert(HistoryEntry(title: title, body: body, kind: kind, at: epochTime()), 0)
  if history.len > MaxHistory:
    history.setLen(MaxHistory)
  saveHistoryToDisk()

  if dndEnabled and kind != nkAlarm:
    return

  notifications.add(Notification(
    id: nextNotifyId, title: title, body: body, kind: kind, createdAt: epochTime(),
  ))
  inc nextNotifyId

  ## Rozbudowa: dźwięk zwykłych toastów, nie tylko alarmu -- jawnie
  ## wymienione wcześniej w README jako brakujące. Świadomie POMIJA
  ## `nkAlarm` -- alarm/minutnik (`apps/clock/clockapp.nim`) już wołają
  ## `playAlarmSound` z WŁASNYM, wybranym przez użytkownika dźwiękiem w
  ## miejscu, gdzie faktycznie odpalają; granie tu drugiego, generycznego
  ## dźwięku NA TO SAMO zdarzenie dawałoby dwa nakładające się dźwięki.
  ## Umieszczone PO sprawdzeniu `dndEnabled` wyżej -- gdy tryb "nie
  ## przeszkadzać" wycisza toast, wycisza też jego dźwięk (ten sam gest,
  ## nie tylko ten sam ekran).
  case kind
  of nkInfo: playNotifySound()
  of nkWarning: playWarningSound()
  of nkAlarm: discard

proc historySnapshot*(): seq[HistoryEntry] =
  ## Kopia (seq w Nimie ma semantykę wartości) -- bezpieczna do iterowania
  ## przez `shell/taskbar.nim` bez ryzyka, że `notify()` zmieni listę
  ## kompozytorowi spod nóg w trakcie rysowania.
  history

proc clearHistory*() =
  history.setLen(0)
  saveHistoryToDisk()

proc formatAgo*(at: float): string =
  ## Krótki, czytelny opis "jak dawno temu" -- używany w panelu historii
  ## (`shell/taskbar.nim`). Celowo z grubym podziałem (sekundy/minuty/
  ## godziny) zamiast dokładnego zegara -- to ma dać orientację, nie
  ## precyzję co do sekundy.
  let deltaSec = epochTime() - at
  if deltaSec < 60: "przed chwilą"
  elif deltaSec < 3600: $int(deltaSec / 60) & " min temu"
  elif deltaSec < 86400: $int(deltaSec / 3600) & " godz. temu"
  else: $int(deltaSec / 86400) & " dni temu"

proc dismissNotification(id: int) =
  notifications.keepItIf(it.id != id)

proc lifetimeFor(kind: NotifyKind): float =
  if kind == nkAlarm: AlarmLifetimeSec else: InfoLifetimeSec

proc tickNotifications*() =
  ## Usuwa wygasłe powiadomienia. Wołane raz na sekundę z `shell.nim`
  ## (ta sama kadencja co zegar/monitor systemu -- powiadomienia nie
  ## potrzebują dokładności co do klatki).
  let now = epochTime()
  notifications.keepItIf(now - it.createdAt < lifetimeFor(it.kind))

proc tickDbusNotifications*() =
  ## **Runda 34/35** -- odpytuje serwer DBus `org.freedesktop.
  ## Notifications` (patrz `shell/dbusnotify.nim`/`dbus_notify_shim.c`
  ## po pełny opis) i każde odebrane powiadomienie od zewnętrznej
  ## aplikacji przepuszcza przez ten sam `notify()`, którego używają
  ## aplikacje ZDE -- efekt: powiadomienie z zewnątrz wygląda i brzmi
  ## DOKŁADNIE tak samo jak powiadomienie wewnętrzne (`nkInfo`), trafia
  ## do tej samej historii/centrum powiadomień. Drenuje CAŁĄ kolejkę w
  ## jednym wywołaniu (pętla `while`), nie tylko jedno powiadomienie na
  ## sekundę -- inaczej seria kilku powiadomień z rzędu (typowe np. przy
  ## aktualizacji systemu) czekałaby w kolejce po jednym na sekundę,
  ## myląco wolno jak na coś, co w rzeczywistości przyszło naraz.
  while true:
    let r = pollDbusNotification()
    if not r.got: break
    let title = if r.app.len > 0: r.app & ": " & r.summary else: r.summary
    notify(title, r.body, nkInfo)

proc accentFor*(kind: NotifyKind): string =
  case kind
  of nkInfo: "#5fb0ff"
  of nkWarning: "#e0a850"
  of nkAlarm: "#e5666b"

proc iconFor*(kind: NotifyKind): string =
  case kind
  of nkInfo: "ℹ"
  of nkWarning: "⚠"
  of nkAlarm: "⏰"

proc drawNotifications*() =
  ## Rysuje stos toastów w prawym górnym rogu ekranu, od najnowszego (na
  ## górze) do najstarszego. Wołane z `drawMain()` PRZED ekranem blokady
  ## (patrz komentarz w `shell.nim`) -- świadomie: alarm ma obudzić także
  ## przez zablokowany ekran, tak jak w każdym telefonie/DE.
  if notifications.len == 0: return

  ## Cała warstwa toastów musi być jednym drzewem zadeklarowanym pod
  ## JEDNYM węzłem najwyższego poziomu -- dokładnie tak jak
  ## `drawTaskbar`/`drawLauncher`/`drawLockOverlay` owijają swoją treść w
  ## pojedynczy `frame` (patrz te moduły). `drawMain()` w `shell.nim` woła
  ## tę funkcję bezpośrednio, poza jakąkolwiek `frame`, więc bez własnego
  ## `frame` tutaj groupy toastów wisiałyby bez korzenia.
  frame "notifications-root":
    ## Pełny ekran, tak jak `frame "lock-overlay"` w
    ## `apps/session/session.nim` -- box zaczyna się w (0, 0), więc
    ## współrzędne dzieci poniżej (liczone względem tego framea) pokrywają
    ## się ze współrzędnymi bezwzględnymi ekranu, bez podwójnego
    ## przesunięcia. Sama warstwa jest przezroczysta i nie ma własnych
    ## `onClick`/`onHover`, więc (patrz duży komentarz w `shell.nim` o
    ## hit-testingu Fidget) nie blokuje kliknięć w pasek zadań/okna pod spodem.
    box 0, 0, windowSize.x, windowSize.y
    fill "#000000", 0.0

    var y = ToastMarginTop
    # najnowsze na górze -> iterujemy od końca seq (najnowsze dopisane na koniec)
    for i in countdown(notifications.len - 1, 0):
      let n = notifications[i]
      let bodyLines = if n.body.len > 60: 2 else: 1
      let h = 34.0'f32 + float32(bodyLines) * 16.0'f32
      let x = windowSize.x - ToastW - ToastMarginRight

      group "toast-" & $n.id:
        box x, y, ToastW, h
        fill "#1b2027", 0.97
        stroke "#333b45"
        strokeWeight 1
        cornerRadius 6

        rectangle "toast-accent-" & $n.id:
          box 0, 0, 4, h
          fill accentFor(n.kind)
          cornerRadius 2

        text "toast-title-" & $n.id:
          box ToastPad + 6, 6, ToastW - ToastPad * 2 - 20, 18
          font "sans-serif", 12, 700, 18, hLeft, vCenter
          fill "#e8ecf0"
          characters iconFor(n.kind) & "  " & n.title

        text "toast-body-" & $n.id:
          box ToastPad + 6, 24, ToastW - ToastPad * 2 - 6, h - 28
          font "sans-serif", 11, 400, 15, hLeft, vTop
          fill "#aeb6c2"
          characters n.body

        group "toast-close-" & $n.id:
          box ToastW - 22, 4, 18, 18
          cornerRadius 4
          fill "#000000", 0.0
          onHover: fill "#2a323f"
          onClick:
            dismissNotification(n.id)
          text "toast-close-label-" & $n.id:
            box 0, 0, 18, 18
            font "sans-serif", 12, 600, 18, hCenter, vCenter
            fill "#8a94a3"
            characters "×"

      y += h + ToastGap
