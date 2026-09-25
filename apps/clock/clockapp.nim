import std/[times, strformat, sequtils, math]
import fidget
import ../../comp/comp
import ../../shell/notifications
import ../../shell/sound

## Rozbudowa v0.1: zegar dostał drugą zakładkę -- "Alarmy" -- z listą
## alarmów budzących o stałej porze dnia oraz prostym minutnikiem
## (countdown). To domyka lukę opisaną wcześniej w README ("zegar nie ma
## alarmów/timerów -- to czysto wizualny widget"). Odpalanie alarmu/końca
## minutnika korzysta z nowego, wspólnego systemu powiadomień
## (`shell/notifications.nim`), więc toast pokaże się nawet gdy okno
## zegara nie jest aktywne (dopóki proces `zde-shell` żyje -- patrz
## ograniczenia w komentarzu tego modułu).

type
  ClockTab = enum
    tabDial   ## klasyczna tarcza analogowa + cyfrowy zegar (zachowanie sprzed rozbudowy)
    tabAlarms ## nowa zakładka: alarmy + minutnik

  AlarmEntry = object
    id: int
    hour, minute: int
    label: string
    enabled: bool
    ## Minuta doby (hour*60+minute), w której alarm ostatnio wystrzelił --
    ## `tickClock` jest wołane raz na sekundę, więc bez tego zabezpieczenia
    ## alarm wysyłałby to samo powiadomienie 60 razy w ciągu minuty, w
    ## której trafia. -1 = jeszcze nie odpalił w bieżącej sesji.
    lastFiredMinuteOfDay: int
    ## Rozbudowa (wybór dźwięku alarmu, patrz `shell/sound.nim`): ścieżka
    ## do pliku dźwiękowego wybranego w kreatorze PRZY TWORZENIU tego
    ## alarmu (patrz `newSoundIdx`/picker niżej). "" = "Auto" (pierwszy
    ## dostępny, dokładnie dawne zachowanie sprzed tej rozbudowy) -- to
    ## też domyślna wartość dla alarmów wczytanych/utworzonych przed jej
    ## wprowadzeniem, bo Nim zeruje nowe pola `object` do ich wartości
    ## domyślnej (`""` dla `string`), nie zostawia ich niezainicjowanych.
    soundPath: string

  TimerPhase = enum
    timerIdle, timerRunning, timerPaused, timerDone

  ClockState* = ref object of RootObj
    tab: ClockTab
    alarms: seq[AlarmEntry]
    nextAlarmId: int
    newHour, newMinute: int  ## godzina/minuta ustawiana w kreatorze nowego alarmu (steppery)
    ## Rozbudowa (wybór dźwięku alarmu): indeks w `availableAlarmSounds()`
    ## wybrany w kreatorze nowego alarmu -- `-1` oznacza "Auto" (patrz
    ## `AlarmEntry.soundPath`). Trzymany jako indeks, nie ścieżka wprost,
    ## żeby cyklowanie przyciskiem w UI (`onClick` w pickerze) było prostą
    ## arytmetyką modulo, niezależną od tego, ile dźwięków akurat istnieje
    ## na danym systemie.
    newSoundIdx: int
    # -- minutnik --
    timerTotalSec: int         ## ustawiony czas w sekundach (edytowalny gdy timerIdle/timerDone)
    timerRemainingSec: int
    timerPhase: TimerPhase
    ## Rozbudowa v0.2 (wybór dźwięku minutnika): do tej rundy minutnik
    ## ZAWSZE odtwarzał `playAlarmSound()` bez argumentu (pierwszy
    ## dostępny dźwięk -- "Auto") -- README (sekcja "Ograniczenia")
    ## jawnie to wymieniało: "minutnik nadal zawsze używa dźwięku Auto".
    ## Ten sam wzorzec co `newSoundIdx` dla alarmów -- indeks w
    ## `availableAlarmSounds()`, `-1` = "Auto" -- ale osobne pole, bo
    ## minutnik to jeden, stały byt (nie lista jak alarmy), więc nie
    ## potrzebuje osobnego "kreatora": wybór dotyczy WPROST bieżącego
    ## minutnika, nie jakiegoś przyszłego wpisu dodawanego do listy.
    timerSoundIdx: int

