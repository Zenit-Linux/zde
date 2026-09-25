import std/[os, hashes, times, strutils, algorithm]
import pixie

## Rozbudowa (runda 16, miniatury obrazów): domyka jawnie wypisany brak
## z README ("brak miniatur obrazów w menedżerze plików"). Ten moduł
## CELOWO importuje TYLKO `std`/`pixie` -- NIE `fidget` -- z DOKŁADNIE
## tego samego powodu, dla którego `shell/desktopapps.nim` też tego nie
## robi (patrz duży komentarz tam): `fidget` wymaga Nim >= 2.0, którego w
## tej sandboxie nie ma, więc każdy moduł zależny od niego jest
## niemożliwy do skompilowania i uruchomienia w tej sesji. Wydzielając
## CAŁĄ logikę dekodowania/skalowania/cache'owania obrazów TUTAJ, a nie
## bezpośrednio w `apps/filemanager/files.nim` (które importuje `fidget`
## do całego swojego UI), ta logika DA SIĘ realnie skompilować i
## przetestować -- dokładnie tak samo, jak runda 14 zrobiła to dla
## `desktopapps.nim`. `files.nim` importuje ten moduł i woła
## `ensureThumbnail*` -- TA integracja (właściwe narysowanie miniatury w
## wierszu listy plików przez Fidget-owe `image(...)`) pozostaje
## nieprzetestowana wizualnie w tej sesji, jak reszta UI menedżera plików
## -- ale sama logika przetwarzania obrazu, która robi całą "ciężką"
## pracę i jest źródłem realnego ryzyka (zły plik, nieobsługiwany
## format, błąd zapisu), JEST przetestowana na prawdziwych plikach.
##
## Architektura i konwencje SPECJALNIE skopiowane 1:1 z już wcześniej
## sprawdzonego (i realnie działającego, wg wcześniejszych rund)
## `shell/wallpaper.nim` (`ensureWallpaperCache`/`wallpaperCachePath`/
## `coverResize`/`pruneWallpaperCache`) -- ten sam wzorzec cache'a
## kluczowanego (ścieżka źródłowa, czas modyfikacji, docelowy rozmiar) w
## SAMEJ NAZWIE PLIKU (bez osobnego stanu do unieważniania), to samo
## "spróbuj raz, zapamiętaj porażkę" dla zepsutych/nieobsługiwanych
## plików, to samo sprzątanie najstarszych plików cache po przekroczeniu
## limitu. Skoro `wallpaper.nim` już to sprawdził w praktyce, nie ma
## powodu wymyślać innego podejścia dla tego samego rodzaju problemu.

## Rozbudowa: lista rozszerzeń, dla których w ogóle PRÓBUJEMY generować
## miniaturę -- dobrana na podstawie realnego sprawdzenia w źródle
## zainstalowanego w tej sandboxie `pixie@5.0.7` (`pixie.decodeImage`,
## `pixie/pixie.nim`), NIE z pamięci/dokumentacji: `decodeImage`
## rozpoznaje format po SYGNATURZE BAJTÓW pliku (nie po rozszerzeniu) i
## obsługuje PNG, JPEG, BMP, GIF (tylko pierwsza klatka -- bez animacji,
## ten sam kompromis co reszta ZDE z GIF-ami, patrz ograniczenia tapety),
## QOI i PPM. WebP i TIFF (mimo że `tiff.nim` istnieje jako osobny plik w
## pakiecie) NIE są w ogóle podłączone do `decodeImage` w tej wersji --
## świadomie pominięte tutaj, nie przeoczone. SVG technicznie też jest
## rozpoznawane przez `decodeImage`, ale ŚWIADOMIE pominięte w tej liście
## -- miniatury plików SVG użytkownika to inny problem niż rastrowe
## ikony aplikacji (`desktopapps.nim`), z innymi kompromisami co do
## jakości/wydajności, i nie było w zakresie tej rundy.
##
## Rozbudowa (runda 17): dekodowanie GIF sprawdzone na 82 PRAWDZIWYCH
## plikach `.gif` zainstalowanych w tej sandboxie (`find / -iname
## "*.gif"`, motywy LibreOffice + dokumentacja pakietów) -- 77/82 (94%)
## dekoduje się bez problemu, 5 nie: jeden zerwany symlink (bez związku
## z Pixie), trzy dają `Invalid GIF buffer, unable to load` (prawdziwa,
## rzadka luka w minimalnym dekoderze GIF Pixie -- niektóre pliki
## `GIF89a` z lokalną paletą kolorów go wywalają), jeden explicite
## odrzucony jako `Unsupported GIF, pixel aspect ratio`. Wszystkie 5
## przypadków kończy się PUSTYM wynikiem z `ensureThumbnail` (patrz
## `except CatchableError` niżej), NIGDY wyjątkiem -- potwierdzone
## bezpośrednio na dwóch z tych plików w `test_real_thumbnails.nim`
## (jeden, który się udaje, jeden, który jawnie nie).
const ThumbnailableExts = [".png", ".jpg", ".jpeg", ".bmp", ".gif", ".qoi", ".ppm"]

proc isThumbnailableExt*(path: string): bool =
  splitFile(path).ext.toLowerAscii() in ThumbnailableExts

proc thumbnailCacheDir(): string =
  let base =
    if existsEnv("XDG_CACHE_HOME"): getEnv("XDG_CACHE_HOME")
    else: getHomeDir() / ".cache"
  base / "zde"

