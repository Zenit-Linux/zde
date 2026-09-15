# ZDE -- Zenit Desktop Environment

Środowisko graficzne dla Zenit Linux, napisane w Nimie (+ Fidget do UI).
Stack:

- **`zde-comp`** -- kompozytor Wayland + XWayland (Nim FFI → libwlroots,
  API oparte o `wlr_output_state`). Cały kod (backend/output/xdg-shell/
  layer-shell/wejście/schowek/XWayland/sesja-VT) był realnie skompilowany
  i zweryfikowany wobec prawdziwych nagłówków wlroots -- pierwotnie 0.18 i
  0.20, a w rundzie rozbudowy "Aurora"/XWayland dodatkowo wobec 0.17.1
  (Ubuntu 24.04): zainstalowano `libwlroots-dev` w piaskownicy, `zde-comp`
  skompilował się i wystartował, postawiono pod nim zagnieżdżony Xvfb,
  uruchomiono prawdziwe okno X11 (`xclock`) i zweryfikowano w logu
  poprawną sekwencję `new_surface -> associate` z odczytanym tytułem okna.
  Jedyna poprawka, jakiej to wymagało: brakujący `import std/sequtils` w
  `wlcomp/xwayland.nim` (błąd Nim, nie API wlroots). Nie przetestowano
  jeszcze pełnego renderowania klatek przez GPU (headless Xvfb w
  piaskownicy nie ma sprzętowego OpenGL) ani wobec wlroots 0.18/0.20 --
  ale sama poprawność API (nazwy pól/sygnałów, sygnatury funkcji) jest
  teraz potwierdzona kompilacją, nie tylko pamięcią. To jest *serwer* --
  odpowiednik Xorg/Sway/Muttera. Uruchamia się jako pierwszy, z TTY.
- **`zde-shell`** -- pasek zadań / launcher / chrome okien (Fidget). To
  *klient* Wayland, łączy się z socketem, który wystawia `zde-comp`.
  Skompilowany, uruchomiony pod Xvfb i zweryfikowany realnymi zrzutami
  ekranu + symulowanymi kliknięciami (`xdotool`) -- patrz sekcja
  "Nowości" niżej po listę pięciu błędów renderowania, które to znalazło
  i naprawiło (dok był niewidoczny, wskazówki zegara niewidoczne, itd.).
- `apps/terminal`, `apps/filemanager`, `apps/clock`, `apps/texteditor`,
  `apps/calculator`, `apps/sysmonitor` -- wbudowane aplikacje shellu.
- `comp/` -- logika okien używana przez `zde-shell`, rozbita na kilka plików
  (nie mylić z `wlcomp/` -- to osobna, dużo niższopoziomowa warstwa: prawdziwy kompozytor).

### Struktura plików

```
wlcomp/            -- zde-comp (kompozytor)
  types.nim           wspólne typy: Server/Output/Toplevel/Keyboard
  output.nim          wyjścia (monitory): init, klatki, odłączanie
  toplevel.nim        okna xdg-shell + XWayland: focus, move/resize,
                       hit-testing (uogólnione przez surfaceOf/geometryOf,
                       patrz "Nowości" niżej), Alt+Tab (cycleToPreviousToplevel)
  xwayland.nim        okna X11 (Xwayland): new_surface/associate/map/
                       unmap/destroy -- patrz "Nowości" niżej
  session.nim         sesja logind/seatd + przełączanie VT (Ctrl+Alt+F1-12)
                       -- patrz "Nowości" niżej
  idle.nim            DPMS (wygaszanie wyjść po bezczynności) + protokół
                       ext-idle-notify-v1 -- patrz "Nowości" niżej
  gestures.nim        gesty touchpada (swipe 3-palcowy) -- patrz "Nowości" niżej
  input.nim           klawiatura + kursor/mysz
  main.nim            tylko inicjalizacja i spięcie sygnałów
  wlroots.nim         bindingi FFI do libwlroots/wayland-server
  shim.c/.h           C glue dla funkcji `static inline` z wayland-server

shell/              -- zde-shell (pasek/launcher/chrome okien)
  state.nim           stan globalny (compositor, zegar, rejestry terminali/
                       monitora systemu/zegarów do odpytywania w tle) +
                       paleta kolorów "Aurora" (patrz "Nowości" niżej)
  waylandlink.nim      linkowanie protokołów Wayland przy -d:wayland (patrz niżej)
  wallpaper.nim        tło pulpitu -- gradient + poświata (Aurora), albo obraz z pliku
  chrome.nim           pasek tytułu / obramowanie / przyciski okna (Aurora)
  taskbar.nim          pływający dok + launcher z wyszukiwarką (Aurora)
  launcher_apps.nim    uruchamianie poszczególnych aplikacji z launchera
  desktopapps.nim      skanowanie/uruchamianie PRAWDZIWYCH aplikacji
                       systemowych (.desktop, XDG) -- patrz "Nowości" niżej
  notifications.nim    system powiadomień (toasty) -- patrz "Nowości" niżej
  quicksettings.nim    głośność/jasność (best-effort, zewn. narzędzia) --
                       patrz "Nowości" niżej
  sound.nim            dźwięk alarmu (best-effort) -- patrz "Nowości" niżej
  shell.nim            główna pętla rysowania + start

comp/                -- silnik okien używany przez zde-shell (focus/z-order/drag)
  types.nim            wspólne typy: ZdeWindow, Compositor, DragState
  window.nim           cykl życia okien: tworzenie/zamykanie, focus, z-order
  drag.nim             przeciąganie/zmiana rozmiaru myszą
  comp.nim             fasada re-eksportująca powyższe (import bez zmian)
apps/                -- aplikacje uruchamiane z launchera
  terminal/            terminal (bash przez potoki, bez pty)
  filemanager/         menedżer plików (nawigacja, tworzenie/zmiana nazwy/usuwanie, otwieranie w edytorze)
  clock/               zegar analogowy + cyfrowy + data, zakładka alarmów i minutnika
  texteditor/          prosty edytor plików tekstowych
  calculator/          kalkulator (siatka przycisków, prosty automat stanu)
  sysmonitor/          monitor systemu -- realne CPU/RAM z /proc, wykres historii
```

`shell/wlprotocol/` (nagłówki+źródła protokołów Wayland dla `waylandlink.nim`,
wygenerowane przez `wayland-scanner`) i `wlcomp/protocol/` to wygenerowane
artefakty budowania -- nie są wersjonowane w repo, `build.janet` tworzy je
przy każdym uruchomieniu.

## Budowanie

**`build.janet` samo wykrywa i instaluje brakujące zależności systemowe** --
nie musisz już ręcznie szukać nazwy pakietu (`apt-cache search libwlroots`
itp.) ani odgadywać, czy Twoja dystrybucja nazywa go `libwlroots-dev` czy
`libwlroots-0.20-dev`. Obsługiwane menedżery pakietów: **apt**
(Debian/Ubuntu), **dnf** (Fedora/RHEL), **pacman** (Arch), **zypper**
(openSUSE), **apk** (Alpine). Przy pierwszym uruchomieniu `janet
build.janet` samo:

1. wykryje Twoją dystrybucję i menedżer pakietów,
2. sprawdzi każdą zależność (`nim`, `gcc`, `wayland-scanner`,
   `wlroots >= 0.18`, `wayland-server`, `xkbcommon`, ...),
3. dla brakujących -- **dla wlroots dodatkowo przeszuka dostępne pakiety**
   (odpowiednik ręcznego `apt-cache search` + wybrania najnowszej
   wersjonowanej nazwy) -- i **zapyta o zgodę** przed jakąkolwiek instalacją
   wymagającą uprawnień administratora (użyje `sudo`, jeśli nie jesteś
   rootem),
4. zainstaluje i sprawdzi jeszcze raz, zanim przejdzie dalej.

**Osobno, przed budowaniem `zde-shell`, `build.janet` sprawdza też paczki
nimble** (Fidget i całe jego drzewo zależności: pixie, typography,
staticglfw, opengl, ...) -- jeśli którejś brakuje, samo odpala `nimble
install -y` (to czyta `zde.nimble` z bieżącego katalogu, więc uwzględni
przypięte tam wersje). Nie musisz już ręcznie pamiętać o `nimble install`
przed pierwszym budowaniem.

Do automatyzacji (np. CI, obrazy Dockera) ustaw `ZDE_ASSUME_YES=1` w
środowisku, żeby pominąć pytania:

```bash
ZDE_ASSUME_YES=1 janet build.janet
```

**Wymagana wersja wlroots: >= 0.18.** `zde-comp` używa API opartego o
`wlr_output_state` (`wlr_output_state_init`/`set_mode`/`set_enabled` +
`wlr_output_commit_state`), które zastąpiło starsze
`wlr_output_set_mode`/`wlr_output_enable`/`wlr_output_commit` w wlroots
0.18. Ubuntu 24.04 (noble) ma tylko wlroots 0.17 w apt -- na niej `zde-comp`
**się nie zbuduje** (auto-instalacja i tak zainstaluje to, co dostępne w
Twoich repozytoriach -- jeśli to za stara wersja, kompilacja zde-comp
zgłosi to jasnym błędem C, nie czymś tajemniczym). Sprawdź swoją wersję:
`pkg-config --modversion wlroots` (albo `wlroots-0.XX`). Ubuntu 24.10+
(oracular/plucky/questing) i Debian testing/sid mają wystarczająco nowe
wersje.

Jeśli wolisz zainstalować wszystko ręcznie z wyprzedzeniem zamiast polegać
na auto-instalacji (Ubuntu/Debian; nazwy pakietów w innych dystrybucjach
się różnią):

```bash
sudo apt install nim nimble gcc \
  libwlroots-dev wayland-protocols libwayland-bin \
  libxkbcommon-dev libinput-dev libgbm-dev libdrm-dev libseat-dev \
  libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libxxf86vm-dev \
  libglfw3-dev libgl1-mesa-dev fontconfig fonts-dejavu-core
```

**`zde-shell` wymaga zainstalowanego fontu** (dowolnego, byle był) --
używa `fontconfig` (`fc-match`) do znalezienia najlepszego dostępnego fontu
`sans-serif`/`monospace` w systemie, więc nie dołączamy własnych plików
`.ttf`. Jeśli zobaczysz błąd `nie znaleziono żadnego fontu` przy starcie,
zainstaluj `fontconfig` + dowolny font (np. `fonts-dejavu-core`) -- na
desktopowym Linuksie to i tak niemal zawsze już jest.

`build.janet` wymaga interpretera **Janet** (`sh: 1: janet: not found`, jeśli
go brakuje). Ubuntu/Debian nie mają go w apt -- zbuduj ze źródeł (mały
projekt w czystym C, ~1 minutę, dokładnie tak to zweryfikowałem):

```bash
git clone --depth 1 https://github.com/janet-lang/janet.git /tmp/janet-src
cd /tmp/janet-src && make -j"$(nproc)" && sudo make install
```

Sprawdź: `janet -v` powinno wypisać numer wersji. Potem wróć do katalogu
projektu i buduj dalej normalnie.

Potem jedna komenda:

```bash
janet build.janet          # buduje zde-comp + zde-shell (Wayland)
```

Warianty:

```bash
janet build.janet :x11         # zde-shell na X11/GLFW zamiast Wayland
janet build.janet :comp-only   # tylko kompozytor
janet build.janet :shell-only  # tylko shell
janet build.janet :clean       # czyści dist/
```

Odpowiedniki jako zadania nimble (te same kroki, tylko przez `nimble
<task>` zamiast bezpośrednio `janet ...`): `nimble buildAll`, `buildX11`,
`buildComp`, `buildShell`, `clean`.

**Nie masz/nie chcesz instalować Janeta?** `nimble buildShellDirect`
(albo wprost `nimble c -d:release -d:pixieNoSimd -o:dist/zde-shell
shell/shell.nim`) zbuduje sam `zde-shell` w wariancie X11, bez Janeta i
bez generowania nagłówków protokołów. To jedyne, co da się zbudować tą
drogą -- `zde-comp` i wariant Wayland i tak wymagają `wayland-scanner`
uruchamianego przez `build.janet`.

**Uwaga o zwykłym `nimble build`:** na niektórych świeżych/deweloperskich
wersjach nimble (m.in. tych z "vnext"/"declarative parser") `nimble build`
bez argumentów potrafi zgłosić `Error: Nothing to build`, mimo że `bin`
jest w `zde.nimble` ustawione -- to obserwowany kwirk tego parsera przy
błędzie parsowania plików `.nimble` zależności (zobaczysz wtedy wcześniej
ostrzeżenie `Declarative parser failed`). Jeśli to Twój przypadek, użyj
`nimble buildShellDirect` zamiast gołego `nimble build`.

Wynikowe binarki lądują w `dist/zde-comp` i `dist/zde-shell`.

### Uwaga o wersjach zależności nimble

`zde.nimble` wymaga `fidget >= 0.7.10` (nie `>= 0.7.9`!) -- to celowe: nimble
przy ograniczeniu `>=` domyślnie wybiera *najniższą* pasującą wersję, a
fidget 0.7.9 ciągnie za sobą pixie w wersji, która ma znany błąd pakowania
(`pixie/fileformats/png.nim` importuje moduł `crunchy`, którego
`pixie.nimble` nie deklaruje jako zależności -- `nimble build` wywala się
wtedy błędem `Error: cannot open file: crunchy`). Podniesienie dolnej
granicy do 0.7.10 (wymaga Nim >= 2.0) wymusza pociągnięcie nowszego pixie,
gdzie tego błędu nie ma; dodatkowo `crunchy` jest też wprost dopisany jako
zależność, na wszelki wypadek. Jeśli Twój Nim jest starszy niż 2.0, w
`zde.nimble` jest gotowy do odkomentowania blok z twardym przypięciem
starych wersji + `crunchy`.