proc newClockState*(): ClockState =
  ClockState(
    tab: tabDial, alarms: @[], nextAlarmId: 1, newHour: 7, newMinute: 0, newSoundIdx: -1,
    timerTotalSec: 5 * 60, timerRemainingSec: 5 * 60, timerPhase: timerIdle, timerSoundIdx: -1,
  )

proc tickClock*(cs: ClockState) =
  ## Wołane raz na sekundę z `shell.nim` (`tickMain`, przez rejestr
  ## `clocks` w `shell/state.nim` -- ten sam wzorzec co `terminals`/
  ## `sysmonitors`). Sprawdza alarmy i odlicza minutnik.
  let n = now()
  let minuteOfDay = n.hour * 60 + n.minute
  for a in cs.alarms.mitems:
    if a.enabled and a.hour == n.hour and a.minute == n.minute and
       a.lastFiredMinuteOfDay != minuteOfDay:
      a.lastFiredMinuteOfDay = minuteOfDay
      let lbl = if a.label.len > 0: a.label else: "Alarm"
      notify(lbl, &"Zaplanowano na {a.hour:02}:{a.minute:02}", nkAlarm)
      playAlarmSound(a.soundPath)  ## rozbudowa -- patrz shell/sound.nim (best-effort, może nic nie zrobić)

  if cs.timerPhase == timerRunning:
    if cs.timerRemainingSec <= 1:
      cs.timerRemainingSec = 0
      cs.timerPhase = timerDone
      notify("Minutnik", "Czas minął", nkAlarm)
      ## Rozbudowa v0.2: użyj wybranego dźwięku minutnika
      ## (`cs.timerSoundIdx`), nie zawsze "Auto" -- ten sam wzorzec co
      ## `playAlarmSound(a.soundPath)` dla alarmów wyżej.
      let sounds = availableAlarmSounds()
      let chosenSound = if cs.timerSoundIdx >= 0 and cs.timerSoundIdx < sounds.len:
                           sounds[cs.timerSoundIdx]
                         else: ""
      playAlarmSound(chosenSound)
    else:
      dec cs.timerRemainingSec

## Fidget nie ma osobnych prymitywów `ellipse`/`line` -- tylko `rectangle`
## (który z `cornerRadius >= połowa boku` staje się kołem) i `rotation`.
## Każdą wskazówkę/kreskę rysujemy więc jako cienki prostokąt.
##
## NAPRAWIONY BUG (znaleziony realnym zrzutem ekranu pod Xvfb -- tarcza
## zegara renderowała się KOMPLETNIE PUSTA, bez kresek ani wskazówek):
## poprzedni komentarz w tym miejscu twierdził, że `rotation` obraca
## węzeł "wokół lewego-górnego rogu jego boxa" -- to było błędne
## założenie, nigdy realnie nie zweryfikowane. Prawdziwe źródło Fidget
## (`fidget/openglbackend.nim`, `proc draw`) pokazuje, że obrót zawsze
## idzie wokół ŚRODKA WŁASNEGO `screenBox` węzła:
##   `ctx.translate(screenBox.wh/2); ctx.rotate(...); ctx.translate(-screenBox.wh/2)`.
## Poprzedni kod deklarował prostokąt jako `box cx, cy-t/2, length, t`
## (zaczynający się W ŚRODKU tarczy) i liczył na to, że obróci się wokół
## TEGO punktu (cx,cy) -- w rzeczywistości obracał się wokół WŁASNEGO
## środka, czyli punktu `(cx+length/2, cy)`, więc punkt (cx,cy) --
## miejsce, gdzie wskazówka miała się "trzymać" środka tarczy -- uciekał
## po okręgu o promieniu `length/2` przy każdym obrocie, a cała wskazówka
## lądowała daleko poza widoczną tarczą.
##
## Naprawa: liczymy końcówkę wskazówki wprost trygonometrią i
## pozycjonujemy NIEOBRÓCONY prostokąt tak, żeby jego WŁASNY środek
## pokrywał się ze środkiem odcinka (cx,cy)-(ex,ey) -- wtedy obrót wokół
## własnego środka jest już poprawny, bo to dokładnie ta sama oś, jakiej
## potrzebujemy.

