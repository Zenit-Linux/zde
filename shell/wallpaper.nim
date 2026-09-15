import std/[os, hashes, times, algorithm]
import fidget
import pixie
import state

## Rozbudowa v0.1 ("Aurora"): tapeta zastępcza dostała pionowy gradient
## (symulowany kilkoma nachodzącymi na siebie pasami o malejącej
## przezroczystości -- Fidget nie ma tu wbudowanego prawdziwego
## `linear-gradient`, więc to najbliższe podejście bez sięgania po własny
## shader) oraz dwie miękkie, rozmyte plamy koloru akcentu ("glow"), żeby
## pulpit nie wyglądał jak jednolita plama koloru tak jak poprzednio.
##
## Uwaga wydajnościowa: liczba warstw jest CELOWO mała (kilkanaście
## prostokątów/kół total) -- to się rysuje na każdą klatkę, więc gęsta
## siatka kropek czy dziesiątki warstw gradientu potrafiłyby zauważalnie
## obciążyć rysowanie przy niczym nie dającej w zamian poprawie wyglądu.
##
## Rozbudowa: prawdziwa tapeta z pliku obrazu (`state.WallpaperPath`,
## ustawiane przez "Ustawienia" -> "Wygląd", patrz `apps/settings/
## settings.nim`). Gdy ścieżka jest pusta (domyślnie, i dla każdej
## instalacji sprzed tej rozbudowy), pulpit wygląda dokładnie tak jak
## dotąd -- wbudowany gradient poniżej, bez żadnej zmiany zachowania.
##
## Obraz użytkownika NIGDY nie trafia bezpośrednio do `image(...)`
## Fidget-a -- zamiast tego jest raz przetworzony przez Pixie (ten sam
## silnik, którego już używa `shell/desktopapps.nim` do ikon) do
## dokładnie takiego rozmiaru jak ekran, metodą "cover" (przeskalowanie +
## przycięcie środka, bez zniekształcenia proporcji -- ten sam algorytm
## co "wypełnij ekran" w GNOME/KDE), i zapisany jako plik cache w
## katalogu `$XDG_CACHE_HOME` (patrz `wallpaperCachePath` niżej). Dwa
## powody: (1) `image(...)` w Fidget prawdopodobnie tylko rozciąga obraz
## do zadanego `box` BEZ zachowania proporcji -- dowolne zdjęcie
## użytkownika (inne wymiary/proporcje niż ekran) wyglądałoby
## rozciągnięte/spłaszczone bez tego kroku; (2) ten sam rodzaj ryzyka co
## przy ikonach aplikacji (`isDecodablePng` w `desktopapps.nim`) --
## Fidget/Pixie w tej wersji potrafi rzucić wyjątkiem przy pewnych
## plikach (np. 16-bit/kanał PNG), którego NIC w pętli renderowania nie
## łapie, więc lepiej zdekodować i przetworzyć obraz TU, gdzie MY
## kontrolujemy `try`/`except`, niż dowiedzieć się o awarii dopiero w
## trakcie rysowania klatki.

const GradientBands = 10

proc drawGlow(idPrefix: string, cx, cy, radius: float32, color: string, alpha: float32) =
  ## "Poświata" -- duże koło (kwadrat z `cornerRadius` = połowa boku, patrz
  ## ten sam trik w `apps/clock/clockapp.nim` dla tarczy zegara) z niską
  ## nieprzezroczystością, żeby wyglądało jak miękka plama światła, nie
  ## twardy dysk.
  rectangle idPrefix:
    box cx - radius, cy - radius, radius * 2, radius * 2
    fill color, alpha
    cornerRadius radius

