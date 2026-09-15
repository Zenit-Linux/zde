import std/[osproc, streams, strutils, os, times, json]

## Rozbudowa: historia schowka (`clipHistory` niżej). Do tej pory
## `copyToClipboard`/`pasteFromClipboard` dawały tylko jednorazowy dostęp
## do BIEŻĄCEJ zawartości schowka systemowego -- coś skopiowanego wcześniej
## (w ZDE albo w dowolnej innej aplikacji, także przez XWayland) było
## bezpowrotnie nadpisywane kolejnym kopiowaniem, bez żadnego "cofnij się
## do poprzedniego", tak jak w każdym nowoczesnym DE (GNOME/KDE mają to
## jako "clipboard manager"/"klipper"). Implementacja CELOWO nie hakuje
## się w `wl_data_device`/DBus na poziomie kompozytora (`wlcomp/`) --
## zamiast tego ODPYTUJE bieżącą zawartość schowka raz na sekundę
## (`tickClipboard`, wołane z `shell.nim` tym samym rytmem co
## zegar/monitor systemu/launcher), tym samym `wl-paste`/`xclip`, którego
## już używa `pasteFromClipboard`. To nie widzi zmian klatka-po-klatce
## (do 1 sekundy opóźnienia) ani schowka PIERWOTNEGO/"primary selection"
## (środkowy klik) w X11 -- świadomy kompromis: pełne śledzenie zdarzeń
## `wl_data_device.selection` wymagałoby kodu na poziomie kompozytora
## (`wlcomp/seatext.nim`) przekazanego aż do `zde-shell` osobnym kanałem,
## czego dziś architektura ZDE nigdzie nie robi (patrz analogiczny
## kompromis przy `desktopapps.appDirsSignature`).
##
## Kolejna rozbudowa: historia od tej rundy PRZEŻYWA restart `zde-shell`
## -- dokładnie ten sam wzorzec co `shell/notifications.nim`
## (`historyFilePath`/`loadHistoryFromDisk`/`saveHistoryToDisk` tam), tylko
## odtworzony tutaj lokalnie (nie da się po prostu zaimportować tamtych
## procedur -- są prywatne, nie eksportowane -- a poza tym schowek i
## powiadomienia to koncepcyjnie różne dane, z różnymi plikami stanu, więc
## dzielenie kodu między nimi nie dawałoby realnej korzyści poza uniknięciem
## dosłownie kilkunastu powtórzonych linii).

type
  ClipboardEntry* = object
    text*: string
    at*: float

const
  ## Ile wpisów historii pamiętamy -- wystarczy na "co niedawno
  ## kopiowałem", bez ryzyka, że lista urośnie bez końca w długo
  ## działającym `zde-shell` (ten sam kompromis co `MaxHistory` w
  ## `shell/notifications.nim`).
  MaxClipHistory = 20
  ## Nie wrzucamy do historii absolutnie WSZYSTKIEGO -- pojedynczy,
  ## przypadkowo zaznaczony (i przez to skopiowany, patrz "primary
  ## selection" wyżej -- choć TEJ akurat nie śledzimy, ten sam problem
  ## dotyczy zwykłego Ctrl+C w niektórych aplikacjach) megabajt tekstu z
  ## przeglądarki/PDF-a zaśmieciłby panel i tak nie nadawałby się do
  ## sensownego pokazania w jednym wierszu listy.
  MaxEntryLen = 20_000
  ## Ten sam katalog stanu XDG co historia powiadomień
  ## (`shell/notifications.nim`, `StateSubdir`), ale OSOBNY plik -- to
  ## koncepcyjnie inne dane (schowek vs powiadomienia), więc mieszanie ich
  ## w jednym pliku JSON tylko utrudniałoby niezależne czyszczenie/debug
  ## jednego bez drugiego.
  StateSubdir = "zde"
  HistoryFileName = "clipboard.json"

var clipHistory: seq[ClipboardEntry] = @[]

proc historyFilePath(): string =
  ## `os.getConfigDir()` zwraca `$XDG_CONFIG_HOME`, nie `$XDG_STATE_HOME`
  ## -- stdlib Nim nie ma gotowca dla katalogu stanu, więc odtwarzamy tę
  ## samą logikę fallbacku co `notifications.historyFilePath` (zmienna
  ## środowiskowa, a w jej braku `~/.local/state`).
  let base =
    if existsEnv("XDG_STATE_HOME"): getEnv("XDG_STATE_HOME")
    else: getHomeDir() / ".local" / "state"
  base / StateSubdir / HistoryFileName

proc saveHistoryToDisk() =
  ## Best-effort, jak reszta integracji ZDE z otoczeniem systemowym
  ## (`notifications.nim`, `quicksettings.nim`, `desktopapps.nim`) --
  ## brak uprawnień do zapisu, pełny dysk, albo cokolwiek innego nie
  ## powinno nigdy wywrócić `zde-shell`, tylko po cichu zostawić historię
  ## nietrwałą w tej jednej sesji.
  try:
    let path = historyFilePath()
    createDir(path.parentDir())
    var arr = newJArray()
    ## `clipHistory[0]` to najnowszy wpis (patrz kolejność `insert(...,
    ## 0)` w `tickClipboard`) -- zapisujemy w kolejności "najstarszy
    ## pierwszy", żeby `loadHistoryFromDisk` mogło po prostu `add` bez
    ## odwracania, ten sam trik co w `notifications.saveHistoryToDisk`.
    for i in countdown(clipHistory.len - 1, 0):
      let e = clipHistory[i]
      arr.add(%*{"text": e.text, "at": e.at})
    writeFile(path, $arr)
  except CatchableError:
    discard