proc drawRadialBar(idPrefix: string, cx, cy, length, thicknessPx, angleDeg: float32, color: string) =
  let rad = angleDeg.float64 * PI / 180.0
  let ex = cx + length * cos(rad).float32
  let ey = cy + length * sin(rad).float32
  let mx = (cx + ex) / 2
  let my = (cy + ey) / 2
  rectangle idPrefix:
    box mx - length / 2, my - thicknessPx / 2, length, thicknessPx
    fill color
    rotation angleDeg

const
  TabBarH = 30.0'f32
  AccentColorForTab = "#e8ecf0"  ## etykieta aktywnej zakładki -- neutralna biel,
                                  ## nie ciągniemy tu zależności do `shell/state.nim`
                                  ## (patrz uzasadnienie w `notifications.nim`)

proc drawTabBar(cs: ClockState, w: float32) =
  group "clock-tabbar":
    box 0, 0, w, TabBarH
    fill "#181c22"

    const tabs = [(tabDial, "Zegar"), (tabAlarms, "Alarmy")]
    let tabW = w / float32(tabs.len)
    for i, t in tabs:
      let tabKind = t[0]
      let label = t[1]
      let active = cs.tab == tabKind
      group "clock-tab-" & label:
        box float32(i) * tabW, 0, tabW, TabBarH
        fill (if active: "#12161c" else: "#181c22")
        onHover:
          if not active: fill "#1d222a"
        onClick:
          cs.tab = tabKind
        text "clock-tab-label-" & label:
          box 0, 0, tabW, TabBarH
          font "sans-serif", 12, (if active: 700 else: 400), TabBarH, hCenter, vCenter
          fill (if active: AccentColorForTab else: "#8a94a3")
          characters label
        if active:
          ## Współrzędne WZGLĘDEM rodzica ("clock-tab-" grupa, patrz box
          ## wyżej) -- lokalne x=0 (nie `i * tabW` ponownie, bo to by
          ## podwójnie przesunęło pasek poza własną szerokość grupy).
          rectangle "clock-tab-underline-" & label:
            box 0, TabBarH - 2, tabW, 2
            fill "#5fb0ff"