const
  ## Rozbudowa: limit WYŻSZY niż `MaxWallpaperCacheFiles` w
  ## `wallpaper.nim` (12) -- tam cache trzyma góra kilkanaście POZYCJI
  ## (jedna właściwa tapeta + niedawno oglądane podglądy), tu KAŻDY plik
  ## obrazu w KAŻDYM przeglądanym katalogu dostaje własną miniaturę, więc
  ## realny scenariusz (katalog ze zdjęciami z wakacji) łatwo generuje
  ## setki plików cache. 500 to sensowny górny limit -- z zapasem na
  ## kilka średniej wielkości katalogów ze zdjęciami naraz, bez
  ## pozwalania cache'owi rosnąć bez końca przy przeglądaniu tysięcy
  ## plików w wielu sesjach.
  MaxThumbnailCacheFiles = 500
  ThumbnailSize* = 40  ## piksele, kwadrat -- z zapasem nad typowym `rowH` menedżera plików (24px), żeby nie było rozmyte na ekranach HiDPI

proc pruneThumbnailCache() =
  ## 1:1 ten sam mechanizm co `pruneWallpaperCache` w `wallpaper.nim` --
  ## patrz komentarz tam po pełne uzasadnienie "usuwanie najstarszych
  ## nigdy nie psuje danych, tylko cofa do stanu 'jeszcze niewygenerowane',
  ## `ensureThumbnail` odtworzy w razie potrzeby".
  try:
    var files: seq[tuple[path: string, mtime: Time]] = @[]
    for f in walkFiles(thumbnailCacheDir() / "thumb-*.png"):
      try:
        files.add((f, getLastModificationTime(f)))
      except OSError:
        discard
    if files.len <= MaxThumbnailCacheFiles: return
    files.sort(proc(a, b: tuple[path: string, mtime: Time]): int = cmp(a.mtime, b.mtime))
    let toRemove = files.len - MaxThumbnailCacheFiles
    for i in 0 ..< toRemove:
      try: removeFile(files[i].path)
      except OSError: discard
  except OSError:
    discard

proc thumbnailCachePath(srcPath: string, size: int): string =
  ## Ten sam potrójny klucz (ścieżka, czas modyfikacji, rozmiar) w SAMEJ
  ## NAZWIE PLIKU co `wallpaperCachePath` -- patrz komentarz tam.
  var mtimeUnix: int64 = 0
  try: mtimeUnix = getLastModificationTime(srcPath).toUnix()
  except OSError: discard
  let key = $hash(srcPath) & "-" & $mtimeUnix
  thumbnailCacheDir() / ("thumb-" & key & "-" & $size & "x" & $size & ".png")

proc squareCoverCrop(src: Image, size: int): Image =
  ## Ten sam algorytm "cover" (skaluj wg krótszej krawędzi, przytnij
  ## nadmiar dłuższej z OBU stron -- środek pozostaje wycentrowany) co
  ## `coverResize` w `wallpaper.nim`, wyspecjalizowany dla KWADRATOWEGO
  ## wyniku (`size`x`size`, bo wiersz listy plików to jedna, stała
  ## wysokość niezależnie od proporcji oryginalnego zdjęcia -- portret czy
  ## panorama, miniatura zawsze ma być tym samym małym kwadratem, tak jak
  ## w każdej realnej przeglądarce plików).
  let srcAspect = src.width.float / src.height.float
  var scaledW, scaledH: int
  if srcAspect > 1.0:
    scaledH = size
    scaledW = int(size.float * srcAspect)
  else:
    scaledW = size
    scaledH = int(size.float / srcAspect)
  scaledW = max(scaledW, size)
  scaledH = max(scaledH, size)
  let resized = resize(src, scaledW, scaledH)
  let cropX = (scaledW - size) div 2
  let cropY = (scaledH - size) div 2
  subImage(resized, cropX, cropY, size, size)

var
  ## Ten sam mechanizm "spróbuj raz, zapamiętaj porażkę" co
  ## `lastAttemptedWallpaper`/`lastAttemptSucceeded` w `wallpaper.nim` --
  ## ale tu jako TABLICA (nie pojedyncza para), bo w JEDNYM katalogu może
  ## być jednocześnie WIELE różnych plików obrazów, z których część jest
  ## uszkodzona/nieobsługiwana -- pojedyncza pamięć "ostatnia próba"
  ## nadawałaby się tylko dla JEDNEGO pliku naraz, tak jak w
  ## `wallpaper.nim` wystarcza (bo tam jest tylko JEDNA aktywna tapeta),
  ## ale tutaj by nie wystarczyło.
  gFailedThumbnails: seq[string]  ## klucze (ścieżka+mtime+rozmiar), dla których dekodowanie/zapis już raz zawiodło w tym procesie

proc ensureThumbnail*(srcPath: string, size: int = ThumbnailSize): string =
  ## Zwraca ścieżkę do gotowej, kwadratowej miniatury PNG w cache'u, albo
  ## "", gdy się nie da (zły/uszkodzony plik, nieobsługiwany format mimo
  ## pasującego rozszerzenia, błąd zapisu...) -- best-effort, ten sam duch
  ## co `ensureWallpaperCache`: błąd tu nigdy nie powinien przerwać
  ## rysowania listy plików, tylko dać pusty wynik, żeby wywołujący
  ## (`files.nim`) po prostu pokazał zwykłą ikonę zastępczą zamiast
  ## miniatury.
  if not isThumbnailableExt(srcPath): return ""
  let cachePath = thumbnailCachePath(srcPath, size)
  if fileExists(cachePath): return cachePath

  if cachePath in gFailedThumbnails: return ""

  try:
    let src = readImage(srcPath)
    if src.width <= 0 or src.height <= 0: return ""
    let thumb = squareCoverCrop(src, size)
    createDir(cachePath.parentDir())
    thumb.writeFile(cachePath)
    pruneThumbnailCache()
    return cachePath
  except CatchableError:
    gFailedThumbnails.add(cachePath)
    return ""