proc loadHistoryFromDisk(): seq[ClipboardEntry] =
  ## Wołane RAZ przy starcie modułu (patrz `clipHistory = ...` na końcu
  ## tego bloku) -- brak pliku (pierwsze uruchomienie na tej maszynie)
  ## albo uszkodzona/niekompatybilna zawartość po prostu dają pustą
  ## historię, nigdy nie wywalają startu shellu.
  try:
    let path = historyFilePath()
    if not fileExists(path): return @[]
    let arr = parseJson(readFile(path))
    if arr.kind != JArray: return @[]
    for item in arr:
      try:
        result.insert(ClipboardEntry(
          text: item["text"].getStr(),
          at: item["at"].getFloat(),
        ), 0)
      except CatchableError:
        discard  ## pojedynczy uszkodzony wpis -- pomijamy go, nie całą historię
    if result.len > MaxClipHistory:
      result.setLen(MaxClipHistory)
  except CatchableError:
    result = @[]

## Wczytanie trwałej historii RAZ, w momencie ładowania tego modułu (a
## więc przy starcie `zde-shell`) -- musi nastąpić PO definicji
## `loadHistoryFromDisk` powyżej (Nim wymaga, żeby proc był już
## zadeklarowany w miejscu wywołania na poziomie modułu).
clipHistory = loadHistoryFromDisk()

proc findClipboardTool(forCopy: bool): tuple[exe: string, args: seq[string]] =
  ## Zwraca (ścieżka do narzędzia, argumenty) dla kopiowania/wklejania,
  ## albo ("", @[]) jeśli nic odpowiedniego nie znaleziono.
  let wlCopy = findExe("wl-copy")
  let wlPaste = findExe("wl-paste")
  let xclip = findExe("xclip")
  if forCopy:
    if wlCopy.len > 0: return (wlCopy, @[])
    if xclip.len > 0: return (xclip, @["-selection", "clipboard"])
  else:
    if wlPaste.len > 0: return (wlPaste, @["-n"])  # -n: bez końcowego \n
    if xclip.len > 0: return (xclip, @["-selection", "clipboard", "-o"])
  ("", @[])

proc copyToClipboard*(text: string): bool =
  ## Kopiuje `text` do systemowego schowka. Zwraca `false`, jeśli żadne
  ## znane narzędzie (`wl-copy`/`xclip`) nie jest zainstalowane -- w takim
  ## wypadku wywołujący powinien pokazać użytkownikowi komunikat, a nie
  ## ciche niepowodzenie.
  let (exe, args) = findClipboardTool(forCopy = true)
  if exe.len == 0: return false
  try:
    var p = startProcess(exe, args = args, options = {poUsePath})
    p.inputStream.write(text)
    p.inputStream.close()
    discard p.waitForExit()
    p.close()
    result = true
  except OSError, IOError:
    result = false

proc pasteFromClipboard*(): tuple[text: string, ok: bool] =
  ## Czyta bieżącą zawartość schowka systemowego. `ok = false`, jeśli
  ## żadne znane narzędzie nie jest zainstalowane.
  let (exe, args) = findClipboardTool(forCopy = false)
  if exe.len == 0: return ("", false)
  try:
    let (output, code) = execCmdEx(exe & " " & args.join(" "))
    if code == 0:
      return (output, true)
    return ("", false)
  except OSError:
    return ("", false)

proc clipboardHistorySnapshot*(): seq[ClipboardEntry] =
  ## Kopia (seq w Nimie ma semantykę wartości) -- bezpieczna do iterowania
  ## przez `shell/taskbar.nim` bez ryzyka, że `tickClipboard()` zmieni
  ## listę spod nóg w trakcie rysowania (ten sam wzorzec co
  ## `historySnapshot` w `shell/notifications.nim`).
  clipHistory

proc clearClipboardHistory*() =
  clipHistory.setLen(0)
  saveHistoryToDisk()

proc tickClipboard*() =
  ## Wołane raz na sekundę z `tickMain()` w `shell/shell.nim`. Dopisuje
  ## bieżącą zawartość schowka systemowego do historii, gdy się zmieniła
  ## względem ostatnio zanotowanej -- porównanie z `clipHistory[0]`
  ## (najnowszy wpis, patrz kolejność `insert(..., 0)` niżej) wystarcza,
  ## bo interesuje nas tylko WYKRYCIE zmiany, nie każdy odczyt z osobna.
  let (text, ok) = pasteFromClipboard()
  if not ok: return
  let trimmed = text
  if trimmed.len == 0 or trimmed.len > MaxEntryLen: return
  if clipHistory.len > 0 and clipHistory[0].text == trimmed: return

  ## Jeśli ten sam tekst już jest gdzieś głębiej w historii (użytkownik
  ## wkleił coś, co wcześniej skopiował, a potem skopiował coś innego, a
  ## teraz wrócił do oryginału), przenosimy go na czoło zamiast trzymać
  ## duplikat -- dokładnie tak zachowują się realne menedżery schowka
  ## (GNOME/KDE), a bez tego historia szybko zapełniłaby się powtórzeniami
  ## tego samego, często kopiowanego fragmentu (np. własnego adresu e-mail).
  for i, e in clipHistory:
    if e.text == trimmed:
      clipHistory.delete(i)
      break

  clipHistory.insert(ClipboardEntry(text: trimmed, at: epochTime()), 0)
  if clipHistory.len > MaxClipHistory:
    clipHistory.setLen(MaxClipHistory)
  saveHistoryToDisk()