proc drawDialTab(win: ZdeWindow, topOffset: float32) =
  let now = now()
  let pad = 16.0'f32
  let availH = win.size.y - topOffset
  let dialSize = min(win.size.x - pad * 2, availH - 120)
  let cx = win.size.x / 2
  let cy = topOffset + pad + dialSize / 2
  let radius = dialSize / 2

  ## NAPRAWIONY BUG (znaleziony realnym zrzutem ekranu -- tarcza była
  ## widoczna jako pusty okrąg, bez kresek i wskazówek): w tym silniku
  ## element zadeklarowany JAKO PIERWSZY renderuje się NA WIERZCHU (patrz
  ## duży komentarz o odwróconej kolejności rysowania w `shell/shell.nim`,
  ## `drawMain`). Tło tarczy MUSI więc być zadeklarowane OSTATNIE wśród
  ## tych rodzeństw-węzłów (`dial`/kreski/wskazówki/piasta), inaczej --
  ## dokładnie jak tutaj poprzednio -- nieprzezroczyste tło tarczy
  ## renderuje się NA WIERZCHU kresek i wskazówek, całkowicie je zasłaniając.

  # -- znaczniki godzin (12 kresek, jako obrócone paski od środka) ---------
  for h in 0 ..< 12:
    let angle = float32(h) * 30.0'f32 - 90.0'f32
    drawRadialBar("tick-" & $h, cx, cy, radius - 6, 2, angle, "#5b6b7d")

  # -- wskazówki ------------------------------------------------------------
  let hour24 = now.hour
  let hour12 = float32(hour24 mod 12) + float32(now.minute) / 60.0'f32
  let hourAngle = hour12 * 30.0'f32 - 90.0'f32
  let minuteAngle = float32(now.minute) * 6.0'f32 - 90.0'f32
  let secondAngle = float32(now.second) * 6.0'f32 - 90.0'f32

  drawRadialBar("hand-hour", cx, cy, radius * 0.5, 5, hourAngle, "#e8ecf0")
  drawRadialBar("hand-minute", cx, cy, radius * 0.72, 3.5, minuteAngle, "#cfd6dd")
  drawRadialBar("hand-second", cx, cy, radius * 0.8, 1.5, secondAngle, "#e0685a")

  rectangle "hub":
    box cx - 4, cy - 4, 8, 8
    fill "#e8ecf0"
    cornerRadius 4

  # -- tarcza (kwadrat z cornerRadius = promień -> koło) -- CELOWO OSTATNIA,
  # patrz komentarz wyżej o kolejności rysowania ----------------------------
  rectangle "dial":
    box cx - radius, cy - radius, dialSize, dialSize
    fill "#181f28"
    stroke "#3a4756"
    strokeWeight 2
    cornerRadius radius

  # -- cyfrowy zegar + data pod tarczą --------------------------------------
  text "digital":
    box 0, cy + radius + 14, win.size.x, 32
    font "monospace", 22, 600, 32, hCenter, vTop
    fill "#e8ecf0"
    characters now.format("HH:mm:ss")

  const dniTygodnia = ["poniedziałek", "wtorek", "środa", "czwartek",
                       "piątek", "sobota", "niedziela"]
  let dow = dniTygodnia[ord(now.weekday)]
  ## NAPRAWIONY BUG (znaleziony realnym zrzutem ekranu -- data pokazywała
  ## się jako "środa, 09 September 2026", polski dzień tygodnia
  ## wymieszany z angielską nazwą miesiąca): `$now.month` z `std/times`
  ## zawsze zwraca nazwę PO ANGIELSKU (`mJanuary`..`mDecember` w enumie
  ## `Month`), nie ma wbudowanej lokalizacji -- ten sam problem, który już
  ## raz naprawiono dla dnia tygodnia (`dniTygodnia` powyżej), tu został
  ## przeoczony.
  const miesiace = ["stycznia", "lutego", "marca", "kwietnia", "maja",
                     "czerwca", "lipca", "sierpnia", "września",
                     "października", "listopada", "grudnia"]
  let monthName = miesiace[ord(now.month) - 1]
  text "date":
    box 0, cy + radius + 48, win.size.x, 24
    font "sans-serif", 13, 400, 20, hCenter, vTop
    fill "#8a94a3"
    characters &"{dow}, {now.monthday:02} {monthName} {now.year}"