proc drawGradientWallpaper() =
  ## Dawna (i wciąż domyślna, gdy nie skonfigurowano tapety z pliku)
  ## zawartość `drawWallpaper` -- wydzielona do osobnej procedury, żeby
  ## `drawWallpaper` mogła zdecydować MIĘDZY tym a prawdziwym obrazem, nie
  ## dublując reszty ramki `frame "wallpaper":`.
  # -- pionowy gradient BgTop -> BgDeep, symulowany pasami -----------------
  for i in 0 ..< GradientBands:
    let t = float32(i) / float32(GradientBands - 1)
    rectangle "wallpaper-band-" & $i:
      box 0, windowSize.y * t * 0.7'f32, windowSize.x,
          windowSize.y / float32(GradientBands) + 2
      fill BgTop, (1.0'f32 - t) * 0.9'f32

  # -- miękkie plamy koloru akcentu, offscreen-ish w rogach ----------------
  drawGlow("wallpaper-glow-1", windowSize.x * 0.82'f32, windowSize.y * 0.18'f32,
            min(windowSize.x, windowSize.y) * 0.32'f32, AccentColor, 0.10)
  drawGlow("wallpaper-glow-2", windowSize.x * 0.12'f32, windowSize.y * 0.78'f32,
            min(windowSize.x, windowSize.y) * 0.24'f32, AccentColor, 0.06)

  # -- subtelna, cienka linia horyzontu 2/3 wysokości ekranu ---------------
  rectangle "wallpaper-horizon":
    box 0, windowSize.y * 0.64'f32, windowSize.x, 1
    fill "#ffffff", 0.03

  group "wallpaper-brand":
    box 24, windowSize.y - 56, 400, 40
    text "wallpaper-label":
      box 0, 0, 400, 22
      font "sans-serif", 14, 700, 22, hLeft, vBottom
      fill TextMuted
      characters "Zenit Linux"
    text "wallpaper-sublabel":
      box 0, 22, 400, 18
      font "sans-serif", 11, 400, 18, hLeft, vTop
      fill TextFaint
      characters "ZDE -- środowisko graficzne v0.1"

proc wallpaperCacheDir(): string =
  let base =
    if existsEnv("XDG_CACHE_HOME"): getEnv("XDG_CACHE_HOME")
    else: getHomeDir() / ".cache"
  base / "zde"

const
  ## Rozbudowa (sprzątanie cache'a): ile najnowszych plików cache tapety
  ## trzymamy naraz. Jawnie wymienione wcześniej jako ograniczenie ("cache
  ## nie jest nigdy sprzątany") -- każda zmiana tapety/rozdzielczości ORAZ
  ## każdy nowy podgląd miniatury w Ustawieniach (patrz
  ## `apps/settings/settings.nim`, `ensureWallpaperCache` wołane z
  ## rozmiarem 160x90) zostawiał nowy plik bez usuwania starych. 12 to
  ## z zapasem: właściwa tapeta ekranu (zwykle 1, rzadko 2 przy zmianie
  ## rozdzielczości) + kilkanaście niedawno OGLĄDANYCH w podglądzie
  ## miniatur -- nikt nie przegląda dziesiątek kandydatów na tapetę w
  ## jednej sesji Ustawień, więc to z naddatkiem pokrywa typowe użycie,
  ## nie ucinając w połowie przeglądania.
  MaxWallpaperCacheFiles = 12

proc pruneWallpaperCache() =
  ## Usuwa NAJSTARSZE (wg czasu modyfikacji) pliki cache tapety, gdy jest
  ## ich więcej niż `MaxWallpaperCacheFiles` -- samoleczące się w tym
  ## sensie, że usunięcie pliku, który akurat jest w użyciu, nie psuje
  ## niczego: `ensureWallpaperCache` po prostu wygeneruje go PONOWNIE przy
  ## następnym potrzebnym wywołaniu (dopóki plik źródłowy wciąż istnieje
  ## na dysku) -- ten sam duch co reszta cache'y w ZDE (`clipboard.nim`,
  ## `notifications.nim`): utrata pliku stanu to co najwyżej niedogodność
  ## (jedno dodatkowe przetworzenie obrazu), nigdy utrata DANYCH
  ## użytkownika (oryginalny plik obrazu nigdy nie jest dotykany, tylko
  ## czytany). Wołane wyłącznie PO faktycznym zapisaniu nowego pliku cache
  ## (patrz `ensureWallpaperCache` niżej) -- nie na każdej klatce, więc
  ## koszt (listowanie katalogu + sortowanie) ponoszony jest rzadko, nie
  ## 60x/s.
  try:
    var files: seq[tuple[path: string, mtime: Time]] = @[]
    for f in walkFiles(wallpaperCacheDir() / "wallpaper-*.png"):
      try:
        files.add((f, getLastModificationTime(f)))
      except OSError:
        discard
    if files.len <= MaxWallpaperCacheFiles: return
    files.sort(proc(a, b: tuple[path: string, mtime: Time]): int = cmp(a.mtime, b.mtime))
    let toRemove = files.len - MaxWallpaperCacheFiles
    for i in 0 ..< toRemove:
      try: removeFile(files[i].path)
      except OSError: discard
  except OSError:
    discard

proc wallpaperCachePath(srcPath: string, w, h: int): string =
  ## Klucz cache'a koduje ŹRÓDŁO (ścieżka + czas modyfikacji) I docelowy
  ## rozmiar w SAMEJ NAZWIE PLIKU -- żaden osobny plik-znacznik ani
  ## zmienna trzymana w pamięci procesu nie jest potrzebna, żeby wiedzieć,
  ## czy istniejący plik cache wciąż pasuje: zmiana tapety, edycja pliku
  ## źródłowego (inny czas modyfikacji), albo zmiana rozdzielczości ekranu
  ## -- każde z tych po prostu daje INNĄ nazwę pliku, więc stary cache
  ## zwyczajnie przestaje być trafiany, bez logiki unieważniania. Ten sam
  ## styl co `appDirsSignature` w `desktopapps.nim` -- policz z tego, co
  ## już jest na dysku, zamiast trzymać osobny stan.
  var mtimeUnix: int64 = 0
  try: mtimeUnix = getLastModificationTime(srcPath).toUnix()
  except OSError: discard
  let key = $hash(srcPath) & "-" & $mtimeUnix
  wallpaperCacheDir() / ("wallpaper-" & key & "-" & $w & "x" & $h & ".png")

proc coverResize(src: Image, targetW, targetH: int): Image =
  ## Skalowanie + przycięcie metodą "cover" (jak `background-size: cover`
  ## w CSS, albo "Wypełnij" w ustawieniach tapety GNOME/KDE) -- obraz
  ## wypełnia CAŁY ekran bez pasów, kosztem przycięcia nadmiaru z jednej
  ## osi, ale BEZ zniekształcenia proporcji (w przeciwieństwie do zwykłego
  ## rozciągnięcia do `targetW`x`targetH`).
  let srcAspect = src.width.float / src.height.float
  let targetAspect = targetW.float / targetH.float
  var scaledW, scaledH: int
  if srcAspect > targetAspect:
    ## Źródło proporcjonalnie SZERSZE niż ekran -- skaluj wg wysokości,
    ## przytnij nadmiar szerokości z boków.
    scaledH = targetH
    scaledW = int(targetH.float * srcAspect)
  else:
    ## Źródło proporcjonalnie WYŻSZE (albo tych samych proporcji) --
    ## skaluj wg szerokości, przytnij nadmiar wysokości góra/dół.
    scaledW = targetW
    scaledH = int(targetW.float / srcAspect)
  ## Zabezpieczenie przed błędem zaokrąglenia przy rzutowaniu float->int
  ## (np. `scaledW` wychodzi o 1px za mały przez obcięcie części
  ## ułamkowej) -- bez tego `subImage` niżej mógłby dostać ujemny zakres
  ## przycięcia i rzucić wyjątkiem zamiast dać prawidłowy wynik.
  scaledW = max(scaledW, targetW)
  scaledH = max(scaledH, targetH)
  let resized = resize(src, scaledW, scaledH)
  let cropX = (scaledW - targetW) div 2
  let cropY = (scaledH - targetH) div 2
  subImage(resized, cropX, cropY, targetW, targetH)

var
  ## Zapamiętane, żeby NIE próbować dekodować/przetwarzać tego samego,
  ## uszkodzonego/nieobsługiwanego pliku źródłowego na każdej klatce (60x/s)
  ## -- kosztowna operacja (dekodowanie + skalowanie obrazu) skazana z
  ## góry na tę samą porażkę powinna zawieść RAZ, nie w nieskończoność.
  ## Klucz to (ścieżka, szerokość, wysokość) -- ten sam potrójny klucz co
  ## w nazwie pliku cache, patrz `wallpaperCachePath`.
  lastAttemptedWallpaper = ("", 0, 0)
  lastAttemptSucceeded = false

proc ensureWallpaperCache*(srcPath: string, w, h: int): string =
  ## Zwraca ścieżkę do gotowego, przetworzonego pliku cache, albo "",
  ## gdy się nie da (zły plik, błąd zapisu...). Best-effort, jak reszta
  ## integracji ZDE z systemem plików (`notifications.nim`,
  ## `clipboard.nim`) -- błąd tutaj nigdy nie powinien zabić `zde-shell`,
  ## tylko po cichu cofnąć do wbudowanego gradientu.
  ##
  ## Eksportowane (rozbudowa: podgląd miniatury) -- `apps/settings/
  ## settings.nim` woła to samo z małym rozmiarem (160x90) do podglądu w
  ## UI PRZED kliknięciem "Zastosuj", zamiast duplikować całą tę logikę
  ## cache'a/obsługi błędów osobno dla podglądu. Klucz cache'a i tak
  ## zawiera docelowy rozmiar (patrz `wallpaperCachePath`), więc podgląd
  ## 160x90 i właściwa tapeta rozmiaru ekranu naturalnie trafiają w dwa
  ## RÓŻNE pliki cache, bez wzajemnej kolizji.
  if srcPath.len == 0: return ""
  let cachePath = wallpaperCachePath(srcPath, w, h)
  if fileExists(cachePath): return cachePath

  let key = (srcPath, w, h)
  if key == lastAttemptedWallpaper:
    return (if lastAttemptSucceeded: cachePath else: "")
  lastAttemptedWallpaper = key

  try:
    let src = readImage(srcPath)
    let final = coverResize(src, w, h)
    createDir(cachePath.parentDir())
    final.writeFile(cachePath)
    lastAttemptSucceeded = true
    pruneWallpaperCache()
    return cachePath
  except CatchableError:
    lastAttemptSucceeded = false
    return ""

proc drawWallpaper*() =
  frame "wallpaper":
    box 0, 0, windowSize.x, windowSize.y
    fill BgDeep

    ## `ensureWallpaperCache` może zwrócić "" (brak tapety skonfigurowanej
    ## ALBO przetwarzanie się nie powiodło) -- w obu przypadkach spadamy
    ## do dawnego gradientu. Dodatkowe `fileExists` TUŻ PRZED narysowaniem
    ## (mimo że `ensureWallpaperCache` już to sprawdzał chwilę wcześniej)
    ## to ostatnia linia obrony na wypadek, gdyby plik cache zniknął z
    ## dysku MIĘDZY tymi dwoma sprawdzeniami (np. ktoś ręcznie wyczyścił
    ## `~/.cache` w trakcie działania sesji) -- `image(...)` w Fidget nie
    ## ma własnej obsługi brakującego pliku, więc lepiej nie zaryzykować.
    let cachePath =
      if WallpaperPath.len > 0:
        ensureWallpaperCache(WallpaperPath, int(windowSize.x), int(windowSize.y))
      else: ""

    if cachePath.len > 0 and fileExists(cachePath):
      ## `dataDir = "/"` ustawione raz w `shell.nim` (`when isMainModule`)
      ## -- stąd ścieżka BEZ wiodącego "/", ten sam trik co ikony
      ## aplikacji w `shell/taskbar.nim` (`drawLauncherRow`).
      rectangle "wallpaper-image":
        box 0, 0, windowSize.x, windowSize.y
        image cachePath[1 .. ^1]
    else:
      drawGradientWallpaper()
