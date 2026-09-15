import std/[os, osproc, strutils]

## Rozbudowa v0.1 ("Aurora"): dźwięk alarmu zegara -- do tej pory alarm
## miał tylko wizualny toast (`shell/notifications.nim`), żadnego dźwięku.
## ZDE nie niesie własnych plików dźwiękowych (za duży, osobny temat --
## licencjonowanie/dobór dźwięku to nie jest coś, co da się "dorzucić przy
## okazji"), więc ten moduł jest CELOWO best-effort: szuka pierwszego
## pasującego pliku dźwiękowego spośród kilku najpopularniejszych
## lokalizacji systemowych (pakiety `sound-theme-freedesktop`/
## `alsa-utils` mają je niemal zawsze, ale NIE zawsze) i pierwszego
## dostępnego odtwarzacza (`paplay`/`pw-play`/`ffplay`/`aplay`). Gdy nic
## nie znajdzie, po cichu nic nie robi -- alarm i tak obudzi wizualnie
## (toast + ewentualnie podświetlenie okna zegara), dźwięk to bonus, nie
## jedyny kanał powiadomienia.
##
## Kolejna rozbudowa (wybór dźwięku alarmu, patrz `availableAlarmSounds`/
## `soundLabel`/parametr `soundPath` w `playAlarmSound` niżej): domykała
## ograniczenie z README ("wciąż bez wyboru dźwięku alarmu") -- teraz
## `apps/clock/clockapp.nim` daje przy tworzeniu alarmu picker cyklujący
## po dźwiękach, które NAPRAWDĘ są na tym systemie (`availableAlarmSounds`
## filtruje `CandidateSounds` przez `fileExists`), zamiast pozwalać
## wybrać coś, co i tak by nie zagrało.

const CandidateSounds = [
  "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga",
  "/usr/share/sounds/freedesktop/stereo/complete.oga",
  "/usr/share/sounds/freedesktop/stereo/bell.oga",
  "/usr/share/sounds/alsa/Front_Center.wav",
]

## Rozbudowa: krótkie, czytelne dla człowieka etykiety dla `CandidateSounds`
## -- używane w nowym pickerze dźwięku alarmu (`apps/clock/clockapp.nim`),
## żeby użytkownik wybierał "Budzik"/"Fanfary" itd., a nie surową ścieżkę
## pliku `.oga`. Tablica musi być RÓWNEJ długości i w TEJ SAMEJ kolejności
## co `CandidateSounds` -- `soundLabel` niżej po prostu szuka indeksu.
const CandidateLabels = [
  "Budzik",
  "Fanfary",
  "Dzwonek",
  "Sygnał (WAV)",
]

## Rozbudowa: dźwięk zwykłych powiadomień (toastów `nkInfo`/`nkWarning`
## z `shell/notifications.nim`), nie tylko alarmu zegara -- jawnie
## wymienione wcześniej w README jako brakujące ("bez dźwięku toastów").
## Świadomie ODRĘBNA lista kandydatów od `CandidateSounds` (alarmu) --
## alarm ma brzmieć wyraźnie i "budząco", zwykłe powiadomienia mają być
## subtelniejsze, tak jak w GNOME/KDE (inny dźwięk dla budzika niż dla
## zwykłego powiadomienia systemowego). Nazwy plików potwierdzone
## względem RZECZYWISTEJ zawartości pakietu `sound-theme-freedesktop`
## (0.8-2ubuntu1) -- nie zgadywane.
const CandidateInfoSounds = [
  "/usr/share/sounds/freedesktop/stereo/dialog-information.oga",
  "/usr/share/sounds/freedesktop/stereo/message.oga",
  "/usr/share/sounds/freedesktop/stereo/message-new-instant.oga",
]
const CandidateWarningSounds = [
  "/usr/share/sounds/freedesktop/stereo/dialog-warning.oga",
  "/usr/share/sounds/freedesktop/stereo/message.oga",
]

proc findAlarmSound(): string =
  for path in CandidateSounds:
    if fileExists(path): return path
  ""

proc findFirstExisting(candidates: openArray[string]): string =
  for path in candidates:
    if fileExists(path): return path
  ""

proc availableAlarmSounds*(): seq[string] =
  ## Rozbudowa (wybór dźwięku alarmu): zwraca TYLKO te kandydatury z
  ## `CandidateSounds`, które faktycznie istnieją na tym systemie --
  ## `apps/clock/clockapp.nim` prezentuje użytkownikowi wyłącznie tę,
  ## przefiltrowaną listę, żeby nigdy nie dało się wybrać dźwięku, który
  ## i tak by nie zagrał (bez pliku `sound-theme-freedesktop`/
  ## `alsa-utils` lista może wyjść pusta -- picker w UI obsługuje to
  ## jako "Auto (brak dźwięków)", patrz komentarz tam).
  for path in CandidateSounds:
    if fileExists(path): result.add(path)