proc drawStepper(idPrefix: string, x, y, w: float32, value, minV, maxV: int,
                  setValue: proc(v: int) {.closure.}) =
  ## Para przycisków -/+ z liczbą pośrodku (dwucyfrowo, z zerem wiodącym) --
  ## celowo zamiast pola tekstowego: dla godziny/minuty steppery są mniej
  ## podatne na błędy wpisania ("61" jako minuta) niż surowy tekst, i nie
  ## wymagają obsługi fokusu klawiatury w małym okienku 320px szerokości.
  ##
  ## `setValue` jest zamknięciem (closure) zamiast `value: var int` --
  ## Nim nie pozwala bezpiecznie przechwytywać parametrów `var` wewnątrz
  ## zamknięć `onClick` (mogłyby przeżyć ramkę stosu tej funkcji), więc
  ## wywołujący przekazuje mały setter zamiast referencji do pola.
  group idPrefix & "-stepper":
    box x, y, w, 26
    group idPrefix & "-dec":
      box 0, 0, 22, 26
      cornerRadius 4
      fill "#2a2f36"
      onHover: fill "#3a424d"
      onClick:
        setValue(if value <= minV: maxV else: value - 1)
      text idPrefix & "-dec-label":
        box 0, 0, 22, 26
        font "sans-serif", 14, 700, 26, hCenter, vCenter
        fill "#e8ecf0"
        characters "-"
    ## NAPRAWIONY BUG (znaleziony realnym zrzutem ekranu -- "07" renderowało
    ## się jako "0" nad "7" zamiast obok siebie): pole wartości było za
    ## wąskie na dwa znaki monospace przy rozmiarze fontu 15 (14px szerokości
    ## na tekst potrzebujący ~20px), więc silnik zawijał tekst na dwie
    ## linie. Przyciski -/+ zwężone z 26 do 22px (`-dec`/`-inc` wyżej/niżej)
    ## i pole wartości teraz wypełnia CAŁĄ przestrzeń między nimi zamiast
    ## węższego, ręcznie dobranego prostokąta.
    text idPrefix & "-value":
      box 22, 0, w - 44, 26
      font "monospace", 13, 600, 26, hCenter, vCenter
      fill "#e8ecf0"
      characters &"{value:02}"
    group idPrefix & "-inc":
      box w - 22, 0, 22, 26
      cornerRadius 4
      fill "#2a2f36"
      onHover: fill "#3a424d"
      onClick:
        setValue(if value >= maxV: minV else: value + 1)
      text idPrefix & "-inc-label":
        box 0, 0, 22, 26
        font "sans-serif", 14, 700, 26, hCenter, vCenter
        fill "#e8ecf0"
        characters "+"

proc toggleAlarm(cs: ClockState, id: int) =
  ## Szuka po `id`, nie po indeksie -- indeksy pętli `for i in 0 ..< len`
  ## przechwycone w zamknięciach `onClick` w Nimie dzielą tę samą zmienną
  ## między iteracjami; identyfikator skopiowany do `let a = ...` PRZED
  ## utworzeniem zamknięcia jest bezpieczny, bo to już osobna wartość na
  ## iterację (ten sam wzorzec co `win.id` w `shell/taskbar.nim`).
  for j in 0 ..< cs.alarms.len:
    if cs.alarms[j].id == id:
      cs.alarms[j].enabled = not cs.alarms[j].enabled
      return

var alarmsScrollY: float32 = 0.0  ## przewinięcie listy alarmów, patrz `drawAlarmsList`