**Ważne:** `nimble build` (bez argumentów) *próbuje* zbudować wariant X11
`zde-shell` (patrz `bin` w `zde.nimble`) -- ale jeśli zgłosi `Nothing to
build`, zobacz sekcję "Warianty" wyżej (`nimble buildShellDirect`). Pełny
zestaw (Wayland + `zde-comp`) buduj przez `nimble buildAll` albo wprost
`janet build.janet`.

## Uruchomienie

`zde-comp` to prawdziwy kompozytor -- **musi** działać z wirtualnego
terminala (TTY), nie z poziomu innej sesji graficznej (chyba że świadomie
testujesz go zagnieżdżonego pod innym Waylandem/X11 -- patrz niżej).

### Wariant A: z czystego TTY (docelowy sposób pracy)

1. Przełącz się na wolny TTY, np. `Ctrl+Alt+F3`, zaloguj się.
2. Upewnij się, że Twój użytkownik jest w grupach potrzebnych do dostępu
   do KMS/input bez roota:
   ```bash
   sudo usermod -aG video,input,seat $USER
   # wyloguj się i zaloguj ponownie, żeby grupy się zaktualizowały
   ```
3. `zde-comp` korzysta z `libseat`/`logind` do przejęcia sesji (poprzez
   `wlr_backend_autocreate`) -- upewnij się, że `systemd-logind` (albo
   `seatd`) działa:
   ```bash
   sudo systemctl status systemd-logind   # zwykle już działa
   # alternatywa bez systemd: sudo systemctl enable --now seatd
   ```
4. Uruchom:
   ```bash
   cd dist
   ./zde-comp
   ```
   Powinieneś zobaczyć w stderr coś w stylu:
   ```
   zde-comp: uruchomiony na WAYLAND_DISPLAY=wayland-1
   ```
5. **W drugim TTY** (`Ctrl+Alt+F4`), zaloguj się i uruchom shell, wskazując
   mu ten sam socket:
   ```bash
   WAYLAND_DISPLAY=wayland-1 dist/zde-shell
   ```
   (docelowo `zde-comp` powinien sam odpalać `zde-shell` jako swój
   "startup command" zamiast wymagać dwóch TTY -- patrz TODO niżej).

### Wariant B: zagnieżdżony, do szybkiego testowania (bez przełączania TTY)

Jeśli masz już działającą sesję Wayland (np. GNOME/Sway) albo X11, możesz
odpalić `zde-comp` jako *zwykłe okno* wewnątrz niej -- wlroots automatycznie
wykrywa, że działa zagnieżdżony, i użyje backendu Wayland-in-Wayland albo
X11-in-X11 zamiast prawdziwego DRM/KMS:

```bash
dist/zde-comp
# w drugim terminalu tej samej sesji:
WAYLAND_DISPLAY=wayland-1 dist/zde-shell
```

To najwygodniejszy sposób na rozwijanie/debugowanie ZDE bez ciągłego
przełączania TTY.

### Zmienne środowiskowe warte znajomości

- `WAYLAND_DISPLAY` -- nazwa socketu wystawionego przez `zde-comp`
  (`zde-comp` sam ją ustawia dla swoich dzieci, ale klienty startowane
  ręcznie w innym terminalu muszą ją dostać jawnie, jak wyżej).
- `WLR_BACKENDS` -- wymusza konkretny backend wlroots (`drm`, `wayland`,
  `x11`, `headless`) zamiast autodetekcji -- przydatne przy debugowaniu.
- `DISPLAY` -- po starcie XWaylanda `zde-comp` (a właściwie `wlr_xwayland`)
  sam wystawia gniazdo X11 i ustawia tę zmienną dla procesów, które
  odpali; stare aplikacje X11 uruchomione z `DISPLAY` ustawionym na tę
  wartość powinny działać przez XWayland bez zmian.

## Nowości tej rozbudowy -- "Znajdź i zamień" w edytorze tekstu