proc soundLabel*(path: string): string =
  ## `path == ""` oznacza "auto" (najlepszy dostępny, wybierany przez
  ## `findAlarmSound` w momencie odpalenia alarmu) -- ten sam domyślny
  ## dotychczasowy tryb sprzed tej rozbudowy, zachowany jako opcja, nie
  ## usunięty.
  if path.len == 0: return "Auto"
  for i, cand in CandidateSounds:
    if cand == path: return CandidateLabels[i]
  path.extractFilename()  ## nieznana ścieżka (nie z naszej listy) -- pokaż chociaż nazwę pliku

proc findPlayerFor(soundPath: string): tuple[exe: string, args: seq[string]] =
  ## `aplay` (ALSA) odtwarza TYLKO WAV -- dla .oga/.ogg trzeba czegoś, co
  ## dekoduje Ogg Vorbis (paplay/pw-play/ffplay). Sprawdzamy w kolejności
  ## "najbardziej prawdopodobne, że jest zainstalowane na typowym
  ## systemie z dźwiękiem" -- PulseAudio i PipeWire (przez warstwę pulse)
  ## są dziś domyślne w większości dystrybucji.
  let isWav = soundPath.toLowerAscii().endsWith(".wav")
  let paplay = findExe("paplay")
  if paplay.len > 0: return (paplay, @[soundPath])
  let pwPlay = findExe("pw-play")
  if pwPlay.len > 0: return (pwPlay, @[soundPath])
  let ffplay = findExe("ffplay")
  if ffplay.len > 0: return (ffplay, @["-nodisp", "-autoexit", "-loglevel", "quiet", soundPath])
  if isWav:
    let aplay = findExe("aplay")
    if aplay.len > 0: return (aplay, @["-q", soundPath])
  ("", @[])

proc playSoundFile(path: string) =
  ## Wspólna, niskopoziomowa część `playAlarmSound`/`playNotifySound`/
  ## `playWarningSound` niżej -- odtwarzanie ODŁĄCZONE (`poDaemon`, ten
  ## sam mechanizm co uruchamianie aplikacji w `shell/desktopapps.nim`),
  ## `zde-shell` nie czeka na koniec dźwięku, nie blokuje klatki
  ## renderowania. Cicho nic nie robi, gdy `path` jest pusty (nic nie
  ## znaleziono) albo brak odtwarzacza -- dźwięk to zawsze bonus, nigdy
  ## jedyny kanał powiadomienia.
  if path.len == 0: return
  let (exe, args) = findPlayerFor(path)
  if exe.len == 0: return
  try:
    discard startProcess(exe, args = args, options = {poUsePath, poDaemon})
  except OSError:
    discard  ## najlepsze, co można zrobić -- brak dźwięku nie powinno nigdy wywalić powiadomienia wizualnego

proc playAlarmSound*(soundPath: string = "") =
  ## Wołane z `apps/clock/clockapp.nim` (`tickClock`) przy odpaleniu
  ## alarmu/końca minutnika.
  ##
  ## Rozbudowa (wybór dźwięku alarmu): `soundPath` to teraz PARAMETR, nie
  ## zawsze `findAlarmSound()` -- każdy alarm (`AlarmEntry.soundPath` w
  ## `clockapp.nim`) pamięta, KTÓRY z `availableAlarmSounds()` wybrał
  ## użytkownik przy tworzeniu. Pusty string (domyślna wartość, i to, co
  ## mają wszystkie alarmy utworzone PRZED tą rozbudową -- pola `object`
  ## dodane do istniejącego typu w Nim milcząco dostają swoją wartość
  ## zerową, czyli `""` dla `string`) zachowuje dokładnie dawne
  ## zachowanie: "auto", czyli pierwszy znaleziony kandydat. Minutnik
  ## (`tickClock`, druga gałąź) w ogóle nie ma własnego wyboru dźwięku --
  ## zawsze woła to bez argumentu, czyli też "auto"; per-minutnik wybór
  ## dźwięku to możliwa przyszła rozbudowa, świadomie odłożona, bo w tej
  ## rundzie minutnik jest zawsze dokładnie jeden naraz (w przeciwieństwie
  ## do wielu alarmów), więc potrzeba rozróżniania dźwięków jest mniejsza.
  let sound = if soundPath.len > 0 and fileExists(soundPath): soundPath
              else: findAlarmSound()
  playSoundFile(sound)

proc playNotifySound*() =
  ## Rozbudowa: dźwięk dla zwykłych powiadomień informacyjnych
  ## (`nkInfo`) -- wołane z `shell/notifications.nim` (`notify`), NIE dla
  ## alarmów (te mają własny, głośniejszy dźwięk wybrany przez
  ## użytkownika, patrz `playAlarmSound` wyżej -- wołanie obu na raz przy
  ## alarmie dawałoby dwa nakładające się dźwięki na jedno zdarzenie).
  playSoundFile(findFirstExisting(CandidateInfoSounds))

proc playWarningSound*() =
  ## Jak `playNotifySound`, ale dla `nkWarning` -- osobny, bardziej
  ## "ostrzegawczy" dźwięk (`dialog-warning.oga`), żeby ostrzeżenie dało
  ## się odróżnić od zwykłej informacji na sam dźwięk, bez patrzenia na
  ## ekran (ten sam pomysł co różne dźwięki systemowe w GNOME/KDE).
  playSoundFile(findFirstExisting(CandidateWarningSounds))