proc drawAlarmsList(cs: ClockState, x, y, w: float32) =
  text "alarms-title":
    box x, y, w, 20
    font "sans-serif", 12, 700, 20, hLeft, vCenter
    fill "#e8ecf0"
    characters "Alarmy"

  let listY = y + 24
  if cs.alarms.len == 0:
    text "alarms-empty":
      box x, listY, w, 20
      font "sans-serif", 11, 400, 20, hLeft, vCenter
      fill "#8a94a3"
      characters "Brak alarmów -- dodaj poniżej"
  else:
    ## Rozbudowa v0.1 ("Aurora" -- przewijanie): obszar listy ma teraz
    ## STAŁĄ wysokość (`ListAreaH`, mieści ok. 4 wiersze) niezależnie od
    ## liczby alarmów -- przy większej liczbie wpisów lista się PRZEWIJA
    ## (kółkiem myszy) zamiast rosnąć w nieskończoność i nachodzić na
    ## kreator nowego alarmu / minutnik poniżej. Ten sam sprawdzony
    ## wzorzec `clipContent` + `onHover`/`mouse.wheelDelta` co lista
    ## plików w `apps/filemanager/files.nim`.
    const ListAreaH = 130.0'f32
    let contentH = float32(cs.alarms.len) * 32.0'f32
    let maxScroll = max(0.0'f32, contentH - ListAreaH)
    alarmsScrollY = clamp(alarmsScrollY, 0.0'f32, maxScroll)

    group "alarms-list-area":
      box x, listY, w, ListAreaH
      clipContent true
      onHover:
        if mouse.wheelDelta != 0:
          alarmsScrollY = clamp(alarmsScrollY - mouse.wheelDelta * 32.0'f32, 0.0'f32, maxScroll)

      var ry = -alarmsScrollY
      for a in cs.alarms:
        group "alarm-row-" & $a.id:
          box 0, ry, w, 28
          cornerRadius 4
          fill "#1b2027"

          # przełącznik włącz/wyłącz -- kropka zmieniająca kolor, klik zmienia stan
          group "alarm-toggle-" & $a.id:
            box 6, 4, 20, 20
            cornerRadius 10
            fill (if a.enabled: "#5fd7a7" else: "#3a4148")
            onClick:
              toggleAlarm(cs, a.id)

          text "alarm-time-" & $a.id:
            box 34, 0, 60, 28
            font "monospace", 13, 600, 28, hLeft, vCenter
            fill (if a.enabled: "#e8ecf0" else: "#767c85")
            characters &"{a.hour:02}:{a.minute:02}"

          text "alarm-label-" & $a.id:
            box 98, 0, w - 98 - 30, 28
            font "sans-serif", 11, 400, 28, hLeft, vCenter
            fill (if a.enabled: "#aeb6c2" else: "#5b6470")
            characters (if a.label.len > 0: a.label else: "Alarm")

          group "alarm-del-" & $a.id:
            box w - 24, 4, 20, 20
            cornerRadius 4
            fill "#000000", 0.0
            onHover: fill "#3a2323"
            onClick:
              cs.alarms.keepItIf(it.id != a.id)
            text "alarm-del-label-" & $a.id:
              box 0, 0, 20, 20
              font "sans-serif", 13, 600, 20, hCenter, vCenter
              fill "#c96a6a"
              characters "×"
        ry += 32

  ## Kreator nowego alarmu jest teraz zawsze w TYM SAMYM miejscu
  ## (`listY + ListAreaH`, gdy są jakieś alarmy -- niezależnie od tego,
  ## ile ich jest, bo obszar listy ma stałą wysokość powyżej), zamiast
  ## przesuwać się w dół z każdym kolejnym alarmem.
  var ry = listY + (if cs.alarms.len == 0: 24.0'f32 else: 130.0'f32)

  # -- kreator nowego alarmu -------------------------------------------------
  ry += 6
  group "alarm-new":
    box x, ry, w, 62
    drawStepper("new-hour", 0, 3, 74, cs.newHour, 0, 23, proc(v: int) = cs.newHour = v)
    text "new-sep":
      box 76, 3, 14, 26
      font "sans-serif", 14, 700, 26, hCenter, vCenter
      fill "#8a94a3"
      characters ":"
    drawStepper("new-minute", 92, 3, 74, cs.newMinute, 0, 59, proc(v: int) = cs.newMinute = v)

    group "alarm-add-btn":
      box 172, 3, w - 172, 26
      cornerRadius 4
      fill "#2d5f8a"
      onHover: fill "#3a72a3"
      onClick:
        let sounds = availableAlarmSounds()
        let chosenSound = if cs.newSoundIdx >= 0 and cs.newSoundIdx < sounds.len:
                            sounds[cs.newSoundIdx]
                          else: ""
        cs.alarms.add(AlarmEntry(
          id: cs.nextAlarmId, hour: cs.newHour, minute: cs.newMinute,
          label: "Alarm", enabled: true, lastFiredMinuteOfDay: -1,
          soundPath: chosenSound,
        ))
        inc cs.nextAlarmId
      text "alarm-add-label":
        box 0, 0, w - 172, 26
        font "sans-serif", 11, 700, 26, hCenter, vCenter
        fill "#ffffff"
        characters "+ Dodaj alarm"

    ## Rozbudowa (wybór dźwięku alarmu): picker pod wierszem
    ## godzina/minuta/dodaj -- pojedynczy przycisk, klik CYKLUJE po
    ## kolejnych dostępnych dźwiękach (`availableAlarmSounds()`), z
    ## "Auto" jako pierwszą, domyślną pozycją (`-1`). Świadomie prosty
    ## widget (jeden przycisk zamiast rozwijanej listy) -- Fidget nie ma
    ## natywnego combo boxa, a lista dźwięków jest krótka (co najwyżej
    ## `CandidateSounds.len` + 1 pozycji), więc cykliczne "kliknij, żeby
    ## przejść dalej" jest w pełni wystarczające, ten sam duch co
    ## `drawStepper` obok.
    let sounds = availableAlarmSounds()
    group "alarm-sound-picker":
      box 0, 34, w, 24
      cornerRadius 4
      fill "#20262d"
      onHover: fill "#262d35"
      onClick:
        if sounds.len > 0:
          cs.newSoundIdx = (cs.newSoundIdx + 2) mod (sounds.len + 1) - 1
          ## `+2` zamiast `+1` przed `mod (len+1)`, żeby uniknąć ujemnego
          ## wyniku operatora `mod` w Nimie dla `-1 mod n` (Nim, jak C,
          ## daje wynik o znaku DZIELNEJ, nie zawsze nieujemny) -- prościej
          ## przesunąć zakres o +1 PRZED `mod`, policzyć w dodatnim
          ## zakresie `0..len`, a dopiero potem odjąć 1 z powrotem, niż
          ## dorzucać osobną gałąź `if`/`else` tylko dla jednego progu.
      text "alarm-sound-label":
        box 8, 0, w - 16, 24
        font "sans-serif", 10, 600, 24, hLeft, vCenter
        fill (if sounds.len == 0: "#5b6470" else: "#aeb6c2")
        characters "🔔 " & (
          if sounds.len == 0: "Auto (brak dźwięków w systemie)"
          elif cs.newSoundIdx < 0: "Auto"
          else: soundLabel(sounds[cs.newSoundIdx]))

proc formatDuration(totalSec: int): string =
  let m = totalSec div 60
  let s = totalSec mod 60
  &"{m:02}:{s:02}"

proc drawTimerSection(cs: ClockState, x, y, w: float32) =
  text "timer-title":
    box x, y, w, 20
    font "sans-serif", 12, 700, 20, hLeft, vCenter
    fill "#e8ecf0"
    characters "Minutnik"

  text "timer-display":
    box x, y + 22, w, 40
    font "monospace", 30, 700, 40, hCenter, vCenter
    fill (if cs.timerPhase == timerDone: "#e5666b" else: "#e8ecf0")
    characters formatDuration(cs.timerRemainingSec)

  ## Rozbudowa v0.2 (wybór dźwięku minutnika): ten sam widget co
  ## "alarm-sound-picker" w `drawAlarmsList` -- pojedynczy przycisk,
  ## klik CYKLUJE po kolejnych dostępnych dźwiękach, "Auto" jako
  ## pierwsza pozycja (`-1`). Zawsze widoczny (nie tylko gdy
  ## `timerIdle`/`timerDone`) -- zmiana dźwięku w trakcie odliczania jest
  ## nieszkodliwa (dźwięk gra dopiero na końcu), więc nie ma powodu, żeby
  ## chować picker akurat wtedy.
  let sounds = availableAlarmSounds()
  group "timer-sound-picker":
    box x, y + 64, w, 18
    cornerRadius 4
    fill "#20262d"
    onHover: fill "#262d35"
    onClick:
      if sounds.len > 0:
        cs.timerSoundIdx = (cs.timerSoundIdx + 2) mod (sounds.len + 1) - 1
    text "timer-sound-label":
      box 8, 0, w - 16, 18
      font "sans-serif", 9, 600, 18, hLeft, vCenter
      fill (if sounds.len == 0: "#5b6470" else: "#aeb6c2")
      characters "🔔 " & (
        if sounds.len == 0: "Auto (brak dźwięków w systemie)"
        elif cs.timerSoundIdx < 0: "Auto"
        else: soundLabel(sounds[cs.timerSoundIdx]))

  let controlsY = y + 86
  case cs.timerPhase
  of timerIdle, timerDone:
    # presety czasu (widoczne tylko, gdy minutnik nie chodzi) + start
    var px = x
    for presetMin in [1, 5, 10, 15]:
      group "timer-preset-" & $presetMin:
        box px, controlsY, 44, 24
        cornerRadius 4
        fill "#2a2f36"
        onHover: fill "#3a424d"
        onClick:
          cs.timerTotalSec = presetMin * 60
          cs.timerRemainingSec = cs.timerTotalSec
          cs.timerPhase = timerIdle
        text "timer-preset-label-" & $presetMin:
          box 0, 0, 44, 24
          font "sans-serif", 11, 600, 24, hCenter, vCenter
          fill "#e8ecf0"
          characters $presetMin & "m"
      px += 48

    group "timer-start":
      box px + 4, controlsY, w - (px + 4 - x), 24
      cornerRadius 4
      fill "#2d8a5f"
      onHover: fill "#37a373"
      onClick:
        cs.timerRemainingSec = cs.timerTotalSec
        cs.timerPhase = timerRunning
      text "timer-start-label":
        box 0, 0, w - (px + 4 - x), 24
        font "sans-serif", 11, 700, 24, hCenter, vCenter
        fill "#ffffff"
        characters "Start"

  of timerRunning, timerPaused:
    group "timer-pause":
      box x, controlsY, w / 2 - 4, 24
      cornerRadius 4
      fill "#2a2f36"
      onHover: fill "#3a424d"
      onClick:
        cs.timerPhase = (if cs.timerPhase == timerRunning: timerPaused else: timerRunning)
      text "timer-pause-label":
        box 0, 0, w / 2 - 4, 24
        font "sans-serif", 11, 700, 24, hCenter, vCenter
        fill "#e8ecf0"
        characters (if cs.timerPhase == timerRunning: "Pauza" else: "Wznów")

    group "timer-reset":
      box x + w / 2 + 4, controlsY, w / 2 - 4, 24
      cornerRadius 4
      fill "#2a2f36"
      onHover: fill "#3a424d"
      onClick:
        cs.timerPhase = timerIdle
        cs.timerRemainingSec = cs.timerTotalSec
      text "timer-reset-label":
        box 0, 0, w / 2 - 4, 24
        font "sans-serif", 11, 700, 24, hCenter, vCenter
        fill "#e8ecf0"
        characters "Reset"

proc drawAlarmsTab(cs: ClockState, win: ZdeWindow, topOffset: float32) =
  let pad = 14.0'f32
  let w = win.size.x - pad * 2
  drawAlarmsList(cs, pad, topOffset + pad, w)
  # Minutnik na dole zakładki -- stała pozycja liczona od dołu okna, żeby
  # nie nachodził na zmienną liczbę wierszy alarmów powyżej (lista alarmów
  # w v0.1 nie przewija się -- przy wielu alarmach obcina się wizualnie,
  # co jest akceptowalnym ograniczeniem dla małego okna 320px).
  drawTimerSection(cs, pad, win.size.y - 132, w)

proc drawClock*(cs: ClockState, win: ZdeWindow) =
  frame "clock-root":
    box 0, 0, win.size.x, win.size.y
    fill "#12161c"

    drawTabBar(cs, win.size.x)

    case cs.tab
    of tabDial: drawDialTab(win, TabBarH)
    of tabAlarms: drawAlarmsTab(cs, win, TabBarH)