Domknięcie luki, którą poprzednia rozbudowa (patrz sekcja "Nowości tej
rozbudowy -- wyszukiwanie w edytorze tekstu" niżej) jawnie zostawiła
otwartą: samo wyszukiwanie już działało, ale bez żadnego sposobu na
zamianę znalezionego tekstu. Pasek "Znajdź" dostał drugi wiersz: pole
"zamień na..." plus przyciski "Zamień" (tylko aktualnie wycelowane
dopasowanie) i "Zamień wszystko".

- **"Zamień"** -- gdy nic nie jest jeszcze "wycelowane" (użytkownik nie
  kliknął wcześniej ◀/▶/Enter), traktuje to jak "przejdź do pierwszego
  dopasowania, a POTEM zamień", zamiast po prostu nic nie robić --
  bardziej przewidywalne niż wymaganie ręcznego kliknięcia strzałki
  najpierw.
- **"Zamień wszystko"** pracuje BEZPOŚREDNIO na całej treści dokumentu
  jako jednym stringu (bez żadnej konwersji linia/kolumna) -- prostsze i
  z automatu bezpieczne dla dowolnego stylu zakończeń linii, bo nigdy
  nie dzieli treści na linie ani jej z powrotem nie składa.

### Prawdziwy błąd, którego UNIKNĄŁEM dzięki testowaniu na realnych danych PRZED napisaniem kodu produkcyjnego

Zanim napisałem `doReplaceCurrent`, sprawdziłem w izolowanym teście, jak
Nim faktycznie zachowuje się przy typowym podejściu "podziel treść na
linie (`splitLines`), zmień jedną, złóż z powrotem (`join("\n")")" --
dokładnie tak, jak dane do wyszukiwania (`line`, `col`) są już liczone w
`computeFindMatches`. Okazało się, że dla plików z końcami linii w stylu
CRLF (`\r\n`, typowe dla plików zapisanych w Windows) taki round-trip
**cicho zamienia KAŻDE `\r\n` w całym pliku na samo `\n`** -- `splitLines`
"zjada" `\r\n` jako jeden separator, a `join("\n")` oddaje z powrotem
tylko `\n`. Efekt: pojedyncza, drobna zamiana tekstu przez użytkownika
cicho przekonwertowałaby styl końców linii CAŁEGO pliku, co przy
zapisaniu z powrotem na dysk pokazałoby się jako ogromny, niespodziewany
diff w systemie kontroli wersji -- dla zmiany jednego słowa.

Zamiast tego `lineColToOffset` liczy przesunięcie znakowe WPROST na
oryginalnym stringu (sprawdzając faktyczny znak/parę znaków napotkanych
po drodze), nigdy nie dzieląc i nie składając treści z powrotem --
zweryfikowane wprost testem z prawdziwą zawartością CRLF, potwierdzającym
identyczną liczbę `\r\n` przed i po zamianie. Dodatkowo `doReplaceCurrent`
ma wbudowaną "siatkę bezpieczeństwa": PRZED zamianą sprawdza, czy pod
obliczonym przesunięciem faktycznie JEST to, czego szukamy -- gdyby
jednak `lineColToOffset` się kiedyś pomyliło (np. przy nietypowych,
mieszanych zakończeniach linii), odmawia zamiany zamiast zaryzykować
nadpisanie niewłaściwego fragmentu pliku użytkownika.

Zweryfikowane w izolowanych, realnie skompilowanych i uruchomionych
programach Nim: podstawowa zamiana LF, zamiana z zachowaniem CRLF,
zamiana DRUGIEGO wystąpienia w tej samej linii (nie tylko pierwszego --
sprawdza, czy liczenie kolumny jest poprawne, nie tylko liczenie linii),
odmowa zamiany przy sztucznie wymuszonym błędnym przesunięciu, "Zamień
wszystko" z zachowaniem CRLF, oraz pełna symulacja przepływu UI (znajdź
-> zamień jedno -> przelicz -> zamień resztę), identyczna z tym, co
faktycznie robi kod w `onClick`.

## Nowości tej rozbudowy -- wyszukiwanie w edytorze tekstu

Zmiana kierunku po kilku rundach skupionych na menedżerze plików i
tapecie: `apps/texteditor/texteditor.nim` nie miało ŻADNEGO sposobu na
wyszukanie tekstu w dokumencie -- trzeba było przewijać ręcznie, nawet w
dużym pliku. Ctrl+F (albo przycisk 🔍 w toolbarze) otwiera teraz pasek
"Znajdź" z licznikiem wyników, nawigacją ◀/▶ i podświetleniem trafień.

- **Wyszukiwanie bez rozróżniania wielkości liter**, nieoverlapujące
  (podłańcuch "konsumuje" swoją długość przed szukaniem kolejnego, ten
  sam standard co wyszukiwanie w przeglądarce), przeliczane na nowo z
  całej treści dokumentu przy każdym renderowaniu paska -- ten sam
  poziom "wystarczająco dobre" co `drawHighlighted`, które retokenizuje
  widoczne linie na każdej klatce niezależnie od rozmiaru pliku (nie
  nowy kompromis wydajnościowy, spójny z tym, co już było).
- **Podświetlenie dopasowań** dorysowane POD tokenami podświetlania
  składni na widocznych liniach (aktualnie "wycelowane" trafienie
  dostaje wyraźnie wyższą nieprzezroczystość niż pozostałe) -- działa
  TYLKO w trybie podglądu (gdy pole edycji nie ma fokusu), bo w trybie
  aktywnej edycji Fidget pokazuje surowe pole tekstowe, nie tokeny.
- **Enter** = następne trafienie, **Shift+Enter** = poprzednie (ten sam
  gest co w przeglądarkach), **Escape** zamyka pasek.
- Ograniczenie, świadomie zaakceptowane: to NIE jest skok kursora w
  dokładne miejsce -- Fidget nie daje programowego dostępu do pozycji
  kursora w polu `editableText`/`multiline` (żadna część kodu w tym
  repo nigdzie tego nie robi), więc "przejdź do trafienia" oznacza
  "przewiń tak, żeby linia z trafieniem była blisko góry z odrobiną
  kontekstu nad nią", nie "postaw kursor na literze X w linii Y".
  Uczciwie nazwane w komentarzach jako uproszczenie, nie ukryte.
- Podobnie świadomie POZA zakresem: Ctrl+F nie ustawia fokusu na pole
  wyszukiwania automatycznie (tylko otwiera pasek) -- programowe
  ustawienie fokusu klawiatury spoza bloku danego widgetu nie jest
  gdzie indziej w tym repo robione, więc nie ryzykowałem zgadywania,
  jak to zrobić poprawnie w tym silniku; użytkownik klika w pole raz,
  tak jak przy każdym innym polu tekstowym w ZDE.

### Nowe pole `ZdeWindow.focused` -- skróty klawiszowe bez cyklu importów

Ctrl+F musiał wiedzieć, czy TO KONKRETNE okno edytora jest aktywne (bez
tego otwierałby pasek Znajdź we WSZYSTKICH otwartych oknach edytora
naraz). Zwykły sposób na to (`win.id == compositor.focusedId`, już
używany w `shell/chrome.nim` i -- inaczej niż tutaj, bez przeszkód -- w
`apps/filemanager/files.nim`) wymaga zaimportowania `shell/state.nim` po
`compositor`. Dla edytora tekstu to NIE JEST możliwe bez cyklu: to
WŁAŚNIE `shell/state.nim` importuje `apps/texteditor/texteditor.nim`
(do rejestru `texteditors`, patrz "wykrywanie zmian pliku na dysku" w
poprzednich rundach), więc `texteditor.nim` importujący `state.nim` z
powrotem zamknąłby pętlę.

Rozwiązanie: nowe pole `ZdeWindow.focused*` (`comp/types.nim`) -- niższy
poziom w hierarchii importów niż `state.nim`, więc dostępne wszędzie bez
ryzyka cyklu. Ustawiane RAZ na klatkę przez `drawWindowChrome`
(`shell/chrome.nim`, które i tak już liczyło `win.id ==
compositor.focusedId` na własny użytek -- podświetlenie ramki aktywnego
okna) TUŻ PRZED narysowaniem treści okna. `drawEditor` po prostu czyta
`win.focused` z argumentu, który i tak już dostaje -- zero nowych
zależności, zero cyklu. Ten sam mechanizm będzie mógł posłużyć
przyszłym skrótom klawiszowym w innych aplikacjach importowanych przez
`state.nim` (dziś: terminal, zegar, monitor systemu, edytor tekstu),
które miałyby ten sam problem.

### Prawdziwy błąd znaleziony i naprawiony podczas testowania

Pierwsza wersja `computeFindMatches` BEZWARUNKOWO zerowała
`findCurrentIdx` na końcu każdego przeliczenia. Ponieważ funkcja ta jest
wołana PRZY KAŻDYM RENDEROWANIU paska Znajdź (nie tylko przy zmianie
zapytania), to zerowanie cofałoby efekt kliknięcia "▶"/"◀"/Enter na
następnej samej klatce -- nawigacja między wynikami wizualnie w ogóle by
nie ruszyła z miejsca, licznik zawsze pokazywałby ten sam stan. Złapane
dopiero przy pisaniu testu SYMULUJĄCEGO wiele kolejnych klatek renderowania
(nie pojedyncze wywołanie) -- test z jednym wywołaniem by tego nie
wykrył, bo błąd ujawnia się dopiero przy PONOWNYM przeliczeniu po
nawigacji. Naprawione przez rozróżnienie "zapytanie faktycznie się
zmieniło" (nowe pole `findLastQuery`) od "to samo zapytanie, po prostu
kolejna klatka" -- indeks resetuje się tylko w tym pierwszym przypadku
(albo gdy przestał mieścić się w nowej, krótszej liście dopasowań).
Zweryfikowane w izolowanym, realnie skompilowanym i uruchomionym
programie Nim, symulującym dokładnie tę sekwencję: kliknięcie "dalej",
potem dziesięć kolejnych "klatek" przeliczenia bez żadnej innej zmiany
-- indeks poprawnie PRZETRWAŁ wszystkie, zamiast wracać do -1.

## Nowości tej rozbudowy -- sprzątanie cache'a tapety

Domknięcie luki, którą DWIE poprzednie rozbudowy z rzędu jawnie zostawiły
otwartą (patrz sekcje "tapeta z pliku obrazu" i "podgląd miniatury tapety"
niżej) -- każda zmiana tapety, zmiana rozdzielczości ekranu, a NAWET samo
przeglądanie kandydatów na tapetę w Ustawieniach (każda poprawna ścieżka
wpisana w pole podglądu generowała własny plik miniatury 160x90)
zostawiały nowy plik w `$XDG_CACHE_HOME/zde/` bez usuwania starych --
katalog cache mógł rosnąć bez końca.

`pruneWallpaperCache` (`shell/wallpaper.nim`), wołane automatycznie zaraz
po każdym udanym zapisie nowego pliku cache (nie na każdej klatce --
tylko wtedy, gdy faktycznie coś nowego przybyło), trzyma co najwyżej 12
najnowszych plików (wg czasu modyfikacji), usuwając resztę. Zamierzenie
jest CELOWO proste i "samoleczące się": usunięcie pliku, który akurat jest
w użyciu (np. bieżącej tapety, gdyby limit trafił akurat na nią przy
bardzo intensywnym przeglądaniu podglądów), niczego nie psuje --
`ensureWallpaperCache` po prostu wygeneruje go PONOWNIE przy następnym
potrzebnym wywołaniu, dopóki oryginalny plik źródłowy wciąż istnieje na
dysku (co nigdy nie jest zagrożone -- sprzątanie dotyka WYŁĄCZNIE plików
cache w `~/.cache`, nigdy oryginalnych zdjęć użytkownika).

Zweryfikowane w izolowanym, realnie skompilowanym i uruchomionym
programie Nim na prawdziwym systemie plików: 20 sztucznych plików cache o
rozstawionych w czasie znacznikach modyfikacji, przycięte do 12
najnowszych, z potwierdzeniem, że zostały faktycznie NAJNOWSZE (nie
przypadkowe), oraz że ponowne wywołanie przy liczbie już poniżej limitu
nic nie usuwa (no-op, nie błąd).

## Nowości tej rozbudowy -- podgląd miniatury tapety

Domknięcie luki, którą poprzednia rozbudowa (patrz sekcja "Nowości tej
rozbudowy -- tapeta z pliku obrazu" niżej) jawnie zostawiła otwartą na
liście ograniczeń: trzeba było kliknąć "Zastosuj" NA ŚLEPO, żeby w ogóle
zobaczyć, czy wpisana ścieżka wskazuje na coś sensownego.

Ustawienia -> Wygląd -> Tapeta pokazują teraz miniaturę 160x90 NA BIEŻĄCO,
w trakcie wpisywania ścieżki -- zanim użytkownik w ogóle kliknie
"Zastosuj". Zero duplikacji logiki: `ensureWallpaperCache`
(`shell/wallpaper.nim`) zostało po prostu wyeksportowane i wołane z
Ustawień z małym rozmiarem docelowym (160x90) zamiast rozmiaru ekranu --
ten sam algorytm "cover", te same zabezpieczenia przed uszkodzonymi
plikami, ten sam mechanizm cache'a co dla właściwej tapety. Klucz cache'a
zawiera docelowy rozmiar w nazwie pliku (patrz poprzednia sekcja), więc
miniatura 160x90 i pełnowymiarowa tapeta dla TEGO SAMEGO źródła trafiają
naturalnie w dwa różne pliki cache, bez wzajemnej kolizji -- zweryfikowane
wprost w izolowanym teście z prawdziwą Pixie (ten sam obraz źródłowy
przetworzony do obu rozmiarów naraz, oba pliki wyniku odczytane z powrotem
i sprawdzone co do wymiarów).

Trzy stany miniatury: pusta/szara ("Podgląd", gdy pole jeszcze puste),
faktyczny podgląd (gdy ścieżka wskazuje na plik, który Pixie potrafi
zdekodować), albo czerwony komunikat błędu ("Nie można odczytać obrazu",
gdy plik istnieje, ale jest w nieobsługiwanym/uszkodzonym formacie) --
ten trzeci stan to dokładnie ten sam sygnał, jaki i tak dostałoby się po
kliknięciu "Zastosuj", tylko wcześniej, bez dodatkowego kliku.

## Nowości tej rozbudowy -- tapeta z pliku obrazu

Pierwsza rozbudowa tej serii, która nie domyka punktu z listy ograniczeń,
tylko dokłada zupełnie nową możliwość: pulpit od zawsze pokazywał
wyłącznie wbudowany, syntetyczny gradient (`shell/wallpaper.nim`) --
zero sposobu na ustawienie własnego zdjęcia/obrazu jako tła, tak jak w
każdym innym środowisku graficznym. Ustawienia -> Wygląd dostały nową
sekcję "Tapeta": pole ze ścieżką do pliku + "Zastosuj"/"Domyślna".

- Wybrany obraz NIGDY nie trafia bezpośrednio do `image(...)` Fidget-a.
  Zamiast tego jest raz przetworzony przez Pixie (ten sam silnik, którego
  już używa `shell/desktopapps.nim` do ikon aplikacji) metodą **"cover"**
  -- przeskalowany i przycięty do DOKŁADNIE rozmiaru ekranu, bez
  zniekształcenia proporcji (ten sam algorytm co "Wypełnij ekran" w
  GNOME/KDE) -- i zapisany jako plik cache w `$XDG_CACHE_HOME/zde/`.
  Dwa powody: Fidget prawdopodobnie tylko rozciąga obraz do zadanego
  `box` bez zachowania proporcji (dowolne zdjęcie o innych proporcjach
  niż ekran wyglądałoby spłaszczone bez tego kroku), a poza tym to ten
  sam rodzaj ryzyka co przy ikonach aplikacji -- Pixie w tej wersji
  potrafi rzucić wyjątkiem przy pewnych plikach, którego NIC w pętli
  renderowania Fidget-a nie łapie, więc lepiej zdekodować obraz TU, w
  kodzie, który MY kontrolujemy, niż dowiedzieć się o awarii dopiero w
  trakcie rysowania klatki.
- **Cache bez osobnego stanu**: nazwa pliku cache koduje ścieżkę
  źródłową, jej czas modyfikacji ORAZ docelowy rozmiar ekranu (hash +
  wymiary w samej nazwie pliku) -- zmiana tapety, edycja pliku źródłowego
  na dysku, albo zmiana rozdzielczości ekranu każde z osobna dają inną
  nazwę pliku, więc stary cache po prostu przestaje być trafiany, bez
  żadnej logiki "unieważnij, jeśli...". Ten sam styl co
  `appDirsSignature` w `desktopapps.nim` -- policz z tego, co już jest na
  dysku, zamiast trzymać osobny stan w pamięci procesu.
- Nieudana próba (zły/uszkodzony plik, nieobsługiwany format) jest
  zapamiętywana per (ścieżka, rozmiar) -- kosztowna, skazana z góry na tę
  samą porażkę próba dekodowania nie powtarza się na każdej klatce
  (60x/s), tylko raz, po czym cicho spada do wbudowanego gradientu.
- Konfiguracja: nowe pole `wallpaperPath` w `zdeconfig.nim` (domyślnie
  `""` -- każda instalacja sprzed tej rozbudowy dostaje dokładnie dawne
  zachowanie bez żadnej zmiany) i nowa żywa zmienna `state.WallpaperPath`,
  mutowana przez Ustawienia na żywo -- ten sam, już wcześniej sprawdzony
  wzorzec co `AccentColor`.

### Jak to zweryfikowałem

Bez fidget/GLFW w tej sandboxie (jak zawsze -- wymagają Nim ≥2.0, dostępny
jest 1.6.14) nie dało się skompilować samego rysowania. UDAŁO się jednak
zainstalować i realnie wykorzystać samą Pixie -- pixie@4.4.0 (starsza,
kompatybilna z Nim 1.6.14 gałąź, bez zależności od `crunchy`) skompilowała
się i zadziałała z flagą `-d:pixieNoSimd` (ten sam, już wcześniej znany
projektowi wymóg -- patrz `buildShellDirect` w `zde.nimble`). Dzięki temu
algorytm "cover" i logika cache'a zostały przetestowane na PRAWDZIWEJ
bibliotece obrazów, nie na reimplementacji: syntetyczne zdjęcie zapisane
jako prawdziwy plik PNG na dysku, wczytane, przeskalowane/przycięte do
kilku różnych docelowych rozdzielczości (obraz szerszy niż ekran, węższy/
portretowy, ta sama proporcja, oraz proporcja powodująca zaokrąglenie przy
rzutowaniu na int -- wszystkie dały dokładnie oczekiwane wymiary wyniku),
zapisane i ponownie odczytane jako poprawny PNG, oraz osobno -- że
uszkodzony plik jest bezpiecznie odrzucany zamiast wywalać program. Cała
logika cache'a (generowanie, ponowne użycie bez regeneracji, inwalidacja
przy zmianie źródła/rozmiaru, brak powtarzania nieudanej próby) również
przetestowana w izolowanym programie z tą samą, prawdziwą Pixie.

## Nowości tej rozbudowy -- skróty klawiszowe w menedżerze plików

Do tej pory każda operacja w menedżerze plików wymagała myszy -- nawet
proste rzeczy jak usunięcie zaznaczenia czy zmiana nazwy. Ta rozbudowa
dokłada cztery skróty, które w każdym innym menedżerze plików są
podstawą obsługi z klawiatury:

- **Delete** -- ten sam mechanizm "uzbrojenia" co przycisk "Usuń" w
  pasku narzędzi: pierwsze naciśnięcie zbroi (przycisk w toolbarze
  pokazuje "Na pewno? (N)"), DRUGIE w ciągu 4 sekund faktycznie usuwa
  zaznaczenie. Wygaśnięcie uzbrojenia między naciśnięciami traktowane
  jest jak świeże, pierwsze naciśnięcie (ponowne uzbrojenie), nie jak
  wykonanie -- nieodwracalna operacja nigdy nie wykonuje się przez
  przypadek po zbyt wolnym drugim naciśnięciu.
- **Ctrl+A** -- zaznacza wszystko w bieżącym katalogu.
- **Escape** -- czyści zaznaczenie i anuluje "uzbrojone", ale
  niedokończone usuwanie (bez zamykania okna -- za to odpowiada osobno
  `shell/chrome.nim`).
- **F2** -- wchodzi w tryb zmiany nazwy, ale TYLKO gdy zaznaczony jest
  dokładnie jeden wpis (przy wielu zaznaczonych nic nie robi -- zmiana
  nazwy zawsze działa na jednym wpisie naraz, tak jak przy ikonie ✎).

Wszystkie cztery działają WYŁĄCZNIE gdy okno menedżera plików jest
aktywne (`win.id == compositor.focusedId`, ten sam sprawdzony sposób co
podświetlanie ramki w `shell/chrome.nim` -- bez tego np. Delete
skasowałoby zaznaczenie we WSZYSTKICH otwartych oknach menedżera naraz,
nie tylko w tym, na które faktycznie patrzy użytkownik) i tylko gdy
użytkownik nie jest akurat w trakcie wpisywania nazwy (zmiana nazwy albo
nowy folder) -- inaczej np. Delete kasowałoby zaznaczenie w trakcie
pisania nazwy nowego pliku, co byłoby mylące. Stałe klawiszy (`DELETE`,
`F2`, `LETTER_A`, `ESCAPE`) zweryfikowane względem rzeczywistego
źródła Fidget (sklonowanego z GitHuba na potrzeby tej rozbudowy), nie
zgadywane.

Zweryfikowane logicznie w izolowanym, realnie skompilowanym i
uruchomionym programie Nim: sekwencja "pierwsze Delete zbroi, drugie
wykonuje", F2 działające tylko przy dokładnie jednym zaznaczeniu, oraz
wygasłe uzbrojenie traktowane jak świeże naciśnięcie, nie jak
wykonanie.

## Nowości tej rozbudowy -- Shift+klik do zaznaczania zakresu

Domknięcie luki, którą poprzednia rozbudowa (patrz sekcja "Nowości tej
rozbudowy -- zaznaczanie wielu wpisów..." niżej) jawnie zostawiła
otwartą: Ctrl+klik do przełączania POJEDYNCZYCH wpisów już działał, ale
zaznaczenie 20 kolejnych plików wymagało 20 Ctrl+kliknięć. Teraz
**Shift+klik** zaznacza cały ciągły zakres jedną operacją -- dokładnie
tak jak w Nautilusie/Dolphinie/Eksploratorze Windows.

- `FilesState` dostał nowe pole `anchorName` -- "kotwicę" zakresu,
  ustawianą na KAŻDYM zwykłym kliknięciu (bez modyfikatorów). Shift+klik
  zaznacza wszystko między kotwicą a klikniętym wierszem WŁĄCZNIE
  (`fs.entries[lo..hi]` na BIEŻĄCEJ, posortowanej liście), zastępując
  dotychczasowe zaznaczenie -- kotwica przy tym NIE przesuwa się na
  kliknięty wiersz, więc kolejne Shift+kliknięcia poszerzają/zwężają
  zakres względem TEJ SAMEJ, pierwotnej kotwicy, a nie względem
  poprzedniego zakresu (dokładnie tak samo działa to w prawdziwych
  menedżerach plików).
- Brakująca/nieaktualna kotwica (np. jeszcze nic nie kliknięto zwykłym
  klikiem w tej sesji okna, albo wskazywała na coś usuniętego w
  międzyczasie) sprawia, że Shift+klik po prostu zachowuje się jak
  zwykły klik -- nowa kotwica ustawia się na kliknięty wiersz, zamiast
  wywalać się albo zaznaczać coś nieprzewidywalnego.
- Modyfikator odczytywany tym samym sprawdzonym sposobem co Ctrl+klik z
  poprzedniej rundy (`buttonDown[LEFT_SHIFT]`/`RIGHT_SHIFT`).

Zweryfikowane w izolowanym, realnie skompilowanym i uruchomionym
programie Nim: zakres w obie strony (kotwica przed i po kliknięciu),
kolejne Shift+kliknięcia względem tej samej kotwicy (nie względem
poprzedniego zakresu), Shift+klik na samej kotwicy, oraz zachowanie przy
nieaktualnej/brakującej kotwicy.

## Nowości tej rozbudowy -- zaznaczanie wielu wpisów w menedżerze plików

Kolejny punkt z listy ograniczeń: dało się już kopiować/wycinać/wklejać,
ale tylko PO JEDNYM wpisie naraz. `apps/filemanager/files.nim` dostał
Ctrl+klik do zaznaczania wielu wpisów jednocześnie:

- Zwykły klik na wierszu zastępuje całe zaznaczenie tym jednym wpisem
  (bez zmian względem wcześniejszego zachowania). **Ctrl+klik** PRZEŁĄCZA
  dany wpis w zaznaczeniu (dodaje, jeśli go tam nie było, usuwa, jeśli
  był) i -- w odróżnieniu od zwykłego kliknięcia -- nigdy nie nawiguje do
  katalogu ani nie otwiera pliku, nawet dla folderu: intencja
  Ctrl+kliknięcia to zawsze "zaznacz to też", nigdy "wejdź do środka".
  Modyfikator odczytywany przez `buttonDown[LEFT_CONTROL]`/
  `RIGHT_CONTROL`, ten sam sprawdzony sposób co w `shell/shortcuts.nim`
  (tam opisano, dlaczego `keyboard.ctrlKey` bywa zawodny).
- **Kopiuj**/**Wytnij**/**Wklej** (z poprzedniej rundy) oraz nowy przycisk
  **Usuń** w pasku narzędzi działają teraz na CAŁYM zaznaczeniu, nie
  tylko na jednym wpisie -- "Wklej" pokazuje liczbę w nawiasie, gdy jest
  więcej niż jeden element w schowku plików. "Usuń" (zbiorcze) używa
  tego samego mechanizmu "uzbrojenia" co ikona 🗑 przy pojedynczym
  wierszu (klik zbroi na 4 sekundy, drugi klik faktycznie usuwa) --
  osobne pole stanu (`pendingBulkDelete`), bo dotyczy WIELU wpisów
  naraz, nie jednego przy konkretnym wierszu.
- Zbiorcze operacje (usuwanie, wklejanie wielu) NIE przerywają się na
  pierwszym niepowodzeniu -- kontynuują resztę i melduje jedno zbiorcze
  podsumowanie na końcu ("Usunięto 3 wpisy", "Błąd: 1 z 4 się nie udało"),
  zamiast zalewać powiadomieniami po jednym na plik albo urwać w
  połowie przy pierwszym błędzie.

### Prawdziwy błąd znaleziony i naprawiony podczas testowania

Podczas pisania testu dla zbiorczego usuwania z jednym brakującym plikiem
(symulacja: coś usunięto z zewnątrz między odświeżeniem listy a
kliknięciem) test dał wynik NIEZGODNY z oczekiwaniem -- `os.removeFile`
w Nim, jak się okazało, **cicho nic nie robi dla nieistniejącego pliku,
zamiast rzucić `OSError`**. Bez jawnego sprawdzenia `fileExists`/
`dirExists` PRZED próbą usunięcia, `doDelete`/`doBulkDelete` zgłosiłyby
fałszywy sukces "Usunięto" dla czegoś, co już nie istniało -- blok
`except OSError` nigdy by się nie uruchomił, bo nic by go nie wywołało.
Naprawione dodaniem jawnego sprawdzenia istnienia przed każdą próbą
usunięcia, w obu procedurach. Zostawiam to tutaj opisane wprost, bo to
dokładnie ten rodzaj cichej nieścisłości, którą łatwo przeoczyć bez
faktycznego przetestowania na prawdziwym systemie plików -- a ta
rozbudowa, jak wszystkie poprzednie, jest testowana właśnie w ten sposób,
nie tylko czytana wzrokiem.

Reszta zweryfikowana tak samo jak zawsze w tej sandboxie: izolowane,
realnie skompilowane i uruchomione programy Nim -- logika przełączania
zaznaczenia (dodaj/usuń/zastąp), oraz zbiorcze kopiowanie/usuwanie
kilku plików i folderu naraz na prawdziwym systemie plików w katalogu
tymczasowym.

## Nowości tej rozbudowy -- kopiuj/wytnij/wklej w menedżerze plików

Domknięcie luki, którą poprzednia rozbudowa (patrz sekcja "Nowości tej
rozbudowy -- prawdziwe operacje na plikach..." niżej) świadomie zostawiła
otwartą: dało się już tworzyć foldery, zmieniać nazwy i usuwać, ale nie
dało się przenieść ani skopiować pliku/folderu MIĘDZY katalogami --
jedyny sposób to było ręczne przepisywanie w terminalu.

`apps/filemanager/files.nim` dostał "schowek plików" -- CELOWO osobny
byt od `shell/clipboard.nim` (schowka TEKSTOWEGO systemu, z poprzednich
rund): to inny rodzaj danych (bezwzględna ścieżka + flaga
kopiuj/przenieś), trzymany wyłącznie w pamięci JEDNEGO okna menedżera,
bez integracji z `wl_data_device` -- nie działa między dwoma otwartymi
oknami menedżera ani z zewnętrznymi aplikacjami. Prawdziwy schowek plików
w stylu GNOME/KDE wymagałby własnego typu MIME na poziomie kompozytora,
czego architektura ZDE dziś nigdzie nie robi -- świadomy kompromis, nie
przeoczenie (opisany też w liście ograniczeń niżej).

- **Kopiuj**/**Wytnij** (przyciski w pasku narzędzi, działają na już
  istniejącym zaznaczeniu z pojedynczego kliknięcia w wiersz) tylko
  zapamiętują źródło -- żadna operacja dyskowa nie dzieje się od razu,
  dokładnie jak Ctrl+C/Ctrl+X w każdym innym menedżerze.
- **Wklej** wykonuje faktyczną operację: `copyFile`/`copyDir` (rekurencyjnie
  dla folderów) dla kopiowania, `moveFile`/`moveDir` dla wycięcia.
  "Wytnij" jest jednorazowe -- schowek czyści się po wklejeniu; "Kopiuj"
  zostaje, więc to samo źródło można wkleić wielokrotnie w różne miejsca.
- **Kolizja nazw** przy wklejaniu (najczęściej: wklejenie z powrotem do
  TEGO SAMEGO katalogu, czyli zwykłe "zduplikuj") NIE pyta "nadpisać?"
  (nie mamy jak -- bez natywnego dialogu) ani nie failuje -- dokłada
  sufiks "(kopia)"/"(kopia 2)"/... aż trafi na wolną nazwę, ten sam
  mechanizm co "Zdjęcie (kopia).jpg" w Nautilusie/Dolphinie.
- **Zabezpieczenie przed rekurencją**: wklejenie folderu do samego siebie
  albo do jego własnego podkatalogu jest wykrywane i odrzucane z błędem
  PRZED próbą operacji na dysku -- bez tego `copyDir` wpadłby w
  nieskończoną rekurencję (kopiowanie tworzyłoby własny cel wewnątrz
  samo siebie).

Zweryfikowane w izolowanym, realnie skompilowanym i uruchomionym
programie Nim z prawdziwymi operacjami na systemie plików w katalogu
tymczasowym: kopiowanie pliku między katalogami, rekurencyjne
kopiowanie folderu (z zachowaniem oryginału), przenoszenie (cel znika ze
źródła), generowanie kolejnych sufiksów "(kopia)"/"(kopia 2)" przy
powtórnym wklejaniu tej samej nazwy, oraz osobno -- po poprawieniu
błędnego założenia w PIERWSZEJ wersji testu -- zabezpieczenie przed
wklejeniem folderu do samego siebie/własnego potomka (odróżnione od w
pełni poprawnego przypadku wklejenia folderu do JEGO WŁASNEGO katalogu
nadrzędnego, co nie jest rekurencją i powinno działać).

## Nowości tej rozbudowy -- prawdziwe operacje na plikach, otwieranie plików, dźwięk zwykłych powiadomień

Największa runda od dawna, bo domyka trzy powiązane braki naraz:
`apps/filemanager` był do tej pory WYŁĄCZNIE przeglądarką (README już to
uczciwie nazywało "przeglądarką", nie "menedżerem") -- nawigacja po
katalogach działała, ale nie dało się utworzyć folderu, zmienić nazwy,
usunąć, ani nawet OTWORZYĆ pliku. Co więcej, `lastClickTime`/
`lastClickName` istniały w `FilesState` od dawna, najwyraźniej z myślą o
wykrywaniu podwójnego kliknięcia -- ale nigdy nie były faktycznie
odczytywane. Martwy kod, nie żadna ukryta funkcja.

### Otwieranie plików (podwójny klik)

Podwójny klik na pliku (dwa kliknięcia w tę samą nazwę w ciągu 0.4s --
`lastClickTime`/`lastClickName`, nareszcie wykorzystane) otwiera go w
edytorze tekstu. Wymagało to przekazania ścieżki startowej AŻ do
`launchTextEditor` (`shell/launcher_apps.nim`) -- `newEditorState`/
`newTab` (`apps/texteditor/texteditor.nim`) już wcześniej to wspierały,
brakowało tylko przekazania parametru z góry. `apps/filemanager/files.nim`
CELOWO nie importuje `launcher_apps.nim` wprost (uniknięcie cyklu -- to
WŁAŚNIE `launcher_apps.nim` importuje `files.nim`) -- zamiast tego
`FilesState` dostał nowe pole `openFile: proc(path: string) {.closure.}`,
które `launchFileManager` wypełnia domknięciem wołającym
`launchTextEditor`. Ten sam wzorzec "callback zapisany na stanie", co
`AppEntry.action`/`win.onClose` gdzie indziej w kodzie.

### Tworzenie folderu, zmiana nazwy, usuwanie

Bez żadnego natywnego dialogu (Fidget go nie ma):

- **Nowy folder**: przycisk w pasku narzędzi otwiera/zamyka wąski pasek
  kreatora pod breadcrumbem (pole tekstowe + "Utwórz"/"Anuluj").
- **Zmiana nazwy**: ikona ✎ przy wpisie zamienia jego wiersz w pole
  edytowalne (wypełnione bieżącą nazwą), z "✓"/"×" do zatwierdzenia/
  anulowania. Sprawdza kolizję nazw PRZED próbą (`fileExists`/
  `dirExists` na celu) -- błąd trafia i do `errorMsg` (widoczny w
  panelu), i do `notify(..., nkWarning)`.
- **Usuwanie**: ikona 🗑 to nieodwracalna operacja, więc dostała osobny
  mechanizm "uzbrojenia" zamiast zwykłego dialogu potwierdzenia (którego
  Fidget i tak nie ma) -- pierwszy klik zbroi (ikona robi się czerwona,
  zamienia się w "✔?"), DRUGI klik w ciągu 4 sekund faktycznie usuwa.
  Wygaśnięcie liczone leniwie przy renderze (`epochTime() -
  pendingDeleteAt`), bez osobnego tickera -- ten sam styl co `formatAgo`
  w `shell/notifications.nim`.

Wszystkie trzy operacje wołają teraz `notify(..., nkInfo)` przy sukcesie
i `notify(..., nkWarning)` przy błędzie -- pierwsze REALNE użycie tych
dwóch wariantów `NotifyKind` w całym kodzie (przedtem istniały w typie,
ale jedynym wywołującym `notify()` był zegar, zawsze z `nkAlarm`).

### Dźwięk zwykłych powiadomień (nie tylko alarmu)

Kolejny jawnie wymieniony brak: toasty (`nkInfo`/`nkWarning`) nie miały
żadnego dźwięku, tylko alarm zegara. `shell/sound.nim` dostał
`playNotifySound`/`playWarningSound` -- osobne, subtelniejsze dźwięki niż
alarm (`dialog-information.oga`/`dialog-warning.oga` z tego samego
motywu `sound-theme-freedesktop`, którego nazwy plików zweryfikowałem
względem RZECZYWISTEJ zawartości pakietu, nie zgadywałem), wołane
automatycznie z `notify()` w `shell/notifications.nim` -- ale NIE dla
`nkAlarm`, bo alarm/minutnik już wołają własny, wybrany przez
użytkownika dźwięk w miejscu, gdzie faktycznie odpalają (patrz sekcja
"Nowości tej rozbudowy -- wybór dźwięku alarmu" niżej) -- dublowanie
dałoby dwa nakładające się dźwięki na jedno zdarzenie. Odtwarzanie
dźwięku respektuje tryb "nie przeszkadzać" tak samo jak sam toast.

Zweryfikowane w izolowanych, realnie skompilowanych i uruchomionych
programach Nim -- tym razem z prawdziwymi operacjami na systemie plików
w katalogu tymczasowym (utworzenie folderu, zmiana nazwy pliku I
katalogu, ochrona przed nadpisaniem istniejącej nazwy, usunięcie), a
także logiki wykrywania podwójnego kliknięcia i wygasania uzbrojenia
usuwania z realistycznym opóźnieniem (`sleep`), nie sztucznie przesuniętym
czasem. Jak zawsze w tej sandboxie, całego `zde-shell` z Fidget/Pixie nie
dało się skompilować (wymagają Nim ≥2.0, dostępny jest 1.6.14).

## Nowości tej rozbudowy -- trwała historia schowka

Domknięcie luki, którą poprzednia rozbudowa (patrz sekcja "Nowości tej
rozbudowy -- historia schowka" niżej) świadomie zostawiła otwartą:
historia schowka żyła wyłącznie w pamięci procesu `zde-shell` -- restart
shellu czyścił ją bezpowrotnie, dokładnie tak jak historia powiadomień
PRZED analogiczną rozbudową opisaną w kolejnej sekcji niżej.

`shell/clipboard.nim` dostał dokładnie ten sam mechanizm co
`shell/notifications.nim`: `historyFilePath`/`saveHistoryToDisk`/
`loadHistoryFromDisk`, zapis do `$XDG_STATE_HOME/zde/clipboard.json`
(fallback `~/.local/state/zde/clipboard.json`) -- OSOBNY plik od
`notifications.json`, bo to koncepcyjnie inne dane (schowek vs
powiadomienia), a nie dlatego, że kod jest inny -- jest niemal identyczny,
tylko przepisany lokalnie (procedury `notifications.nim` są prywatne, nie
eksportowane, więc nie dało się ich po prostu zaimportować).
Zachowuje się tak samo jak przy powiadomieniach: zapis po każdej zmianie
(nowy wpis w `tickClipboard`, wyczyszczenie przez "Wyczyść" w panelu) jest
best-effort (nigdy nie wywala shellu przy braku uprawnień/pełnym dysku),
odczyt raz przy starcie modułu z cichym powrotem do pustej historii przy
braku/uszkodzeniu pliku.

Zweryfikowane w izolowanym, realnie skompilowanym i uruchomionym
programie Nim (pełny cykl: zapis kilku wpisów, odczyt z zachowaniem
kolejności "najnowszy pierwszy", wyczyszczenie i ponowny odczyt dający
pustą historię).

## Nowości tej rozbudowy -- wybór dźwięku alarmu

Kolejny punkt zdjęty z listy: alarmy zegara (`apps/clock/clockapp.nim`)
grały dotąd zawsze TEN SAM dźwięk -- pierwszy znaleziony kandydat
(`findAlarmSound` w `shell/sound.nim`), bez możliwości wyboru innego,
mimo że system często ma dostępnych kilka. Jawnie wymienione w README
jako brakujące ("wciąż bez wyboru dźwięku alarmu").

- `shell/sound.nim`: `availableAlarmSounds()` zwraca tylko te dźwięki z
  ustalonej listy kandydatów, które FAKTYCZNIE istnieją na danym
  systemie (przefiltrowane przez `fileExists`) -- picker w UI nigdy nie
  pozwoli wybrać czegoś, co i tak by nie zagrało. `soundLabel()` mapuje
  ścieżkę na czytelną nazwę ("Budzik", "Fanfary", "Dzwonek", "Sygnał
  (WAV)") zamiast pokazywać surową ścieżkę pliku.
- `playAlarmSound()` przyjmuje teraz opcjonalny parametr `soundPath` --
  pusty string (wartość domyślna, i to, co mają WSZYSTKIE alarmy
  utworzone przed tą rozbudową, bo Nim zeruje nowe pola `object` do ich
  wartości domyślnej) zachowuje dokładnie dawne zachowanie: "Auto",
  czyli pierwszy dostępny dźwięk.
- Nowe pole `AlarmEntry.soundPath` pamięta wybór DOKONANY PRZY TWORZENIU
  danego alarmu -- każdy alarm może grać innym dźwiękiem. W kreatorze
  nowego alarmu (`drawAlarmsList`) doszedł drugi wiersz: przycisk
  cyklujący po kolejnych dostępnych dźwiękach (klik = następny, z "Auto"
  jako pozycją wyjściową) -- prosty widget zamiast rozwijanej listy,
  bo Fidget nie ma natywnego combo boxa, a lista i tak jest krótka.
- Świadomie POZA zakresem tej rundy: zmiana dźwięku ISTNIEJĄCEGO już
  alarmu (dziś edytowalne przy tworzeniu, potem tylko włącz/wyłącz/usuń
  -- ten sam ograniczony poziom edycji, jaki alarmy miały już wcześniej
  dla godziny/etykiety) oraz osobny wybór dźwięku dla minutnika (zawsze
  gra "Auto" -- minutnik jest zawsze dokładnie jeden naraz, w
  przeciwieństwie do wielu alarmów, więc potrzeba rozróżniania dźwięków
  wydaje się tu mniejsza).
- Zweryfikowane logicznie w izolowanych, realnie skompilowanych i
  uruchomionych programach Nim (filtrowanie istniejących plików,
  mapowanie na etykiety, arytmetyka cyklowania -1..N-1 bez wpadania w
  ujemny wynik operatora `mod`) -- z tych samych powodów co poprzednie
  rundy, w tej sandboxie nie da się skompilować całego `zde-shell` z
  Fidget/Pixie (wymagają Nim ≥2.0).

## Nowości tej rozbudowy -- historia schowka (clipboard manager)

Nowa funkcja, nie tylko domknięcie istniejącego ograniczenia: **panel
historii schowka** (📋 w doku, obok dzwonka i quick settings) -- lista
ostatnio skopiowanych fragmentów tekstu z możliwością szybkiego powrotu
do dowolnego z nich, tak jak "clipboard manager"/"klipper" w
GNOME/KDE. Do tej pory `shell/clipboard.nim` dawał tylko jednorazowy
dostęp do BIEŻĄCEJ zawartości schowka -- coś skopiowanego wcześniej
znikało bezpowrotnie przy kolejnym kopiowaniu.

- `shell/clipboard.nim` (`tickClipboard`, wołane raz na sekundę z
  `tickMain()` w `shell.nim`, tym samym rytmem co zegar/monitor systemu)
  odpytuje bieżącą zawartość schowka systemowego (tym samym
  `wl-paste`/`xclip`, którego już używał `pasteFromClipboard`) i dopisuje
  ją do historii (do 20 wpisów, `MaxClipHistory`), gdy się zmieniła.
  Duplikat przenosi istniejący wpis na czoło listy zamiast go powielać
  (tak samo zachowują się GNOME/KDE).
- Nowy panel `drawClipboardHistory` w `shell/taskbar.nim` -- ten sam
  wizualny język i mechanizm przewijania co centrum powiadomień. Klik na
  wiersz kopiuje jego treść z powrotem do schowka systemowego i zamyka
  panel; przycisk "Wyczyść" czyści całą historię.
- Świadome kompromisy (ten sam poziom uczciwości co reszta dokumentu):
  to ODPYTYWANIE co sekundę, nie subskrypcja zdarzeń `wl_data_device`
  (opóźnienie do 1s, tak jak przy żywym odświeżaniu launchera -- patrz
  sekcja niżej), więc BEZ "primary selection" (środkowy klik w X11) i
  BEZ obrazów -- tylko czysty tekst. W TEJ rundzie historia żyła
  wyłącznie w pamięci procesu `zde-shell` (jak powiadomienia PRZED
  analogiczną rozbudową opisaną niżej) -- kolejna runda (patrz sekcja
  "Nowości tej rozbudowy -- trwała historia schowka" WYŻEJ, chronologicznie
  późniejsza niż ten akapit) domknęła i to, dokładnie tym samym wzorcem
  co `notifications.nim`.
- Zweryfikowane logicznie w izolowanym, realnie skompilowanym i
  uruchomionym programie Nim (dedup + przesunięcie na czoło, obcinanie
  do limitu, ignorowanie natychmiastowych duplikatów) -- z tych samych
  powodów co poprzednie rundy, w tej sandboxie nie da się skompilować
  całego `zde-shell` z Fidget/Pixie (wymagają Nim ≥2.0).

## Nowości tej rozbudowy -- ciągłe przeciąganie suwaków quick settings

Kolejny punkt zdjęty z listy świadomie odłożonych kompromisów: suwaki
głośności/jasności (`shell/taskbar.nim`, `drawSlider`) obsługiwały do tej
pory tylko "kliknij, żeby ustawić" -- samo przytrzymanie i przeciągnięcie
myszą nie aktualizowało wartości w locie, trzeba było klikać wielokrotnie
wzdłuż paska. Powód był czysto techniczny: `onMouseDown` w DSL-u Fidget to
zdarzenie WYZWALANE RAZ, na przejściu "przycisk wciśnięty" -- nie blok
wołany co klatkę, dopóki przycisk jest trzymany.

Rozwiązanie to dokładnie ten sam wzorzec, którego ZDE już używa do
przenoszenia/zmiany rozmiaru OKIEN (`comp/drag.nim` + globalny hook
`compositor.updateDrag` w `drawMain()`, `shell.nim`) -- tylko odtworzony
lokalnie dla suwaków, bez dotykania maszyny stanów przeciągania okien
(inny byt, inna skala: pojedynczy globalny stan wystarczy, bo naraz może
być przeciągany co najwyżej jeden suwak):

- `SliderDragState` (`shell/taskbar.nim`) pamięta, KTÓRY suwak jest
  przeciągany (przez przechowanie jego `setValue` jako domknięcia) oraz
  geometrię jego paska (`trackX`/`trackW`) -- zapisywane w `onMouseDown`
  w momencie wciśnięcia, DODATKOWO do dotychczasowego klik-ustaw (które
  zostaje bez zmian, więc pojedyncze kliknięcie dalej działa identycznie
  jak wcześniej).
- `updateSliderDrag()`, wołane co klatkę z `drawMain()` w `shell.nim`
  (obok analogicznego `compositor.updateDrag` dla okien) -- dopóki
  przycisk myszy jest trzymany i panel quick settings jest otwarty,
  przelicza wartość z bieżącej pozycji kursora WZGLĘDEM zapamiętanej
  geometrii paska. Kluczowe: liczy się względem zapamiętanej pozycji
  paska, NIE względem bieżącego trafienia w jego granice -- dokładnie
  tak samo jak przeciąganie okna za tytuł działa, nawet gdy kursor
  "wyjedzie" poza wąski 24px pasek przy szybkim ruchu myszy (naturalne
  przy przeciąganiu, patrz identyczne uzasadnienie przy `beginMove` w
  `comp/drag.nim`).
- Kończy się samo, gdy przycisk myszy zostanie puszczony ALBO panel
  quick settings zostanie w międzyczasie zamknięty (np. kliknięciem poza
  panelem) -- drugi warunek zapobiega sytuacji, w której przeciąganie
  "po cichu" dalej zmieniałoby głośność/jasność mimo zamkniętego panelu.
- Zweryfikowane logicznie w izolowanym programie Nim (symulacja pozycji
  kursora wewnątrz i POZA granicami paska, klamrowanie do 0-100, oraz
  zatrzymanie po puszczeniu przycisku) -- w tej sandboxie nie dało się
  skompilować całego `zde-shell` (patrz notatka metodologiczna na końcu
  tej sekcji dokumentu), więc integrację z realnym Fidget/GLFW trzeba
  będzie zweryfikować wizualnie w przyszłej rundzie, tak jak zrobiono to
  wcześniej dla reszty `shell/` (patrz sekcja "pierwsze prawdziwe testy
  wizualne" niżej).

## Nowości tej rozbudowy -- trwała historia powiadomień, żywe odświeżanie launchera

Ta runda domyka dwa punkty, które od dawna wisiały na liście "Ograniczenia"
niżej jako świadomie odłożone kompromisy -- oba bez potrzeby dokładania
nowej infrastruktury (wątków w tle, demonów, zależności) do `zde-shell`.

### Trwała historia powiadomień (`shell/notifications.nim`)

Do tej pory historia powiadomień (dzwonek w doku, do 30 wpisów) żyła
WYŁĄCZNIE w pamięci procesu `zde-shell` -- restart shellu (albo całej
sesji) czyścił ją bezpowrotnie. Teraz każde wywołanie `notify()` (i
`clearHistory()`) zapisuje bieżącą historię jako zwykły plik JSON:

- Ścieżka zgodna z XDG Base Directory Specification:
  `$XDG_STATE_HOME/zde/notifications.json`, a w braku tej zmiennej --
  `~/.local/state/zde/notifications.json`. To świadomie katalog *stanu*
  (`state`), nie *configu* (`config`) ani *cache* -- historia powiadomień
  nie jest ustawieniem użytkownika ani czymś bezpiecznym do usunięcia bez
  utraty informacji, więc żaden z tamtych katalogów nie pasował
  semantycznie.
- Wczytywana RAZ, przy starcie modułu (czyli starcie `zde-shell`) --
  `loadHistoryFromDisk()`. Brak pliku (pierwsze uruchomienie na danej
  maszynie) albo uszkodzona zawartość dają po prostu pustą historię,
  nigdy nie wywalają startu shellu.
- Zapis jest best-effort, tak jak reszta integracji ZDE z otoczeniem
  systemowym (`quicksettings.nim`, `sound.nim`, `desktopapps.nim`) --
  brak uprawnień do zapisu czy pełny dysk nie mają prawa wywrócić
  `zde-shell`, najwyżej historia zostaje nietrwała w danej sesji (dokładnie
  zachowanie sprzed tej rozbudowy).
- Świadomie POZA zakresem: to nie jest integracja z zewnętrznym,
  DBusowym `org.freedesktop.Notifications` (patrz duży komentarz na
  górze pliku) -- to wciąż wyłącznie wewnętrzny mechanizm ZDE, tylko już
  przeżywający restart.

### Żywe odświeżanie listy aplikacji systemowych w launcherze (`shell/desktopapps.nim`, `shell/taskbar.nim`)

Launcher skanował `.desktop` pliki RAZ, przy starcie `zde-shell` -- nowo
zainstalowany program pojawiał się dopiero po restarcie shellu. To był
jawnie wymieniony punkt na liście ograniczeń ("pełne śledzenie katalogów
przez `inotify` to możliwa przyszła rozbudowa").

Zamiast pełnego `inotify` (wymagałoby to trzymania osobnego deskryptora i
integracji z pętlą zdarzeń Fidget/GLFW, której dziś `zde-shell` nigdzie
nie robi -- cała reszta stanu w tym projekcie, patrz `state.nim`, jest
ODPYTYWANA raz na sekundę, nie subskrybowana) -- rozwiązanie trzyma się
istniejącej architektury:

- `desktopapps.appDirsSignature()` sumuje mtime katalogów z `AppDirs`,
  które faktycznie istnieją -- instalacja/usunięcie pliku `.desktop`
  zawsze dotyka mtime katalogu, który go zawiera, więc zmiana tej sumy
  jest niezawodnym (choć niegranularnym co do pojedynczego pliku)
  sygnałem "coś się tu ruszyło".
- `taskbar.rescanSystemAppsIfChanged()`, wołane raz na sekundę z
  `tickMain()` w `shell.nim` (ten sam rytm co zegar/monitor systemu/
  wykrywanie zmian pliku w edytorze) -- porównuje bieżącą sygnaturę z
  zapamiętaną i przebudowuje `SystemAppGroups` (teraz `var`, nie `let`)
  TYLKO gdy się różnią. W normalnej pracy (nic się nie zmieniło) to więc
  tylko garść tanich `stat()`, nie pełne, kosztowne parsowanie
  wszystkich `.desktop` plików w systemie co sekundę.
- Efekt: `apt install`/`apt remove` (albo dowolny inny menedżer pakietów)
  w trakcie działania sesji ZDE odzwierciedla się w launcherze z
  opóźnieniem rzędu jednej sekundy, bez restartu `zde-shell`.
- Wciąż aktualne ograniczenia z poprzednich rund: tylko ikony rastrowe
  (PNG), bez pełnej specyfikacji Icon Theme (dziedziczenie motywów).

## Nowości tej rozbudowy -- quick settings, dźwięk alarmu, wykrywanie zmian pliku

### Quick settings: głośność i jasność (`shell/quicksettings.nim`, nowy plik)

Nowa ikona 🔊 w doku otwiera panel z suwakami głośności i jasności ekranu.
Jak `shell/clipboard.nim`/`shell/desktopapps.nim` -- cienka, best-effort
warstwa nad zewnętrznymi narzędziami, NIE własny demon audio:

- Głośność: `wpctl` (PipeWire) → `pactl` (Pulse) → `amixer` (czyste ALSA),
  w tej kolejności, pierwszy znaleziony wygrywa.
- Jasność: `/sys/class/backlight/*` do odczytu, `brightnessctl` do zapisu
  (dba o uprawnienia -- bezpośredni zapis do sysfs jako zwykły
  użytkownik prawie zawsze się nie uda i jest tylko awaryjnym fallbackiem).
- **Sekcja, dla której nie znaleziono backendu, po prostu się nie
  pokazuje** -- zweryfikowane zrzutem ekranu: w piaskownicy bez karty
  dźwiękowej ani backlightu panel poprawnie pokazuje "Brak sterowania
  audio/jasnością na tym systemie" zamiast pustych/martwych suwaków.
  Po doinstalowaniu `alsa-utils` (`amixer`) -- bez prawdziwej karty
  dźwiękowej, więc `amixer` i tak zwraca błąd -- panel pokazuje realny
  suwak z wartością "0%" (bezpieczny fallback), reaguje na klik bez
  crasha.
- Własny suwak (`drawSlider`) -- Fidget nie ma widgetu suwaka: klik/
  kółko myszy nad paskiem, ten sam wzorzec `mouse.wheelDelta` co scroll
  list gdzie indziej w tym pliku. Od kolejnej rozbudowy (patrz sekcja
  "Nowości tej rozbudowy -- ciągłe przeciąganie suwaków" niżej) obsługuje
  też PRAWDZIWE przeciąganie, nie tylko klik-ustaw.

### Dźwięk alarmu (`shell/sound.nim`, nowy plik)

Alarm zegara i koniec minutnika (`apps/clock/clockapp.nim`) odtwarzają
teraz dźwięk, nie tylko toast wizualny -- best-effort przez pierwszy
znaleziony z `paplay`/`pw-play`/`ffplay`/`aplay` i pierwszy znaleziony
plik dźwiękowy z kilku standardowych lokalizacji
(`sound-theme-freedesktop`, `alsa-utils`). ZDE świadomie nie niesie
własnych plików dźwiękowych -- gdy nic nie znaleziono, po cichu nic się
nie odtwarza (alarm i tak budzi wizualnie).

### Wykrywanie zmian pliku na dysku w edytorze tekstu

`apps/texteditor/texteditor.nim` porównuje teraz co sekundę
(`checkExternalChanges`, rejestr `texteditors` w `shell/state.nim` --
ten sam wzorzec co `clocks`/`terminals`) czas modyfikacji otwartego
pliku z tym zapamiętanym przy ostatnim wczytaniu/zapisie. Gdy coś INNEGO
zmieniło plik pod nami (inny program, `git pull`, edycja w terminalu),
pokazuje się baner "Plik zmienił się na dysku" z przyciskami
"Przeładuj"/"Zignoruj".

## Nowości tej rozbudowy -- pulpity wirtualne (workspaces)

Cztery pulpity wirtualne, w pełni zaimplementowane w `comp/` (pole
`workspace` w `ZdeWindow`, `currentWorkspace` w `Compositor`,
`comp/window.nim`: `switchWorkspace`/`moveWindowToWorkspace`,
`WorkspaceCount = 4`):

- **Przełącznik w doku** (`shell/taskbar.nim`) -- cztery kwadraciki "1 2 3
  4", aktywny podświetlony akcentem, pozostałe dostają małą kropkę, gdy
  mają na sobie choć jedno okno (widać "gdzie coś zostało otwarte" bez
  przełączania).
- **Skróty klawiszowe**: `Ctrl+Alt+Right/Left` przełącza pulpit (zawija
  się, 4→1 i 1→4, jak karuzela Alt+Tab okien w `wlcomp/`),
  `Ctrl+Alt+Shift+Right/Left` przenosi AKTYWNE okno na sąsiedni pulpit i
  od razu na niego przełącza.
- **Pełna izolacja pulpitów**: okna z innych pulpitów nie są rysowane
  (`windowsInZOrder`), nie dostają fokusu (Alt+Tab/`cycleFocus` filtruje
  po pulpicie), nie pokazują się w doku (lista zadań filtruje po
  pulpicie) -- to nie jest kosmetyczne ukrywanie, okna z innych pulpitów
  są dla reszty shellu tak samo "niewidoczne" jak zminimalizowane.
- Nowe okna otwierają się zawsze na AKTUALNYM pulpicie.

Zweryfikowane zrzutami ekranu: otwarcie Zegara na pulpicie 1, przełączenie
na pulpit 2 -- okno i jego przycisk w doku znikają całkowicie, pulpit "1"
dostaje kropkę wskaźnika.

## Nowości tej rozbudowy -- filtr kategorii w launcherze

Na wyraźną prośbę: launcher dostał pasek "chipów" kategorii pod
wyszukiwarką ("Wszystkie" + jedna na każdą kategorię, która faktycznie ma
choć jedną aplikację -- puste filtry się nie pokazują). Kliknięcie
kategorii (np. "Biuro") zawęża listę TYLKO do niej -- z realnymi ikonami,
bez przewijania przez wszystko. Pasek chipów **zawija się do kolejnego
wiersza** samodzielnie, gdy nie mieści się w jednej linii (prosty,
własny algorytm zawijania -- Fidget nie ma API do mierzenia szerokości
tekstu przed narysowaniem, więc szerokość chipa jest przybliżona z
długości etykiety). Kolejność kategorii w pasku jest stała i "sensowna"
(Internet, Biuro, Grafika... zamiast alfabetycznej). Zweryfikowane
zrzutami ekranu: zawijanie do drugiego wiersza i filtrowanie do samego
LibreOffice po kliknięciu "Biuro" -- działa dokładnie tak jak powinno.

## Nowości tej rozbudowy -- snapowanie okien, scroll list, prawdziwe aplikacje systemowe

### Snapowanie okien (Super+Left/Right)

`comp/window.nim` (`snapWindow`, nowy typ `SnapEdge`) + skróty w
`shell/shortcuts.nim`. Przyciąga aktywne okno do połowy ekranu; drugie
Super+Left/Right na tej samej krawędzi przywraca oryginalny rozmiar
(zapamiętany w `savedPos`/`savedSize`, ten sam mechanizm co zwykła
maksymalizacja). Zweryfikowane zrzutami ekranu, łącznie z toggle "z
powrotem".

**Ważna notatka o metodologii testowania**, przydatna dla przyszłych
sesji: `xdotool key ctrl+alt+t` (skrót) najpierw wyglądał, jakby NIE
działał -- w rzeczywistości `xdotool key` wysyła całą kombinację za
szybko dla jednoklatkowego śledzenia modyfikatorów w Fidget. `xdotool
keydown`/`keyup` z realnym opóźnieniem (~0.3s) między nimi działa
niezawodnie. To nie był bug w kodzie.

### Przewijanie list (kółkiem myszy)

Centrum powiadomień, lista alarmów zegara i teraz też launcher -- każda
z tych list ma teraz GÓRNY LIMIT wysokości i przewija się zamiast rosnąć
w nieskończoność. Wzorzec (`clipContent true` + `onHover`/
`mouse.wheelDelta`, sprawdzony wcześniej w `apps/filemanager/files.nim`)
teraz powtórzony w trzech miejscach.

### Prawdziwe aplikacje systemowe w launcherze (`shell/desktopapps.nim`, nowy plik)

To była główna prośba tej rundy: launcher miał pokazywać nie tylko 7
wbudowanych aplikacji ZDE, ale też WSZYSTKO, co faktycznie jest
zainstalowane w systemie -- jak w KDE/GNOME, tylko lepiej zorganizowane.
Zaimplementowane:

- Skanowanie `.desktop` plików z `~/.local/share/applications`,
  `/usr/local/share/applications`, `/usr/share/applications` (standard
  XDG, ten sam mechanizm co w każdym "poważnym" DE).
- Parsowanie `Name`/`Exec`/`Icon`/`Categories`/`Terminal`/`NoDisplay`/
  `Hidden`/`Type` -- z pominięciem `Name[locale]=` (jedno pole `Name`),
  `[Desktop Action ...]` (podmenu akcji) i wpisów innych niż
  `Type=Application`.
- Grupowanie po kategorii XDG, zmapowanej na 9 własnych, przetłumaczonych
  grup (Internet, Biuro, Grafika, Multimedia, Programowanie, Gry,
  Edukacja, Narzędzia, System, Inne) -- każda z nagłówkiem w launcherze.
- Uruchamianie przez `osproc.startProcess` (odłączony proces, `%f`/`%F`/
  `%u`/`%U`/`%i`/`%c`/`%k` usuwane z linii poleceń -- launcher nie
  przekazuje żadnego konkretnego pliku/URL).
- **Prawdziwe ikony PNG** -- przeszukiwanie kilku najpopularniejszych
  lokalizacji motywów ikon (hicolor, Humanity, Adwaita, breeze,
  `/usr/share/pixmaps`), z ikoną zastępczą wg kategorii, gdy nic nie
  znaleziono.

**Realny crash znaleziony i naprawiony w trakcie testów pod Xvfb:**
Fidget renderuje `image(...)` przez Pixie, konwertując PNG do własnego
formatu cache (`.flippy`) PRZY KAŻDYM PIERWSZYM UŻYCIU -- a Pixie 5.0.1
nie obsługuje np. PNG 16-bit/kanał (realny format, spotkany od razu na
pierwszej ikonie ImageMagicka w tym systemie) i rzuca wyjątkiem, którego
NIC w całej bibliotece Fidget nie łapie (cała pętla renderowania nie ma
ani jednego `try`/`except`) -- **cały proces `zde-shell` umierał**, zanim
zdążył pokazać cokolwiek. Naprawione przez wstępną walidację: `desktopapps.nim`
(`isDecodablePng`) próbuje realnie zdekodować każdego kandydata na ikonę
W CZASIE SKANOWANIA (gdzie kontrolujemy obsługę wyjątków), i odrzuca (na
rzecz ikony zastępczej kategorii) każdy plik, którego się nie da --
zanim, nie w trakcie, rysowania klatki. Bez tego etapu testowania
wizualnego ten bug trafiłby prosto do repo.

**Ograniczenie, świadomie poza zakresem:** tylko ikony RASTROWE (PNG) --
ikony dostępne wyłącznie jako SVG (częste w nowszych motywach) dostają
ikonę zastępczą kategorii, bo Fidget/Pixie w tej wersji nie rasteryzuje
SVG przez zwykłe `image(...)`. Lista aplikacji jest skanowana przy
starcie `zde-shell` i od tej rozbudowy odświeżana też w tle -- patrz
sekcja "Nowości tej rozbudowy -- żywe odświeżanie launchera..." niżej --
ale wciąż z opóźnieniem rzędu sekundy, nie natychmiast klatka-po-klatce
(pełny `inotify` zamiast odpytywania mtime to możliwa przyszła
rozbudowa, patrz uzasadnienie tam).

## Nowości tej rozbudowy -- pierwsze prawdziwe testy wizualne `zde-shell`

Do tej pory `shell/` był rozwijany wyłącznie przez czytanie kodu i
ręczne śledzenie konwencji Fidget -- nigdy realnie uruchomiony ani
zobaczony. W tej rundzie udało się to zmienić: zainstalowano `nim` +
`fidget`/`pixie`/resztę zależności nimble w piaskownicy (z ręcznym
obejściem tego, że pakiet `html5_canvas` -- zależność `fidget` --
jest hostowany na zablokowanym `gitlab.com`: sklonowano oficjalny mirror
z GitHuba i doinstalowano ręcznie do `~/.nimble/pkgs/`), skompilowano
`zde-shell`, uruchomiono je pod zagnieżdżonym Xvfb i zrobiono realne
zrzuty ekranu (`xwd`) oraz symulowano kliknięcia (`xdotool`) -- pierwszy
raz w historii tego projektu ktoś (coś) faktycznie ZOBACZYŁ działające
ZDE, zamiast tylko czytać kod.

To znalazło pięć realnych, poważnych błędów, niewidocznych przy samym
czytaniu kodu -- wszystkie naprawione i ponownie zweryfikowane wizualnie
(zrzut przed/po dla każdego):

1. **Dok (pasek zadań) był całkowicie niewidoczny** -- renderował się
   ok. 750px pod dolną krawędzią ekranu. Przyczyna: `box x, y, ...` w
   Fidget zawsze liczy się względem WŁASNEGO RODZICA
   (`node.screenBox = node.box + parent.screenBox`, patrz
   `fidget/common.nim`), nie względem ekranu. `dock` jest dzieckiem
   ramki `taskbar` (której `screenBox.y` to już `windowSize.y -
   TaskbarHeight`) -- poprzedni kod liczył pozycję `dock` tak, jakby był
   dzieckiem ekranu wprost, więc przesunięcie rodzica doliczało się
   PONOWNIE. Naprawione w `shell/taskbar.nim`.
2. **Wskazówki i kreski zegara analogowego były całkowicie niewidoczne**
   -- dwa nakładające się błędy w `apps/clock/clockapp.nim`:
   - błędne założenie (nigdy wcześniej niezweryfikowane), że `rotation`
     w Fidget obraca węzeł wokół zadanego punktu -- naprawdę zawsze
     obraca wokół ŚRODKA WŁASNEGO `box` węzła. `drawRadialBar` przepisany
     tak, żeby liczyć końcówkę wskazówki trygonometrią i centrować box
     dokładnie na środku odcinka, zamiast liczyć na nieistniejące
     zachowanie "obrót wokół lewego-górnego rogu";
   - tło tarczy (`dial`) było zadeklarowane JAKO PIERWSZE wśród
     rodzeństwa-węzłów, więc (zgodnie z odwróconą kolejnością rysowania
     Fidget -- patrz `shell/shell.nim`) renderowało się NA WIERZCHU
     kresek/wskazówek, całkowicie je zasłaniając. Przestawione na koniec.
3. **Data pokazywała angielską nazwę miesiąca** ("09 September" zamiast
   "09 września") -- `$now.month` ze `std/times` nie ma lokalizacji
   (ten sam problem, który już raz naprawiono dla dnia tygodnia, tu
   przeoczony). Dodana polska tablica `miesiace`.
4. **Pole godziny/minuty w kreatorze alarmu pokazywało "0" i "7" jedna
   nad drugą** zamiast "07" obok siebie -- pole tekstowe było za wąskie
   (14px) na dwuznakowy tekst monospace przy rozmiarze fontu 15 (~20px
   potrzebne), więc silnik zawijał tekst na dwie linie. Przyciski -/+
   zwężone, pole wartości poszerzone, font zmniejszony.
5. **`shell/taskbar.nim` (`AppCatalog`) w ogóle się nie kompilował** --
   znalezione i naprawione JESZCZE PRZED uruchomieniem, na etapie
   `nim c`: przypisanie procedur (`launchTerminal` itd.) do pola
   `action: proc()` nie przechodziło type-checkingu, bo Nim inferuje dla
   prostych lambd typ BEZ `{.closure.}`, a dla procedur odwołujących się
   do zmiennych top-level -- Z `{.closure.}`, i te dwa "prawie takie
   same" typy proc nie są dla Nima identyczne. Naprawione jawną pragmą
   `{.closure.}` na każdej lambdzie w `AppCatalog`/`SystemCatalog`.

**Dla przyszłych sesji:** jeśli środowisko ma zainstalowany `nim` +
`nimble`, `zde-shell` da się teraz skompilować i uruchomić lokalnie (nie
tylko `zde-comp`) -- polecenie: `nim c -d:release -d:pixieNoSimd
-o:dist/zde-shell shell/shell.nim`. To rewelacyjnie tania metoda
znajdywania tej klasy błędów (pozycjonowanie, kolejność rysowania,
literały tekstowe) w porównaniu z samym czytaniem kodu DSL-a.

## Nowości tej rozbudowy -- kompozytor: DPMS, gesty, pełny Alt+Tab

Ta runda skupiła się na `wlcomp/` i -- pierwszy raz -- każda zmiana była
od razu kompilowana i uruchamiana w piaskownicy (patrz sekcja o XWayland
niżej po opis, jak dokładnie), więc poniższe punkty mają wyższy stopień
pewności niż wcześniejsze rundy.

- **Idle/DPMS** (`wlcomp/idle.nim`, nowy plik) -- kompozytor sam wygasza
  wszystkie wyjścia po 5 minutach bez ruchu myszy/klawiatury
  (`DpmsTimeoutSec`) i budzi je przy pierwszej aktywności. Dodatkowo
  wystawia protokół `ext-idle-notify-v1` (`wlr_idle_notifier_v1`) dla
  przyszłych klientów (np. demona blokady) -- to i DPMS to dwie
  NIEZALEŻNE rzeczy, patrz komentarz na górze pliku.
- **Pełna karuzela Alt+Tab** (`wlcomp/toplevel.nim`, `cycleAltTab`/
  `commitAltTab`) -- zastępuje poprzedni prosty toggle. Powtarzane Tab
  przy trzymanym Alt przewija po WSZYSTKICH oknach (Shift = kierunek
  odwrotny), z podświetleniem kandydata cienkim, półprzezroczystym
  prostokątem (`wlr_scene_rect` w `overlayTree`, najwyższej warstwie
  sceny). Wybór zatwierdza się dopiero puszczeniem Alt (wykrywane w
  `onKeyboardModifiers`, `wlcomp/input.nim`).
- **Gesty touchpada** (`wlcomp/gestures.nim`, nowy plik) -- 3-palcowy
  swipe w lewo/prawo przełącza aktywne okno (ten sam mechanizm co
  `cycleFocusBy`, używany też przez gesty). Tylko swipe -- pinch/hold
  świadomie poza zakresem (brak dziś w ZDE naturalnego zastosowania, np.
  przeglądarki obrazów do zoomowania). Gesty są też przekazywane dalej do
  klientów przez `wlr_pointer_gestures_v1`, niezależnie od własnej reakcji
  kompozytora.
- **Polityka granic okien X11** (`wlcomp/xwayland.nim`,
  `onXwaylandRequestConfigure`) -- żądana przez klienta X11 geometria jest
  teraz klamrowana do granic całego układu monitorów
  (`wlr_output_layout_get_box`), więc okno nie może poprosić o
  umieszczenie się całkowicie poza widocznym ekranem.
- **Hit-testing subsurface'ów -- sprawdzone ponownie, nie był to realny
  problem.** `wlr_scene_subsurface_tree_create`/`wlr_scene_xdg_surface_create`
  już budują subsurface'y jako zwykłe węzły-dzieci w tym samym drzewie
  sceny, a `toplevelAt` poprawnie wspina się do właściciela -- poprzedni
  wpis na liście ograniczeń był nadmiarową ostrożnością.

### XWayland i sesja/VT-switch -- teraz zweryfikowane realną kompilacją

W tej rundzie udało się zainstalować `nim` + `libwlroots-dev` (0.17.1,
Ubuntu 24.04) w piaskownicy i realnie skompilować oraz uruchomić
`zde-comp` z całym kodem `wlcomp/` -- łącznie z pełnym testem end-to-end:
postawiono zagnieżdżony kompozytor pod Xvfb, uruchomiono pod nim
prawdziwe okno X11 (`xclock`) przez Xwayland i zweryfikowano w logu
poprawną sekwencję `new_surface -> associate` z odczytanym tytułem okna.
Każda nazwa pola/sygnału w `wlr/xwayland/xwayland.h` i
`wlr/backend/session.h`, odtworzona wcześniej "z pamięci", okazała się
zgodna z prawdziwymi nagłówkami. Realne błędy, jakie kompilator faktycznie
złapał przy tej i poprzednich rundach (dla przyszłej orientacji, jakiego
typu usterek szukać przy pracy bez kompilatora):

- brakujący `import std/sequtils` w nowym pliku (`wlcomp/xwayland.nim`),
- pusta linia wewnątrz definicji `object` w Nim 1.6 potrafi rozwalić
  parser (patrz `ServerObj` w `types.nim`),
- `addr` na elemencie tablicy `const` (a czasem nawet modułowego `let`)
  nie zawsze ma czego zaadresować przy `-d:release` -- Nim/gcc potrafią ją
  w pełni "spłaszczyć" do literałów; trzeba `var` (patrz `AltTabColor` w
  `wlcomp/toplevel.nim`).

Nie przetestowano jeszcze wobec wlroots 0.18/0.20 (tylko 0.17.1) ani na
prawdziwym DRM/TTY (tylko zagnieżdżone pod Xvfb, bez GPU) -- ale sama
poprawność API jest teraz potwierdzona kompilacją, nie tylko pamięcią.

## Nowości poprzedniej rozbudowy -- Alt+Tab i centrum powiadomień

- **Alt+Tab** (`wlcomp/toplevel.nim`, `cycleToPreviousToplevel`) --
  pierwszy skrót kompozytora do przełączania OKIEN (wcześniej istniał już
  tylko Ctrl+Alt+F<n> do przełączania VT, patrz niżej). To celowo prosty
  przełącznik "wróć do poprzedniego okna" (`toplevels[^2]`), NIE pełna
  karuzela z podglądem na przytrzymanym Alt -- ta druga wymagałaby
  rysowania nakładki UI wprost w scenie kompozytora, czego `wlcomp/`
  dziś nigdzie nie robi (cały UI shellu rysuje osobny proces `zde-shell`).
  Przechwytywane na poziomie kompozytora w `wlcomp/input.nim`, więc Tab z
  wciśniętym Alt nigdy nie dolatuje do aplikacji pod fokusem.
- **Centrum powiadomień** (`shell/notifications.nim` + `drawNotificationCenter`
  w `shell/taskbar.nim`) -- dzwonek w doku otwiera panel z historią
  ostatnich powiadomień (do 30, `MaxHistory`) i przełącznikiem "Nie
  przeszkadzać" (`setDnd`/`isDndEnabled`). Toasty i historia to dwa
  osobne byty: DND wycisza WYSKAKUJĄCE toasty, ale historia dalej się
  zapisuje (poza alarmami zegara -- te świadomie OMIJAJĄ DND, tak jak w
  telefonach). Kropka na dzwonku sygnalizuje niepustą historię. Wciąż bez
  przewijania listy (patrz ograniczenia niżej) i bez trwałości między
  restartami `zde-shell` -- ten sam kompromis co reszta systemu
  powiadomień, opisany w komentarzu na górze `notifications.nim`.

## Nowości poprzedniej rozbudowy (patrz też `shell/notifications.nim`)

- **System powiadomień ZDE** (`shell/notifications.nim`) -- wspólne API
  `notify(title, body, kind)` wołane z dowolnej aplikacji ZDE, toasty w
  prawym górnym rogu ekranu, widoczne nawet na zablokowanym ekranie (żeby
  alarm faktycznie obudził). Prosty, tylko-w-pamięci-procesu odpowiednik
  centrum powiadomień -- bez dziennika historii, bez dźwięku i bez
  integracji z zewnętrznym DBusowym `org.freedesktop.Notifications`
  (patrz komentarz na górze pliku, dlaczego to świadomie poza zakresem).
- **Alarmy i minutnik w `apps/clock`** -- druga zakładka zegara ("Alarmy")
  z listą alarmów o stałej porze dnia (włącz/wyłącz, usuń, dodaj przez
  steppery godzina/minuta) oraz prostym minutnikiem (presety 1/5/10/15 min,
  start/pauza/reset). Oba korzystają z powyższego systemu powiadomień --
  odliczanie działa w tle przez rejestr `clocks` w `shell/state.nim` (ten
  sam wzorzec co `terminals`/`sysmonitors`), niezależnie od tego, czy okno
  zegara jest akurat aktywne.

### "Aurora" -- wizualna przebudowa `zde-shell`

Cały wygląd powłoki dostał wspólny, nowocześniejszy motyw (`shell/state.nim`,
sekcja "Aurora" -- paleta, promienie zaokrągleń, poziomy tekstu w jednym
miejscu, żeby zmiana koloru w jednym pliku faktycznie zmieniała cały shell):

- **Tapeta** (`shell/wallpaper.nim`) -- domyślnie pionowy gradient
  (symulowany pasami, Fidget nie ma tu prawdziwego `linear-gradient`) +
  dwie miękkie plamy koloru akcentu ("glow") zamiast płaskiego
  jednolitego koloru; od kolejnej rozbudowy można też ustawić PRAWDZIWY
  obraz z dysku (Ustawienia -> Wygląd), patrz sekcja "Nowości tej
  rozbudowy -- tapeta z pliku obrazu" niżej.
- **Ramka okna** (`shell/chrome.nim`) -- zaokrąglone rogi, kropka
  wskazująca aktywne okno zamiast samej zmiany koloru obramowania, cienka
  jaśniejsza linia na górze paska tytułu ("glass highlight").
- **Dok** (`shell/taskbar.nim`) -- pasek zadań przestał być pełną belką od
  krawędzi do krawędzi; teraz to pływający, półprzezroczysty, zaokrąglony
  dok wcięty marginesem od krawędzi ekranu, z ikonami per aplikacja i
  kropką przy aktywnym oknie. `TaskbarHeight` (`comp/types.nim`) podniesione
  z 40 na 56px, żeby dok miał gdzie "oddychać" -- wszystko, co liczy
  dostępną wysokość pulpitu z tej stałej (maksymalizacja, ograniczenie
  pozycji okna), dostało tę przestrzeń automatycznie.
- **Launcher** (`shell/taskbar.nim`, `drawLauncher`) -- przeprojektowany na
  kartę z polem wyszukiwania filtrującym listę aplikacji na żywo (ten sam
  wzorzec pola tekstowego co ścieżka w edytorze tekstu), ikony w
  zaokrąglonych plakietkach, sekcje "Aplikacje"/"System" oddzielone
  cienką linią.

### Kompozytor (`wlcomp/`) -- XWayland i sesja/VT-switch

- **XWayland** (`wlcomp/xwayland.nim`, nowy plik) -- do tej pory `zde-comp`
  URUCHAMIAŁ proces Xwayland, ale nigdy nie nasłuchiwał na jego
  `events.new_surface`, więc żadne okno aplikacji X11 nigdy nie trafiało
  do sceny ani na listę okien -- proces się uruchamiał, ale efektywnie nic
  nie robił. Teraz okna X11 dostają pełny cykl życia (new_surface →
  associate → map/unmap → dissociate/destroy) i są wpięte w TEN SAM,
  uogólniony typ `Toplevel`, którego dotąd używał tylko xdg-shell (patrz
  `surfaceOf`/`geometryOf` w `wlcomp/toplevel.nim`) -- fokus, przeciąganie,
  zmiana rozmiaru działają dla okien X11 tą samą ścieżką kodu co dla
  zwykłych okien Wayland, bez duplikowania logiki.
- **Sesja / przełączanie VT** (`wlcomp/session.nim`, nowy plik) --
  `zde_backend_autocreate` (shim.c) do tej pory zawsze przekazywał `NULL`
  zamiast wskaźnika wyjściowego na `wlr_session`, więc kompozytor nie miał
  jak się dowiedzieć o przełączeniu wirtualnego terminala (Ctrl+Alt+F2 itd.)
  -- po powrocie na VT kompozytora ekran zostawał zamrożony na ostatniej
  klatce na zawsze (`onOutputFrame` samo się nie wznawia). Teraz: (1)
  `Ctrl+Alt+F1..F12` przełącza VT (przechwytywane na poziomie kompozytora,
  po surowym kodzie evdev klawisza -- działa niezależnie od układu
  klawiatury), (2) po powrocie aktywnej sesji wszystkie wyjścia dostają
  jawne `wlr_output_schedule_frame`, więc renderowanie faktycznie się
  wznawia.

  **Aktualizacja -- zweryfikowane kompilacją:** w kolejnej rundzie
  rozbudowy udało się zainstalować `nim` + `libwlroots-dev` (0.17.1,
  Ubuntu 24.04) w piaskownicy i realnie skompilować oraz uruchomić
  `zde-comp` z tym kodem, łącznie z pełnym testem end-to-end pod
  zagnieżdżonym Xvfb: prawdziwe okno X11 (`xclock`) uruchomione przez
  Xwayland poprawnie przeszło sekwencję `new_surface -> associate`
  (widoczne w logu z odczytanym tytułem okna). Jedyna znaleziona usterka:
  brakujący `import std/sequtils` w `wlcomp/xwayland.nim` (błąd Nim, nie
  API wlroots) -- każda nazwa pola/sygnału odtworzona wcześniej "z
  pamięci" okazała się zgodna z prawdziwymi nagłówkami. Nie
  przetestowano jeszcze wobec wlroots 0.18/0.20 (tylko 0.17.1) ani
  pełnego renderowania klatek przez GPU (headless Xvfb bez sprzętowego
  OpenGL) -- patrz zaktualizowany komentarz nad `WlrXwayland` w
  `wlcomp/wlroots.nim`.

## Ograniczenia obecnej wersji (v0.1)

Ten opis był w poprzednich wydaniach README rozjechany z rzeczywistym
stanem kodu (m.in. layer-shell, popupy, schowek/DnD, prawdziwy PTY,
podświetlanie składni, panel monitorów i aplikacja "Ustawienia" już
istniały, mimo że sekcja niżej twierdziła inaczej) -- poniższa lista jest
zweryfikowana względem bieżącej zawartości repo:

- **wlr-layer-shell** jest zaimplementowany (`wlcomp/layershell.nim`) --
  `zde-shell` może się zadokować jako pasek, nie tylko jako zwykłe okno
  xdg-toplevel.
- **Popupy** xdg-shell (`wlcomp/popup.nim`) i **schowek + drag & drop**
  (`wlr_data_device_manager`, `request_set_selection`/`request_start_drag`
  w `wlcomp/seatext.nim`) działają na poziomie kompozytora.
- **Terminal** (`apps/terminal`) ma prawdziwe PTY (`pty_shim.c`), programy
  pełnoekranowe (`vim`, `top`, `less`) działają poprawnie.
- **Edytor tekstu** (`apps/texteditor`) ma podświetlanie składni
  (`highlight.nim`), zakładki, wykrywanie zmian pliku na dysku w tle
  (`checkExternalChanges`) i od niedawna wyszukiwanie ORAZ zamianę
  (Ctrl+F, "Zamień"/"Zamień wszystko" -- patrz "Nowości" wyżej) -- to
  ostatnie bez rozróżniania wielkości liter, bez wyrażeń regularnych, i
  ze skokiem do LINII zamiast dokładnej pozycji kursora (Fidget nie daje
  programowego dostępu do pozycji kursora w polu tekstowym).
- **Układ klawiatury** jest konfigurowalny (`zdeconfig.nim`, aplikacja
  "Ustawienia"), nie zaszyty na sztywno na `us`.
- **Aplikacja "Ustawienia"** (`apps/settings`) istnieje, z wizualnym
  edytorem układu monitorów (przeciąganie, snapowanie krawędzi) i
  konfiguracją skrótów klawiszowych.
- **Zegar** ma teraz alarmy i minutnik (patrz sekcja "Nowości" wyżej) --
  lista alarmów też się teraz przewija (patrz "Nowości" -- scroll list),
  a każdy alarm może mieć wybrany dźwięk spośród realnie dostępnych w
  systemie (patrz sekcja "Nowości tej rozbudowy -- wybór dźwięku alarmu"
  niżej) -- minutnik nadal zawsze używa dźwięku "Auto".

Wciąż aktualne, rzeczywiste ograniczenia:

- **pojedynczy seat** (jeden zestaw klawiatura+mysz na sesję kompozytora)
  -- świadomie poza zakresem tej rundy: prawdziwy multi-seat wymaga
  przypisywania urządzeń wejścia/wyjścia do osobnych seatów przez udev i
  osobnego zarządzania sesją per seat (`seatd`/logind), co jest dużym,
  odrębnym projektem, potrzebnym praktycznie tylko w kioskach
  wieloosobowych -- nie regresja, tylko rozsądna granica zakresu
- **gesty touchpada -- tylko swipe** (`wlcomp/gestures.nim`, patrz
  "Nowości" wyżej); pinch (zbliżanie/oddalanie) i hold świadomie poza
  zakresem, brak dziś w ZDE naturalnego zastosowania (np. przeglądarki
  obrazów do zoomowania)
- ~~hit-testing kursora bez specjalnej obsługi zagnieżdżonych subsurface'ów~~
  -- sprawdzone ponownie przy tej rundzie rozbudowy: to jednak NIE jest
  realne ograniczenie. `wlr_scene_subsurface_tree_create`/
  `wlr_scene_xdg_surface_create` (`wlcomp/toplevel.nim`, `wlcomp/xwayland.nim`)
  budują subsurface'y jako zwykłe węzły-dzieci w TYM SAMYM drzewie sceny,
  a `toplevelAt` (`wlcomp/toplevel.nim`) wspina się po `node.parent` aż do
  korzenia z ustawionym `.data` -- więc trafienie w subsurface poprawnie
  rozwiązuje się do właściwego `Toplevel` bez żadnego dodatkowego kodu.
  Poprzedni wpis na tej liście był nadmiarową ostrożnością, nie opisem
  realnej luki.
- **XWayland i sesja/VT-switch** -- zweryfikowane kompilacją i podstawowym
  testem runtime wobec wlroots 0.17.1 (patrz sekcja "Nowości" wyżej), ale
  jeszcze NIE wobec 0.18/0.20 (docelowe wersje reszty `wlcomp/`) ani na
  prawdziwym DRM/TTY (tylko zagnieżdżone pod Xvfb, bez GPU) -- rozsądnie
  wysokie zaufanie, ale nie to samo co pełny test na docelowym sprzęcie
- ~~brak reguł polityki okien dla X11~~ -- już NIEAKTUALNE: geometria
  żądana przez klienta X11 jest klamrowana do granic układu monitorów
  (`wlr_output_layout_get_box`, `wlcomp/xwayland.nim`,
  `onXwaylandRequestConfigure`) od poprzedniej rundy rozbudowy
- system powiadomień (patrz "Nowości" wyżej): historia (do 30 wpisów,
  `MaxHistory` w `notifications.nim`) od pewnej rozbudowy PRZEŻYWA
  restart `zde-shell`, a zwykłe toasty (`nkInfo`/`nkWarning`) od tej
  rozbudowy mają własny, subtelny dźwięk (patrz sekcja "Nowości tej
  rozbudowy -- dźwięk zwykłych powiadomień" wyżej) -- wciąż bez
  integracji z zewnętrznymi aplikacjami spoza ZDE (np. przez DBus); panel
  historii (dzwonek w doku) przewija się tak samo jak launcher i lista
  alarmów (patrz "Nowości" wyżej)
- **aplikacje systemowe w launcherze -- lista jest teraz odświeżana w
  tle** (patrz "Nowości" niżej), ale przez tanie porównanie mtime
  katalogów `.desktop`, nie przez `inotify` -- nowy program pojawia się
  w launcherze z opóźnieniem rzędu sekundy, nie natychmiast; wciąż tylko
  ikony rastrowe (PNG) i bez pełnej specyfikacji Icon Theme (dziedziczenie
  motywów)
- **menedżer plików** (patrz "Nowości" wyżej -- tworzenie folderu, zmiana
  nazwy, usuwanie, otwieranie w edytorze, kopiuj/wytnij/wklej,
  zaznaczanie wielu wpisów przez Ctrl+klik i Shift+klik, skróty
  klawiszowe Delete/Ctrl+A/Escape/F2) -- wciąż bez przeciągania plików
  myszą (drag & drop); schowek plików (kopiuj/wytnij/wklej) żyje
  wyłącznie w pamięci JEDNEGO okna menedżera -- nie działa między dwoma
  otwartymi oknami ani z zewnętrznymi aplikacjami (prawdziwy schowek
  plików w stylu GNOME/KDE wymagałby własnego typu MIME na
  `wl_data_device`, czego architektura ZDE dziś nigdzie nie robi)
- ~~Alt+Tab to toggle do poprzedniego okna, nie pełna karuzela~~ -- już
  NIEAKTUALNE, patrz sekcja "Nowości" wyżej: teraz to pełna karuzela z
  podświetleniem w scenie kompozytora
- brak menedżera pakietów z GUI dla formatu `.zpk` (patrz `packaging/`) --
  budowanie/instalacja paczek to na razie tylko CLI (`zpk.build`,
  `recipe.janet`)
- **historia schowka** (patrz "Nowości" wyżej) -- od tej rozbudowy
  PRZEŻYWA restart `zde-shell` (patrz sekcja "Nowości tej rozbudowy --
  trwała historia schowka" niżej, ten sam wzorzec co historia
  powiadomień), ale wciąż tylko tekst (bez obrazów), tylko schowek
  "clipboard" (bez "primary selection" ze środkowego kliku w X11) i
  odpytywana raz na sekundę (nie na żywo przez zdarzenia
  `wl_data_device`)
- brak przełączania wielu użytkowników / wielu jednoczesnych sesji
- **tapeta z pliku** (patrz "Nowości" wyżej -- podgląd miniatury na żywo,
  automatyczne sprzątanie cache'a do 12 najnowszych plików) -- ścieżkę
  wciąż trzeba wpisać ręcznie (Fidget nie ma natywnego okna wyboru pliku,
  tak jak wszędzie indziej w ZDE); formaty ograniczone do tego, co
  dekoduje Pixie w tej wersji (PNG/JPEG -- bez GIF/WebP/animacji)
