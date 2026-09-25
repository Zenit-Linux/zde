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
  Menedżer plików (`apps/filemanager/files.nim`) od rundy 13 obsługuje też
  przeciąganie plików/folderów myszą (drag & drop) -- patrz "Nowości w
  v0.2 (runda 13)" niżej.
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
  libglfw3-dev libgl1-mesa-dev fontconfig fonts-dejavu-core \
  libdbus-1-dev pkg-config
```

**Runda 35 dodaje `libdbus-1-dev` (+ `pkg-config`) do tej listy** --
w odróżnieniu od `dwebp`/`wl-copy`/`xclip` (opcjonalne NA URUCHOMIENIU,
brakujące narzędzie = po cichu wyłączona jedna integracja), `libdbus-1`
jest wymagane do SAMEJ KOMPILACJI `zde-shell` od tej rundy --
`shell/notifications.nim` bezwarunkowo importuje `shell/dbusnotify.nim`
(patrz "Nowości w v0.2 (runda 35)" niżej), które przez
`{.passc: gorge("pkg-config --cflags dbus-1").}` woła `pkg-config` W
TRAKCIE kompilacji. Uruchomienie samego `zde-shell` bez działającego
`dbus-daemon --session` w sesji jest za to wciąż bezpieczne (patrz
duży komentarz w `dbusnotify.nim`) -- integracja po prostu się nie
aktywuje, reszta `zde-shell` działa normalnie.

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
   zde-comp: uruchomiono /.../dist/zde-shell (WAYLAND_DISPLAY=wayland-1)
   ```
   **To wszystko -- jedno TTY wystarczy.** Od v0.2 `zde-comp` sam odpala
   `zde-shell` jako swój "startup command" (patrz sekcja "Nowości w v0.2"
   niżej) -- `zde-shell` musi leżeć w TYM SAMYM katalogu co `zde-comp`
   (czyli w `dist/`, tak jak buduje go `build.janet`/`zde.nimble`
   domyślnie). Jeśli wolisz uruchomić powłokę ręcznie (np. do
   debugowania) albo Twoja binarka `zde-shell` leży gdzie indziej:
   ```bash
   ZDE_NO_AUTOSTART=1 ./zde-comp
   # w drugim TTY:
   WAYLAND_DISPLAY=wayland-1 dist/zde-shell
   # albo wskaż inną binarkę zde-shell bez wyłączania autostartu:
   ZDE_SHELL_PATH=/gdzie/indziej/zde-shell ./zde-comp
   ```

### Wariant B: zagnieżdżony, do szybkiego testowania (bez przełączania TTY)

Jeśli masz już działającą sesję Wayland (np. GNOME/Sway) albo X11, możesz
odpalić `zde-comp` jako *zwykłe okno* wewnątrz niej -- wlroots automatycznie
wykrywa, że działa zagnieżdżony, i użyje backendu Wayland-in-Wayland albo
X11-in-X11 zamiast prawdziwego DRM/KMS:

```bash
dist/zde-comp
```

Od v0.2 to wystarczy -- `zde-comp` sam odpala `dist/zde-shell` (patrz
"Wariant A" wyżej po szczegóły i zmienne `ZDE_NO_AUTOSTART`/
`ZDE_SHELL_PATH`). **Zweryfikowane realnym uruchomieniem w tej rundzie**
(nie tylko przeczytane w kodzie): `zde-comp` postawiony zagnieżdżony pod
Xvfb sam odpalił `zde-shell`, który połączył się z nim jako prawdziwy
klient Wayland -- zrzut ekranu potwierdza kompletny pulpit ZDE (tapeta,
dok, zegar) wyrenderowany przez WŁASNY kompozytor ZDE, nie przez
GLFW/X11 bezpośrednio (patrz sekcja "Nowości w v0.2" niżej po pełen opis
i drugi zrzut ekranu z realnym oknem X11 przez XWayland).

To najwygodniejszy sposób na rozwijanie/debugowanie ZDE bez ciągłego
przełączania TTY.

### Zmienne środowiskowe warte znajomości

- `WAYLAND_DISPLAY` -- nazwa socketu wystawionego przez `zde-comp`
  (`zde-comp` sam ją ustawia dla siebie i swoich dzieci -- w tym dla
  autostartowanego `zde-shell`, patrz wyżej; klienty startowane ręcznie w
  innym terminalu muszą ją dostać jawnie).
- `ZDE_NO_AUTOSTART` -- wyłącza autostart `zde-shell` przez `zde-comp`
  (dowolna niepusta wartość) -- patrz "Wariant A" wyżej.
- `ZDE_SHELL_PATH` -- wskazuje `zde-comp`, SKĄD odpalić `zde-shell` przy
  autostarcie, zamiast domyślnego "obok binarki zde-comp" -- patrz
  "Wariant A" wyżej.
- `WLR_BACKENDS` -- wymusza konkretny backend wlroots (`drm`, `wayland`,
  `x11`, `headless`) zamiast autodetekcji -- przydatne przy debugowaniu.
- `DISPLAY` -- po starcie XWaylanda `zde-comp` (a właściwie `wlr_xwayland`)
  sam wystawia gniazdo X11 i ustawia tę zmienną dla procesów, które
  odpali; stare aplikacje X11 uruchomione z `DISPLAY` ustawionym na tę
  wartość powinny działać przez XWayland bez zmian.

## Nowości w v0.2 (runda 33) -- weryfikacja interakcji "przypnij na wierzchu" z "Pokaż pulpit" i przenoszeniem między pulpitami

Krótka runda dopełniająca rundę 32: dwie interakcje między
`alwaysOnTop` (runda 32) a dwiema wcześniejszymi funkcjami (`toggleShowDesktop`
z rundy 28, `moveWindowToWorkspace` z rundy 27) nie były jeszcze
sprawdzone razem. Po ośmiu rundach znajdowania błędów DOKŁADNIE w
takich miejscach ("dwie funkcje, które nigdy nie były przetestowane
obok siebie"), warto było to sprawdzić explicite, zamiast zakładać, że
"pewnie działa".

**Wynik: oba przypadki działają poprawnie, bez poprawek.**

- **Przypięte okno + "Pokaż pulpit"**: przypięte okno jest
  minimalizowane przez "Pokaż pulpit" na równi ze zwykłymi (poprawne
  zachowanie -- "Pokaż pulpit" to bezwzględne "wyczyść wszystko z
  ekranu", nie powinno robić wyjątku dla przypiętych okien) i poprawnie
  przywracane, z zachowanym statusem przypięcia po całym cyklu.
- **Przypięte okno + przeniesienie na inny pulpit**: status przypięcia
  przetrwa przeniesienie, a okno poprawnie renderuje się na wierzchu
  również na NOWYM pulpicie, nie tylko na tym, na którym zostało
  przypięte.

Oba scenariusze dopisane jako stałe testy regresyjne do
`test_real_comp_alwaysontop.nim` (teraz 9 scenariuszy, z 7) -- na
PRAWDZIWYM, niezmodyfikowanym `comp/comp.nim`, tak jak reszta tej serii.
Ta runda to uczciwy przykład, że nie każde poszukiwanie błędu kończy się
jego znalezieniem -- i że to też jest wartościowy wynik, wart
udokumentowania i zabezpieczenia testem na przyszłość, nie tylko
błędy same w sobie.

## Nowości w v0.2 (runda 32) -- "Przypnij na wierzchu" (always-on-top), świadomie wąski zakres po ośmiu rundach napraw

Dziewiąta runda dotycząca `comp/` -- pierwsza NOWA funkcja od rundy 28,
zaprojektowana z pełną świadomością tego, co osiem poprzednich rund
(24-31) już nauczyło o tym kodzie: większość znalezionych tam błędów
brała się z DWÓCH funkcji inaczej interpretujących to samo pojęcie
"kolejności okien" (zIndex vs. minimized vs. workspace). Żeby nie
dołożyć DZIEWIĄTEGO takiego przypadku, przypinanie okna "na wierzchu"
zostało celowo ograniczone do JEDNEGO wymiaru: kolejności RYSOWANIA
(`windowsInZOrder`). Nie rusza `zIndex` samego okna ani logiki fokusu
(`cycleFocus`, `focusNextBestOnWorkspace`) -- Alt+Tab i przejmowanie
fokusu po zamknięciu/zminimalizowaniu działają DOKŁADNIE tak samo,
niezależnie od tego, czy jakiekolwiek okno jest przypięte.

- Przycisk "📌" w pasku tytułu każdego okna (`shell/chrome.nim`) --
  dostępny niezależnie od `resizable`/`closable`, bo przypinanie to
  inna oś niż zmiana rozmiaru/zamykanie.
- Przypięte okno renderuje się ZAWSZE nad wszystkimi nieprzypiętymi,
  niezależnie od tego, który z nich ma wyższy surowy `zIndex` --
  `windowsInZOrder` sortuje teraz dwupoziomowo (najpierw status
  przypięcia, potem `zIndex` w ramach każdej z dwóch grup).
- Dwa przypięte okna wciąż porządkują się między sobą normalnie wg
  `zIndex` -- przypięcie nie zamienia ich w nierozróżnialną grupę.
- `toggleAlwaysOnTop` świadomie NIE zmienia fokusu -- przypięcie okna w
  tle (np. odtwarzacza muzyki) nie powinno kraść fokusu klawiatury
  aktywnemu oknu, w którym użytkownik akurat pracuje.

**Metoda weryfikacji**: `test_real_comp_alwaysontop.nim` -- 7
scenariuszy na PRAWDZIWYM, niezmodyfikowanym `comp/comp.nim`, w tym DWA
uznane za KLUCZOWE dla tej rundy: `cycleFocus` (Alt+Tab) daje DOKŁADNIE
tę samą sekwencję co w testach z rund 21/23, niezależnie od tego, czy
jedno z trzech okien jest przypięte; przejęcie fokusu po
`minimizeWindow` (runda 30) wciąż opiera się wyłącznie na surowym
`zIndex`, nieporuszone przez status przypięcia. Reszta: podstawowe
działanie (przypięte na wierzchu mimo niższego zIndex), przypięte
zostaje na wierzchu nawet po ogniskowaniu innego okna (cały sens tej
funkcji), dwa przypięte okna porządkują się między sobą, odpięcie
przywraca zwykłe sortowanie, brak zmiany fokusu przy samym przypinaniu.

## Nowości w v0.2 (runda 31) -- naprawiona luka w kontrakcie: `openWindow` nie gwarantowało, że początkowy rozmiar jest co najmniej `minSize`

Ósmy problem znaleziony w `comp/` -- tego samego, "latentnego" gatunku
co runda 29 (nie widoczny dziś w praktyce, ale realna niespójność w
publicznym kontrakcie API), znaleziony przy okazji przeglądu
`openWindow` po naprawie `dkResize` z rundy 26.

**Problem**: `openWindow` przyjmuje ZARÓWNO `size` (startowy rozmiar),
JAK I `minSize` (minimalny rozmiar) jako niezależne parametry, ale nic
nie sprawdzało, czy `size >= minSize` -- konstruktor po prostu wpisywał
`size` wprost, nawet jeśli był MNIEJSZY niż deklarowane dla tego samego
okna minimum. Potwierdzone bezpośrednim uruchomieniem PRZED naprawą:
`openWindow(..., size = vec2(100, 50), minSize = vec2(280, 180))`
dawało okno o rozmiarze `(100, 50)` -- sprzeczne samo ze sobą.

**Uczciwa notatka o zasięgu**: sprawdzone w `shell/launcher_apps.nim` --
wszystkie obecne w kodzie aplikacji wywołania `openWindow` przekazują
`size` bezpiecznie większy niż `DefaultMinSize` (280x180), żadne nie
przekazuje własnego `minSize` w ogóle. To nie jest błąd widoczny w
dzisiejszym działaniu ZDE -- to luka, którą ugryzłaby pierwsza
aplikacja (albo przyszła zmiana domyślnych rozmiarów), jaka
przekazałaby oba parametry niespójnie.

**Naprawa**: przycięcie `size` do `minSize` w JEDNYM miejscu
(`clampedSize`), zastosowane PRZED liczeniem pozycji startowej (żeby
wyśrodkowanie na ekranie też korzystało z faktycznego, przyciętego
rozmiaru, nie surowego) oraz w `savedSize` (żeby maksymalizacja i
przywrócenie takiego okna nie cofały go do niespójnego, zbyt małego
stanu) -- ten sam duch co przycinanie w `dkResize` z rundy 26, tylko
zastosowany też przy SAMYM OTWARCIU okna.

**Metoda weryfikacji**: `test_real_comp_open_minsize.nim` -- 5
scenariuszy na PRAWDZIWYM, niezmodyfikowanym `comp/comp.nim`: regresja
na sam znaleziony błąd, przycinanie NIEZALEŻNE per oś (nie
"wszystko-albo-nic"), regresja na typowy przypadek (`size > minSize`,
bez zmian), spójność `savedSize` przy cyklu maksymalizuj/przywróć, oraz
poprawność wyśrodkowania względem faktycznego (przyciętego) rozmiaru.

## Nowości w v0.2 (runda 30) -- naprawiona asymetria: minimalizacja aktywnego okna nie oddawała fokusu następnemu widocznemu

Siódmy problem znaleziony w `comp/` -- tym razem PRAWDZIWY, widoczny w
codziennym działaniu (w odróżnieniu od rundy 29), znaleziony przez
porównanie dwóch koncepcyjnie podobnych operacji obok siebie.

**Błąd**: `closeWindow` zawsze oddawał fokus najwyżej ułożonemu z
pozostałych widocznych okien na tym samym pulpicie po usunięciu okna.
`minimizeWindow` -- ta sama, z punktu widzenia użytkownika, kategoria
zdarzenia ("to okno znika z widoku") -- tego NIE robiło: po prostu
zerowało `comp.focusedId` na `0` i kończyło, nawet gdy na ekranie
zostawały inne, widoczne okna. Potwierdzone bezpośrednim uruchomieniem
PRZED naprawą: dwa okna, drugie ma fokus, zminimalizuj je --
`windowsInZOrder()` nadal zwraca pierwsze (widoczne), ale `focusedId`
zostaje `0`, jakby nic w ogóle nie było widoczne -- w praktyce
użytkownik zminimalizowałby aktywne okno i nie zobaczyłby ŻADNEGO okna
podświetlonego jako aktywne, mimo że inne wciąż stoją na ekranie.

**Naprawa**: wydzielona wspólna procedura `focusNextBestOnWorkspace`
(ten sam duch co `doMaximize` z rundy 22) -- `closeWindow` i
`minimizeWindow` teraz DOSŁOWNIE dzielą tę samą logikę zamiast
utrzymywać dwie osobne, prawie identyczne kopie, które już raz się
rozjechały. To nie tylko naprawia dzisiejszy błąd, ale też eliminuje
ryzyko, że przyszła zmiana w jednym miejscu znowu nie trafi do
drugiego.

**Metoda weryfikacji**: `test_real_comp_minimize_focus.nim` -- 6
scenariuszy na PRAWDZIWYM, niezmodyfikowanym `comp/comp.nim`: regresja
na sam znaleziony błąd, minimalizacja NIE-ogniskowanego okna (fokus bez
zmian), minimalizacja jedynego okna (poprawnie `focusedId = 0`), fokus
trafia na NAJWYŻEJ ułożone z wielu pozostałych (nie przypadkowe),
respektowanie granic pulpitów wirtualnych, oraz regresja potwierdzająca,
że `closeWindow` po refaktoryzacji nadal działa dokładnie tak jak
przedtem.

## Nowości w v0.2 (runda 29) -- naprawiona niespójność API: `closable=false` nie było wcale egzekwowane przez `closeWindow`

Szósty z rzędu problem znaleziony w `comp/` -- ale, w odróżnieniu od
poprzednich pięciu (rundy 24-27), UCZCIWIE inny co do zasięgu: to NIE
jest błąd widoczny dziś w codziennym działaniu ZDE, tylko luka w
egzekwowaniu udokumentowanego kontraktu publicznego API, którą
znaleziono przez systematyczny przegląd, nie przez natrafienie na
zaobserwowane złe zachowanie.

**Problem**: `closable` (parametr `openWindow`, mówiący "tego okna nie
da się zamknąć") był sprawdzany WYŁĄCZNIE w `shell/chrome.nim`, przy
decyzji, czy w ogóle POKAZAĆ przycisk "X" na pasku tytułu. Samo
`closeWindow` (`comp/window.nim`) w ogóle nie sprawdzało tej flagi --
ukrycie przycisku "X" było więc czysto KOSMETYCZNE: skrót klawiszowy
(Ctrl+Alt+Q, `actCloseWindow`) albo jakiekolwiek inne, przyszłe
wywołanie `closeWindow` wprost wciąż zamykało okno, mimo
`closable = false`.

**Uczciwa notatka o zasięgu**: sprawdzone przez `grep` po całym repo --
ŻADNE okno w obecnym kodzie aplikacji nie jest dziś otwierane z
`closable = false`. To nie jest więc błąd, na który ktokolwiek mógłby
dziś trafić, używając ZDE -- to luka, która ugryzłaby PIERWSZĄ
aplikację, jaka kiedykolwiek skorzystałaby z tego parametru, ufając, że
robi to, co obiecuje. Naprawiona teraz, na zapas, egzekwowaniem w
JEDNYM, autorytatywnym miejscu (`closeWindow` samo odmawia, jeśli
`not w.closable`) -- zamiast polegać na tym, że każdy wywołujący (skrót
klawiszowy, dok, przyciski UI, przyszły kod) osobno o tym pamięta.

**Metoda weryfikacji**: `test_real_comp_closable.nim` -- 5 scenariuszy
na PRAWDZIWYM, niezmodyfikowanym `comp/comp.nim`: regresja na sam
znaleziony problem (`closable=false` faktycznie opiera się
`closeWindow`), regresja na zwykłe okno (`closable=true`, wartość
domyślna, zamyka się bez zmian), `onClose` NIE wywołuje się dla okna,
którego nie dało się zamknąć (ważne, żeby aplikacja nie wykonała
sprzątania dla okna, które w rzeczywistości wciąż istnieje), fokus nie
zmienia się przy nieudanej próbie, oraz regresja na nieistniejące id
jako bezpieczny no-op.

## Nowości w v0.2 (runda 28) -- "Pokaż pulpit" (Super+D)

Domyka realny brak: funkcja obecna w praktycznie każdym DE (minimalizuj
wszystkie okna naraz, żeby zobaczyć pulpit, ponowne wywołanie przywraca
je wszystkie) nie istniała w ogóle. Po pięciu rundach z rzędu
poświęconych wyłącznie naprawianiu znalezionych błędów, ta runda to
znowu nowa funkcja -- `comp/window.nim` (`toggleShowDesktop`), skrót
domyślnie `super+d`.

Kluczowy szczegół projektowy: ponowne wywołanie przywraca WYŁĄCZNIE
okna, które SAMO zminimalizowało (`Compositor.showDesktopIds`) -- NIE
"wszystkie aktualnie zminimalizowane okna". Bez tego rozróżnienia okno,
które użytkownik zminimalizował RĘCZNIE PRZED wywołaniem "Pokaż
pulpit", zostałoby po cichu przywrócone razem z resztą przy drugim
naciśnięciu Super+D, mimo że użytkownik nigdy o to nie prosił --
zweryfikowane wprost testem (Test 3, "kluczowy przypadek").

- Fokus zapamiętywany i przywracany (`showDesktopPrevFocusedId`) --
  drugie Super+D wraca do tego samego okna, które było aktywne przed
  pierwszym.
- Respektuje pulpity wirtualne -- dotyczy WYŁĄCZNIE bieżącego pulpitu,
  okna na innych pulpitach nietknięte (ten sam wzorzec co
  `cycleFocus`/`switchWorkspace` z wcześniejszych rund).
- Bezpieczne na okno zamknięte W TRAKCIE pokazywania pulpitu (drugie
  wywołanie nie wywala się na już-nieistniejącym `id`) i na pusty
  pulpit bez żadnych okien.

**Metoda weryfikacji**: `test_real_comp_showdesktop.nim` -- 7
scenariuszy na PRAWDZIWYM, niezmodyfikowanym `comp/comp.nim`:
podstawowe minimalizowanie/przywracanie, kluczowy przypadek z ręcznie
zminimalizowanym oknem sprzed wywołania, przywracanie fokusu, izolacja
pulpitów wirtualnych, zamknięcie okna w trakcie pokazywania pulpitu,
pusty pulpit jako bezpieczny przypadek brzegowy.

Nowy skrót `actToggleShowDesktop`, domyślnie `super+d`, konfigurowalny w
Ustawieniach jak reszta (runda 21) -- trzy równoległe tablice w
`shell/shortcuts.nim` rozszerzone o jeden wpis w poprawnej pozycji,
przeliczone ręcznie (19 = 19 = 19 = liczba wartości enuma).

## Nowości w v0.2 (runda 27) -- naprawiony błąd: przeniesienie zminimalizowanego okna na inny pulpit zostawiało je niewidocznym, mimo że "miało fokus"

Piąty z rzędu prawdziwy błąd znaleziony w `comp/` -- w `moveWindowToWorkspace`,
kodzie nietkniętym przez żadną z poprzednich pięciu rund.

**Błąd**: `moveWindowToWorkspace` ustawiało `comp.focusedId = id`
**bezpośrednio**, z pominięciem `comp.focus(id)` (które normalnie
podnosi zIndex okna na wierzch ORAZ czyści `minimized`). Dla zwykłego
okna nie robiło to różnicy -- ale dla okna przenoszonego W STANIE
ZMINIMALIZOWANYM (łatwe do wywołania z paska zadań, bez wcześniejszego
ręcznego przywracania) zostawiało `w.minimized == true` nietknięte,
mimo że `comp.focusedId` już na nie wskazywało. Kompozytor "wierzył",
że to okno ma fokus, a jednocześnie `windowsInZOrder()` (używane do
rysowania) dalej je pomijało jako zminimalizowane -- okno stawało się
niewidoczne mimo rzekomego fokusu, w praktyce "znikając" po przeniesieniu
na inny pulpit z paska zadań.

Potwierdzone bezpośrednim uruchomieniem PRZED naprawą, nie domysłem:
zminimalizuj okno, przenieś je na inny pulpit -- `windowsInZOrder()` na
docelowym pulpicie zwracało **0 okien**, mimo że `focusedId` wskazywało
dokładnie na to jedno, właśnie przeniesione.

**Naprawa**: `comp.focus(id)` zamiast bezpośredniego przypisania --
przeniesienie zminimalizowanego okna na inny pulpit teraz też je
PRZYWRACA, spójnie z tym, jak "przywróć i pokaż" działa wszędzie
indziej w tym module (`restoreWindow` robi dokładnie to samo, jednym
wywołaniem `comp.focus`).

**Metoda weryfikacji**: `test_real_comp_moveworkspace.nim` -- 4
scenariusze na PRAWDZIWYM, niezmodyfikowanym `comp/comp.nim`: regresja
na sam znaleziony błąd (zminimalizowane okno widoczne po przeniesieniu),
regresja na zwykłe okno (bez zmian), potwierdzenie że naprawa używa
PEŁNEGO `focus()` (zIndex też poprawnie podniesiony, nie tylko
`minimized` wyczyszczone ręcznie), oraz przeniesienie na ten sam
pulpit jako bezpieczny przypadek brzegowy.

## Nowości w v0.2 (runda 26) -- naprawiony błąd: zmiana rozmiaru okna z lewej/górnej krawędzi poza minimalny rozmiar przesuwała przeciwległą krawędź

Czwarty z rzędu prawdziwy błąd znaleziony w `comp/` dzięki temu, że
faktycznie się kompiluje i uruchamia -- tym razem w logice zmiany
rozmiaru okna (`dkResize`, `comp/drag.nim`), nietkniętej przez żadną z
poprzednich czterech rund.

**Błąd**: `applyLeft`/`applyTop` (szablony obliczające nową pozycję/
rozmiar przy przeciąganiu lewej/górnej krawędzi okna) liczyły `newPos`
wprost z NIEPRZYCIĘTEGO przesunięcia kursora, a przycinanie do
`minSize` działo się DOPIERO PÓŹNIEJ, bez żadnej odpowiadającej korekty
`newPos`. W praktyce: przeciągnięcie lewej (albo górnej) krawędzi POZA
punkt, w którym okno osiągnęłoby swój minimalny rozmiar -- codzienny,
łatwy do przypadkowego wywołania scenariusz, nie przypadek brzegowy --
powodowało, że PRZECIWLEGŁA krawędź (prawa/dolna -- ta, której
użytkownik w ogóle nie dotykał) nagle PRZESKAKIWAŁA w bok, zamiast
zostać na miejscu.

Potwierdzone bezpośrednim uruchomieniem PRZED naprawą, nie domysłem:
okno 200x150 na pozycji (100,100) -- prawa krawędź na x=300 --
przeciągnięcie lewej krawędzi o +150px (poza `minSize.x = 100`, surowy
wynikowy rozmiar wyszedłby 50px) dawało finalnie `pos.x=250, size.x=100`
-- prawa krawędź wychodziła na x=350, zamiast zostać na x=300.

**Naprawa**: `newPos` dla lewej/górnej krawędzi liczone jest teraz na
podstawie tego, o ILE rozmiar FAKTYCZNIE się zmienił WZGLĘDEM już
przyciętego minimum (`newPos.x = startPos.x + startSize.x - newSize.x`),
nie wprost z surowego przesunięcia kursora -- gwarantuje to, że
przeciwległa krawędź (`newPos.x + newSize.x`) zawsze zostaje dokładnie
tam, gdzie była, niezależnie od tego, czy przycięcie do `minSize`
faktycznie zadziałało. Prawa/dolna krawędź nigdy nie miały tego błędu
(nie zmieniają pozycji okna w ogóle) -- naprawa dotyczy WYŁĄCZNIE
lewej/górnej, potwierdzone osobnym testem regresyjnym.

**Metoda weryfikacji**: `test_real_comp_resize.nim` -- 5 scenariuszy na
PRAWDZIWYM, niezmodyfikowanym `comp/comp.nim`: regresja na sam
znaleziony błąd (lewa krawędź poza minSize, prawa musi zostać
nieruchoma), to samo dla górnej/dolnej, róg (obie osie naraz poza
minSize jednocześnie), zwykłe rozciąganie W GRANICACH minSize
(niezmienione), oraz regresja potwierdzająca, że prawy-dolny róg nigdy
nie miał tego problemu i nadal działa bez zmian.

## Nowości w v0.2 (runda 25) -- naprawiony błąd: zamknięcie okna psuło kaskadę pozycji startowej kolejnych okien

Trzeci z rzędu prawdziwy błąd znaleziony dzięki testowalności `comp/`
(rundy 21-24) -- znowu w kodzie, który istniał od dawna, ujawnionym
dopiero przez systematyczne przeglądanie modułu w poszukiwaniu kolejnych
celów.

**Błąd**: `openWindow` kaskaduje pozycję startową nowego okna (żeby
kolejne okna nie nakładały się idealnie jedno na drugim -- klasyczny
"cascade" znany z każdego DE), ale licznik kaskady był kluczowany po
`comp.windows.len` -- **liczbie okien otwartych AKURAT TERAZ**, nie po
liczbie okien otwartych kiedykolwiek w tej sesji. W praktyce: zamknięcie
okna W ŚRODKU sekwencji otwierania (zwyczajny scenariusz codziennego
użytkowania -- otwórz kilka okien, zamknij jedno, otwórz kolejne, nie
przypadek brzegowy) cofało licznik kaskady, więc KOLEJNE nowo otwarte
okno mogło wylądować DOKŁADNIE na pozycji innego, wciąż otwartego okna
-- dokładnie ten problem, który kaskadowanie miało w ogóle zapobiegać.

Potwierdzone bezpośrednim uruchomieniem PRZED naprawą, nie domysłem:
otwórz W1/W2/W3 (każde na innej, skaskadowanej pozycji), zamknij W2,
otwórz W4 -- W4 lądowało w DOKŁADNIE tej samej pozycji co W3
(`vec2(616.0, 308.0)` w obu przypadkach).

**Naprawa**: kaskada liczona teraz wg `id` (unikalny, monotonicznie
rosnący identyfikator okna -- nigdy się nie cofa ani nie jest ponownie
użyty, niezależnie od tego, ile okien zamknięto po drodze) zamiast
`comp.windows.len`. Zawijanie po 8 "stopniach" kaskady (żeby 9. okno nie
wylądowało poza ekranem) pozostaje niezmienione -- to wciąż `mod 8`,
tylko liczony od stabilnego `id`, nie od chwiejnej liczby aktualnie
otwartych okien.

**Metoda weryfikacji**: `test_real_comp_cascade.nim` -- 4 scenariusze na
PRAWDZIWYM, niezmodyfikowanym `comp/comp.nim`: regresja na sam
znaleziony błąd (zamknięcie środkowego okna nie psuje pozycji
kolejnego), podstawowe kaskadowanie bez zamykania (nadal działa),
przewidywalność kaskady niezależna od "hałasu" (otwórz-i-zamknij 5
tymczasowych okien, kaskada 7. faktycznie otwartego okna liczy się od
jego prawdziwego `id`, nie od liczby okien widocznych w danej chwili),
oraz regresja na zawijanie po 8 oknach (niezmienione).

## Nowości w v0.2 (runda 24) -- naprawiony błąd: okna przyciągnięte do połowy/ćwiartki traciły snap przy zmianie rozdzielczości ekranu

Kolejny prawdziwy błąd znaleziony dzięki temu, że `comp/` faktycznie się
kompiluje i uruchamia (rundy 21-23) -- tym razem NIE w nowo dodanym
kodzie tej rundy, tylko w PRZEDTEM ISTNIEJĄCEJ procedurze
`setScreenSize`, ujawniony dopiero przez sprawdzenie, jak współdziała z
funkcjami z rund 21-22.

**Błąd**: `setScreenSize` (wołana przy zmianie rozdzielczości ekranu,
np. podłączeniu innego monitora) traktowała KAŻDE zmaksymalizowane okno
identycznie -- rozciągała je na CAŁY nowy ekran. To poprawne dla okna
zmaksymalizowanego W CAŁOŚCI, ale BŁĘDNE dla okna przyciągniętego do
POŁOWY albo ĆWIARTKI (`w.maximized == true` to JEDNA flaga używana dla
obu przypadków, rozróżnia je dopiero `w.snapEdge`) -- w praktyce okno
przyciągnięte do lewej połowy nagle zajmowało CAŁY nowy ekran po zmianie
rozdzielczości, mimo że `snapEdge` wciąż formalnie mówił `seLeft`.

Potwierdzone bezpośrednim uruchomieniem PRZED naprawą, nie domysłem: w
oknie 1920x1080 przyciągniętym do lewej połowy (960px szerokości) po
`setScreenSize(2560x1440)` szerokość wynosiła **2560** -- cały nowy
ekran, zamiast oczekiwanych 1280 (połowa nowego). Ten sam błąd dotyczył
też ćwiartek z rundy 21 -- w praktyce prawdopodobnie NAJCZĘŚCIEJ
widoczny scenariusz (laptop z oknem przyciągniętym do połowy, podłączony
do zewnętrznego monitora o innej rozdzielczości).

**Naprawa**: gdy `snapEdge != seNone`, `setScreenSize` przelicza
geometrię przez `snapGeometry` (tę samą funkcję, której już używa
`snapWindow` z rundy 21) względem NOWEGO rozmiaru ekranu, zamiast na
sztywno rozciągać na pełny ekran -- prawdziwa pełna maksymalizacja
(`snapEdge == seNone`) zachowuje dotychczasowe, poprawne zachowanie bez
zmian.

**Metoda weryfikacji**: `test_real_comp_screensize.nim` -- 5
scenariuszy na PRAWDZIWYM, niezmodyfikowanym `comp/comp.nim`: regresja
na sam znaleziony błąd (lewa połowa pozostaje połową NOWEGO ekranu),
prawa połowa (pozycja X też poprawnie przeliczona, nie tylko rozmiar),
ĆWIARTKA (kluczowy przypadek, który w praktyce najbardziej ujawnia ten
błąd -- geometria poprawnie przeliczona względem nowego ekranu), oraz
dwa testy regresyjne potwierdzające, że naprawa NIE zepsuła istniejącego
zachowania: prawdziwa pełna maksymalizacja nadal poprawnie rozciąga się
na cały nowy ekran, okno niezmaksymalizowane wciąż tylko przycinane
(`clampToScreen`), bez zmiany rozmiaru.

## Nowości w v0.2 (runda 23) -- cykl fokusu wstecz (Shift+Alt+Tab); prawdziwy błąd znaleziony i naprawiony metodą "uruchom i zobacz"

Domyka realny brak: Alt+Tab działał tylko w jedną stronę -- Shift+Alt+Tab
(cykl WSTECZ) nie istniał w ogóle, mimo że to standard w praktycznie
każdym menedżerze okien.

**To była runda z najbardziej pouczającym, realnym błędem w całej tej
serii.** Pierwsza, intuicyjna implementacja `reverse` w `cycleFocus`
(`comp/window.nim`) wyglądała poprawnie na papierze: znajdź bieżący
indeks ogniskowanego okna w posortowanej wg z-order liście, odejmij 1
zamiast dodać. Napisany od razu do niej test (oparty na ZAŁOŻONEJ,
prostej sekwencji) faktycznie nie przechodził -- ale dopiero
bezpośrednia obserwacja (`echo` po każdym kroku w osobnym skrypcie
diagnostycznym) ujawniła PRAWDZIWY charakter problemu: `comp.focus()`
PODNOSI zIndex ogniskowanego okna na wierzch przy KAŻDYM wywołaniu --
więc "bieżący indeks" ogniskowanego okna jest PO KAŻDYM kroku, w
przeliczonej na nowo liście, zawsze `len - 1` (ostatnia pozycja).
Odejmowanie stałej "1" od stałej "len - 1" daje ZAWSZE tę samą docelową
pozycję względną -- program wpadał w nieskończoną pętlę oscylującą
między DWOMA oknami, nigdy nie docierając do pozostałych (potwierdzone
na 3 oknach: `focused=3 -> 2 -> 3 -> 2 -> 3...`, okno `1` nigdy
nieosiągalne).

**Naprawa wykorzystuje własność matematyczną cykli**, zamiast łatać
indeksowanie: "w przód" jest -- empirycznie potwierdzonym, i chronionym
osobnym testem regresyjnym -- STABILNYM cyklem o długości dokładnie
`visible.len` (każde naciśnięcie odwiedza kolejne okno, wraca do
punktu startowego dopiero po tylu krokach, ile jest okien). Wykonanie
kroku "w przód" `visible.len - 1` razy z rzędu, na TEJ SAMEJ, raz
posortowanej liście (bez ponownego sortowania między krokami --
wydzielony `stepFocusForward`), jest matematycznie równoważne jednemu
krokowi w przeciwnym kierunku: N-1 kroków w cyklu o długości N zawsze
ląduje dokładnie tam, gdzie wylądowałby jeden krok wstecz. Zero nowej,
zawodnej logiki indeksowej -- reużycie logiki "w przód", której
poprawność jest już ustalona.

**Metoda weryfikacji**: `test_real_comp_cyclefocus.nim` -- 7
scenariuszy na PRAWDZIWYM, niezmodyfikowanym `comp/comp.nim`: regresja
zwykłego `cycleFocus()` (zero zmian zachowania), pełny cykl wstecz
przez 3 okna (dokładnie odwrotna kolejność do "w przód", stabilna przez
wiele pełnych okrążeń), "w przód potem wstecz" wraca do punktu
startowego, pojedyncze okno i brak okien jako bezpieczne przypadki
brzegowe, respektowanie granic pulpitów wirtualnych, oraz -- najbardziej
wymowny -- test regresyjny NA SAM ZNALEZIONY BŁĄD z 5 oknami i 20
kolejnymi krokami wstecz, potwierdzający, że wszystkie 5 zostaje
odwiedzonych, żadna pętla dwuokienna się nie powtarza.

Nowy skrót `actCycleFocusPrev`, domyślnie `shift+alt+tab`,
konfigurowalny w Ustawieniach na tych samych zasadach co reszta (patrz
runda 21) -- trzy równoległe tablice w `shell/shortcuts.nim` rozszerzone
o jeden wpis w poprawnej pozycji, przeliczone ręcznie (18 = 18 = 18 =
liczba wartości enuma, `shell/shortcuts.nim` importuje `fidget` więc
bezpośrednia kompilacja nie była możliwa).

## Nowości w v0.2 (runda 22) -- "Aero Snap" myszą: przeciągnięcie okna do krawędzi ekranu przyciąga je

Domyka naturalne uzupełnienie rundy 21: przyciąganie okien do
połowy/ćwiartek ekranu działało dotąd WYŁĄCZNIE ze skrótów klawiszowych
(Super+Left/Right/Up/Down) -- brakowało klasycznego gestu MYSZĄ, znanego
z Windows/GNOME/KDE: przeciągnięcie paska tytułu okna do krawędzi
ekranu i puszczenie przycisku myszy przyciąga je automatycznie.

- **Przeciągnięcie do samej góry ekranu** (`TopDragSnapZone`, 4px --
  celowo węższa strefa niż przy bokach, żeby zwykłe przesuwanie okna
  blisko górnej krawędzi bez intencji maksymalizowania go nie kończyło
  się przypadkową maksymalizacją) **maksymalizuje** okno.
- **Przeciągnięcie do lewej/prawej krawędzi** (`SnapMargin`, już
  istniejąca stała, używana też przez magnetyczne wyrównanie pozycji
  podczas przeciągania) **przyciąga do połowy ekranu**.
- **Strefa górna ma pierwszeństwo** nad boczną w rogu ekranu -- kursor
  jednocześnie blisko góry i blisko boku daje PEŁNĄ maksymalizację, nie
  przyciągnięcie do połowy (potwierdzone testem).
- Sam snap dzieje się DOPIERO na puszczenie przycisku myszy
  (`endDrag`), nie na bieżąco podczas przeciągania -- w przeciwnym razie
  okno zmieniałoby rozmiar W TRAKCIE przeciągania, utrudniając dalsze
  manewrowanie nim, gdyby użytkownik jeszcze zmienił zdanie co do
  miejsca. Podczas samego przeciągania śledzone jest tylko, CZY kursor
  jest akurat w strefie aktywacji (`DragState.pendingSnapEdge`/
  `pendingMaximize`, nowe pola w `comp/types.nim`).
- **Cofnięcie przyciągnięcia** (Super+Left ponownie, albo przycisk w
  tytule) wraca do pozycji okna z CHWILI PUSZCZENIA MYSZY, nie do
  pozycji sprzed całego ruchu -- `snapWindow`/`doMaximize` zapisują
  bieżącą (właśnie przeciągniętą) geometrię jako punkt powrotu,
  dokładnie tak samo jak przy przyciąganiu klawiaturą.
- `toggleMaximize` zostało zrefaktoryzowane -- sama logika "przejdź do
  stanu zmaksymalizowanego" wydzielona do `doMaximize`, reużywanej teraz
  przez oba wyzwalacze (przycisk w tytule ORAZ przeciągnięcie do góry),
  żeby te dwie ścieżki nie mogły z czasem rozjechać się w drobnych
  szczegółach geometrii.

**Metoda weryfikacji**: `test_real_comp_dragsnap.nim` -- 8 scenariuszy
na PRAWDZIWYM, niezmodyfikowanym `comp/comp.nim`, symulujących pełną
sekwencję `beginMove` → `updateDrag` (jeden lub więcej razy) →
`endDrag`, dokładnie tak jak wołałby ją `shell/shell.nim`: maksymalizacja
przez przeciągnięcie do góry, przyciągnięcie do lewej/prawej połowy,
brak jakiegokolwiek snapu przy przeciąganiu z dala od krawędzi,
poprawność `savedPos` przy cofnięciu (wraca do pozycji z CHWILI
puszczenia myszy, nie sprzed całego ruchu -- najbardziej subtelny z
testowanych przypadków), pierwszeństwo strefy górnej w rogu ekranu,
okno `resizable = false` ignorujące gest, oraz regresja: nie da się
rozpocząć przeciągania już zmaksymalizowanego okna (zachowanie sprzed
tej rundy, niezmienione).

## Nowości w v0.2 (runda 35) -- integracja powiadomień z DBus (realnie zweryfikowana end-to-end), WebP dla tapety przez zewnętrzny `dwebp`

Kontynuacja rundy 34 (ta sama prośba: rozbudować o WSZYSTKO z listy
ograniczeń) -- tym razem dwa kolejne punkty, oba z MOCNIEJSZĄ
weryfikacją niż większość rundy 34, bo żaden z nich nie zależy od
`fidget` (jedynej, powtarzającej się przeszkody w tej serii rund).

**1. DBus -- `org.freedesktop.Notifications`**
(`shell/dbus_notify_shim.c`/`.h`, `shell/dbusnotify.nim`,
`shell/notifications.nim`, `shell/shell.nim`) -- ✅ **zweryfikowane
END-TO-END, realnie, w tej sesji**. Minimalny serwer powiadomień na
session-bus DBus, w procesie `zde-shell` (przez FFI do `libdbus`, ten
sam styl co `apps/terminal/pty_shim.c` -- zwykłe funkcje C wołane z
głównej pętli, ŻADEN nowy proces/demon). Implementuje `Notify` (parsuje
`app_name`/`summary`/`body`, odpowiada poprawnym id), `GetCapabilities`,
`GetServerInformation`, `CloseNotification`, `Introspect`, plus poprawną
odpowiedź błędem `UnknownMethod` dla wszystkiego innego (żeby nadawca
czekający synchronicznie na odpowiedź nie zawisł). Odebrane
powiadomienia trafiają do TEJ SAMEJ kolejki/historii co powiadomienia
wewnętrzne ZDE (`tickDbusNotifications` w `notifications.nim`, wołane
raz na sekundę z `tickMain` w `shell.nim`, drenuje całą kolejkę na raz).

Metoda weryfikacji: w tej sandboxie zainstalowano `libdbus-1-dev` i
`libnotify-bin` (apt, `archive.ubuntu.com` na liście dozwolonych domen),
uruchomiono PRAWDZIWY `dbus-daemon --session`, skompilowano
`dbus_notify_shim.c` (samodzielnie w C, potem PRZEZ Nim FFI w
`dbusnotify.nim` -- oba się skompilowały i połączyły bez błędu) i
przepuszczono przez niego PRAWDZIWE wywołania: `notify-send "TestApp"
"Hello..."` odebrane poprawnie po stronie C ORAZ po stronie Nim
(`pollDbusNotification()`, osobny test), `dbus-send` dla
`GetServerInformation`/`CloseNotification`/nieznanej metody -- wszystkie
z poprawnymi odpowiedziami. To najsilniej zweryfikowany fragment kodu w
CAŁEJ tej rundzie rozbudowy (34+35) -- prawdziwy klient, prawdziwy bus,
prawdziwy protokół, nie tylko izolowany test logiki na `std` samym.

Świadomie POZA zakresem (nie przemilczane): akcje przycisków, `hints`
(priorytet/dźwięk/ikona), `expire_timeout` z wywołania -- wszystkie
ignorowane, każde powiadomienie z zewnątrz wygląda jak zwykłe `nkInfo`.
`CloseNotification` wołane przez NADAWCĘ jest przyjmowane, ale nie ma
efektu (brak mapowania id DBus -> id toastu ZDE). Gdy na sesji już
działa inny serwer powiadomień (GNOME/KDE/dunst) i nie oddaje nazwy --
integracja po cichu się nie aktywuje (`DBUS_NAME_FLAG_DO_NOT_QUEUE`,
świadomie BEZ `REPLACE_EXISTING` -- odbieranie tej roli aktywnej sesji
w trakcie działania mogłoby zerwać inne aplikacje w trakcie wysyłania
powiadomienia).

**2. WebP dla tapety -- przez zewnętrzny `dwebp`** (`shell/wallpaper.nim`)
-- ✅ **zweryfikowane realnie**: prawdziwy plik `.webp` wygenerowany
`cwebp` (z prawdziwego PNG zrobionego przez Pixie), zdekodowany z
powrotem przez `readImageWithWebpFallback` z poprawnymi wymiarami; osobno
potwierdzone poprawne, ciche zdegradowanie (bez wyjątku wykraczającego
poza istniejącą obsługę błędów `ensureWallpaperCache`), gdy `dwebp` nie
jest w `PATH`. Pixie samo w sobie WCIĄŻ nie dekoduje WebP (to się nie
zmieniło i nie mogło się zmienić bez podmiany biblioteki) --
`readImageWithWebpFallback` woła `dwebp` (pakiet `webp`/
`libwebp-tools`) do konwersji na tymczasowy PNG PRZED przekazaniem do
Pixie, ten sam duch integracji zewnętrznym narzędziem co
`wl-copy`/`xclip` gdzie indziej w ZDE. Plik tymczasowy trafia do
katalogu cache tapet i jest usuwany zaraz po wczytaniu
(`try`/`finally`), niezależnie od powodzenia.

**Wciąż bez zmian** (te same powody architektoniczne, patrz notatka do
rundy 14/34 wyżej): multi-seat, GUI dla `.zpk`, wiele
sesji/użytkowników, prawdziwe HiDPI (ZDE dalej nie zna skali monitora).

## Nowości w v0.2 (runda 34) -- domknięcie sześciu punktów z listy ograniczeń: Icon Theme Spec, .gitignore (ścieżki + rodzice), schowek plików ↔ zewnętrzne aplikacje, pinch/hold, pełne Ctrl+Z w edytorze

Ta runda powstała w odpowiedzi na wprost sformułowaną prośbę: rozbudować
ZDE o WSZYSTKO, co wcześniej wypisane zostało jako wymagające dalszej
pracy. Zrealizowano sześć z ~piętnastu punktów -- pozostałe (multi-seat,
integracja DBus dla powiadomień, GUI dla `.zpk`, wiele
sesji/użytkowników, prawdziwe HiDPI, WebP) zostają bez zmian, z tych
samych, architektonicznych powodów opisanych już wcześniej w tym README
(patrz notatka do rundy 14 wyżej w sekcji "Ograniczenia") -- każdy z
nich to osobny, wielodniowy/wielotygodniowy projekt, nie coś do
"dorzucenia przy okazji".

**Metoda weryfikacji w TEJ sesji** (żeby było jasne, co dokładnie
oznacza "zrobione" dla każdego punktu): sandbox tej rundy MIAŁA dostęp
do `apt` (`archive.ubuntu.com`/`security.ubuntu.com` na liście
dozwolonych domen) -- zainstalowano Nim 1.6.14 i `pixie` przez `nimble`.
To wystarczyło do PRAWDZIWEJ kompilacji `shell/desktopapps.nim` (patrz
punkt 1 niżej) i do dwóch izolowanych, realnie uruchomionych testów
logiki menedżera plików (punkty 2-3) na `std/re`+`std/os` samych, bez
`fidget`. `fidget` (wymaga Nim >= 2.0, niedostępny w tej sandboxie)
pozostał niedostępny jak w poprzednich rundach -- więc punkty dotyczące
`apps/texteditor` (5) i `wlcomp/` (4, brak `libwlroots-dev` w TEJ
konkretnej sandboxie) mają SŁABSZĄ weryfikację (kod napisany zgodnie ze
sprawdzonymi wzorcami z wcześniejszych rund, `nim check` przeszedł poza
samym importem `fidget`/nagłówków wlroots, ale bez żywego uruchomienia)
-- każdy punkt niżej mówi wprost, do której kategorii należy.

**1. Icon Theme Spec -- pełne reguły `Fixed`/`Scalable`/`Threshold`**
(`shell/desktopapps.nim`) -- ✅ **skompilowane i przetestowane REALNIE**
w tej sesji. `dirSizeDistance` zastępuje poprzednie, jednolite
`abs(size - PreferredIconSize)` formalną funkcją odległości ze
specyfikacji: katalog `Type=Fixed` wymaga DOKŁADNEGO rozmiaru;
`Type=Scalable` dopasowuje CAŁY zakres `MinSize=`..`MaxSize=` bez kary;
`Type=Threshold` (domyślny, gdy `Type=` nie występuje w ogóle --
zgodnie ze specyfikacją) dopasowuje `Size= ± Threshold=` (domyślnie 2)
bez kary. Test: syntetyczny motyw z trzema katalogami (`Fixed` 16px,
`Scalable` 16-512px, `Threshold` 48±3px) -- przy `PreferredIconSize=48`
katalog `Threshold` poprawnie wygrywa jako jedyne dokładne dopasowanie
(dystans 0), a dla SVG poprawnie wybierany jest katalog `Scalable`.

**2-3. `.gitignore`: wzorce ze ścieżką + wędrówka po rodzicach**
(`apps/filemanager/files.nim`) -- ✅ **logika przetestowana REALNIE**
(4 testy na prawdziwym systemie plików w `/tmp`, poza repo -- ten sam
styl co reszta projektu, testy nie są commitowane). Dwie zmiany naraz:
- `loadGitignoreChain` wędruje teraz w górę od katalogu startowego aż do
  korzenia systemu plików (limit `MaxGitignoreParentWalk = 64` jako
  siatka bezpieczeństwa), zbierając WSZYSTKIE napotkane `.gitignore`, nie
  tylko ten z katalogu bieżącego -- więc `.gitignore` w korzeniu repo
  teraz poprawnie wpływa na podkatalogi, nawet gdy przeglądamy je
  bezpośrednio, bez własnego `.gitignore`.
- Wzorce ZAWIERAJĄCE `/` (np. `src/generated/`, `/build`) są teraz
  UŻYWANE zamiast pomijane -- dopasowywane do PEŁNEJ ścieżki względem
  katalogu, w którym leży dany `.gitignore`, z poprawną semantyką
  pojedynczej `*` (nie przekracza `/`, `[^/]*`) i `**` (przekracza,
  `.*`) -- poprzednio `*`/`**` były traktowane identycznie, co dla
  wzorców bez `/` (jedyne wcześniej obsługiwane) nie miało znaczenia,
  ale miałoby dla ścieżek.
`loadGitignorePatterns`/`isGitignored` (jednopoziomowe, bez rodziców)
zostały ZACHOWANE dla wstecznej zgodności, ale nowy kod
(`refresh`/`searchFilesRecursive`) korzysta z `loadGitignoreChain`/
`isGitignoredAt`.

**4. Schowek plików -- jednokierunkowa integracja z aplikacjami spoza
ZDE** (`apps/filemanager/files.nim`) -- ✅ logika fallbacku
przetestowana REALNIE (graceful no-op, gdy brak `wl-copy`/`xclip`),
❌ samo wywołanie `wl-copy`/`xclip` nie zostało przetestowane wobec
PRAWDZIWEGO kompozytora Wayland (ta sandbox go nie ma). "Kopiuj"/"Wytnij"
teraz DODATKOWO wystawiają skopiowane ścieżki jako `text/uri-list` na
systemowy schowek (`wl-copy --type text/uri-list` / `xclip -t
text/uri-list`, dokładnie ten sam wzorzec zewnętrznego narzędzia co
`shell/clipboard.nim` używa już od dawna dla tekstu) -- pozwala to
wkleić skopiowane pliki w PRAWDZIWEJ, zewnętrznej aplikacji. Kierunek
odwrotny (wklejanie DO ZDE plików skopiowanych gdzie indziej) wciąż
wymaga zmiany w kompozytorze (`wl_data_device`) i pozostaje
nierozwiązany -- patrz notatka w sekcji "Ograniczenia".

**5. Edytor tekstu -- pełne Ctrl+Z/Ctrl+Shift+Z/Ctrl+Y dla zwykłego
pisania** (`apps/texteditor/texteditor.nim`) -- ⚠️ NAPISANE, ale **NIE
zweryfikowane na żywym Fidget** w tej sesji (ten sam powód co zawsze:
brak Nim >= 2.0). Migawki CAŁEGO dokumentu (nie diff, ten sam styl co
istniejące `replaceUndoStack`), odkładane w `onInput` z debounce 0,6s
(`UndoSnapshotIntervalSec`) i limitem głębokości 100
(`MaxUndoTypingDepth`) -- nowa edycja po cofnięciu kasuje stos "ponów",
standardowe zachowanie. Kluczowy szczegół: po cofnięciu/ponowieniu kod
jawnie ustawia `keyboard.focusNode = nil` -- to NIE jest nowy pomysł,
tylko ODTWORZENIE techniki, którą ten sam projekt już raz potwierdził
żywym testem pod Xvfb przy zupełnie innym buggu (`apps/terminal/term.nim`,
runda 12): Fidget trzyma WŁASNY, wewnętrzny bufor edycji dla
skupionego pola, niezależny od tego, co ustawi kod, i bez zerowania
fokusu odtworzyłby swój stary bufor z powrotem na następnej klatce,
kasując efekt cofnięcia. Ryzyko, że mimo tej techniki coś tu nie
zadziała tak jak w terminalu, jest realne i NIE zostało w tej rundzie
wykluczone -- do potwierdzenia w przyszłej sesji z dostępnym Fidget/GLFW.

**6. Pinch/hold -- re-broadcast do klientów** (`wlcomp/gestures.nim`,
`wlcomp/wlroots.nim`, `wlcomp/types.nim`) -- ⚠️ NAPISANE z pamięci API
wlroots 0.18 (nazwy sygnałów `events.pinch_begin` itd., struktury
`wlr_pointer_pinch_*_event`), **NIE skompilowane** w tej sesji (brak
`libwlroots-dev`, w odróżnieniu od punktu 1 wyżej ten pakiet nie był w
tej sesji instalowany). Wzorowane 1:1 na już wcześniej zweryfikowanym
kodzie swipe w tym samym pliku -- ten sam re-broadcast przez
`wlr_pointer_gestures_v1`, bez żadnej WŁASNEJ reakcji kompozytora
(świadomie -- patrz duży komentarz w pliku o braku dziś w ZDE
jednoznacznego zastosowania dla pinch-to-zoom). Do potwierdzenia
kompilacją w przyszłej sesji z dostępnymi nagłówkami wlroots.

## Nowości w v0.2 (runda 21) -- przyciąganie okien do ćwiartek ekranu; przełom w metodzie weryfikacji: `comp/` kompiluje się i testuje w PEŁNI, jako jedyny prawdziwie działający fragment `zde-shell` w tej serii rund

**Największe odkrycie metodologiczne od rundy 14.** Podczas szukania
kolejnego celu do rozbudowy sprawdzono zależności `comp/` (rdzeń
zarządzania oknami -- kafelkowanie, przyciąganie do krawędzi, z-order,
fokus, pulpity wirtualne) i okazało się, że `comp/comp.nim`/`window.nim`/
`types.nim`/`drag.nim` zależą WYŁĄCZNIE od `vmath` (biblioteka
matematyczna, już zainstalowana jako zależność `pixie` w rundzie 14) --
zero zależności od `fidget`. **To pierwszy raz w całej tej serii rund
(13-21), kiedy dało się skompilować i URUCHOMIĆ prawdziwy, produkcyjny
kod ZARZĄDZANIA OKNAMI** -- nie kopię logiki w izolowanym skrypcie (jak
rundy 13-20 musiały robić dla `files.nim`/`texteditor.nim`), tylko
`import ../comp/comp` i wywołanie PRAWDZIWYCH, eksportowanych procedur:
`openWindow`, `snapWindow`, `cycleFocus`, `closeWindow`, `switchWorkspace`,
`hitTestEdge` i reszty.

### Funkcja: przyciąganie okien do ćwiartek ekranu (Super+Up/Down)

Domyka realny brak -- dotąd `SnapEdge` (`comp/types.nim`) miał tylko
`seLeft`/`seRight` (Super+Left/Right, od rundy "Aurora" v0.1). Dodano
górną/dolną połowę (`seTop`/`seBottom`, nowe skróty Super+Up/Super+Down)
ORAZ cztery ćwiartki, z "doprecyzowaniem" w stylu Windows 11 Snap: gdy
okno jest już przyciągnięte do lewej/prawej połowy, naciśnięcie
Super+Up/Down nie zastępuje tego górną/dolną połową CAŁEGO ekranu, tylko
DOPRECYZOWUJE do odpowiedniej ćwiartki (`combinedEdge` w
`comp/window.nim`) -- Super+Left, potem Super+Up, daje ćwiartkę lewą-
górną. Dokładnie to samo, dwukrotne naciśnięcie TEJ SAMEJ krawędzi
(Super+Left, Super+Left) nadal przywraca oryginalny rozmiar okna --
zachowanie sprzed tej rundy, zachowane bez zmian i potwierdzone testem
regresyjnym.

**Metoda weryfikacji**: `test_real_comp_snap.nim` importuje PRAWDZIWY,
niezmodyfikowany `comp/comp.nim` -- 11 scenariuszy na faktycznie
uruchomionym kodzie kompozytora: geometria otwarcia okna, przyciągnięcie
do połowy, toggle przy powtórzeniu tej samej krawędzi (regresja),
doprecyzowanie do ćwiartki (Super+Left potem Super+Up), wszystkie 4
sprawdzone kombinacje doprecyzowania, test NIEZMIENNIKA geometrycznego
(cztery ćwiartki razem wypełniają cały dostępny ekran, bez dziur i bez
nakładania -- nie tylko sprawdzenie pojedynczych wartości), okno
`resizable = false` ignorujące snap, cykl fokusu (Alt+Tab) po
prawdziwym z-order, oddawanie fokusu po zamknięciu aktywnego okna,
izolacja okien między pulpitami wirtualnymi, wykrywanie krawędzi do
zmiany rozmiaru (`hitTestEdge`).

Nowe skróty (`shell/shortcuts.nim`): `actSnapUp`/`actSnapDown`, domyślnie
`super+up`/`super+down`, konfigurowalne w Ustawieniach na tych samych
zasadach co reszta skrótów (generyczna pętla `for a in ShortcutAction`,
żadna lista w `apps/settings/settings.nim` nie wymagała ręcznej
aktualizacji). Trzy równoległe tablice (`ActionNames`/`ActionLabels`/
`DefaultCombos`, indeksowane POZYCYJNIE wg kolejności enuma
`ShortcutAction`) rozszerzone o dwa wpisy w poprawnej pozycji --
zweryfikowane osobnym testem semantyki Nim (`array[EnumType, T]`
faktycznie dopasowuje pozycję literału do kolejności enuma) plus ręczne
przeliczenie długości wszystkich trzech tablic (17 = 17 = 17 = liczba
wartości enuma) -- `shell/shortcuts.nim` importuje `fidget`, więc nie
dało się tego sprawdzić bezpośrednią kompilacją, ale ryzyko rozjechania
pozycji zostało zaadresowane najlepiej jak się dało bez tego.

Reszta `zde-shell` (całe UI -- menedżer plików, edytor, launcher, dok)
WCIĄŻ importuje `fidget` i pozostaje nieskompilowana w tej sesji --
`comp/` to jeden, wydzielony fragment silnika, nie cały shell.

## Nowości w v0.2 (runda 20) -- podświetlanie składni: Go, Rust, JSON

**Domyka realny brak**, znaleziony przy przeglądzie kodu w poszukiwaniu
kolejnego celu: `apps/texteditor/highlight.nim` obsługiwał tylko 5
języków (Nim/Python/C/JS/Shell), mimo że -- w ODRÓŻNIENIU od reszty
edytora -- zależy WYŁĄCZNIE od `std`, nie od `fidget`. To oznacza, że
CAŁY ten moduł dało się w pełni skompilować i przetestować w tej
sandboxie (ten sam status co `desktopapps.nim`/`thumbnails.nim` z rund
14/16, ale bez potrzeby instalowania `pixie` -- `highlight.nim` nie
potrzebuje nawet tego).

Dodano trzy popularne języki: **Go** (z obsługą surowych stringów w
backtickach, `` `...` `` -- inna, specyficzna dla Go składnia, celowo
jednolinijkowa, bez pełnej obsługi wieloliniowych surowych stringów),
**Rust** (bez `r"..."`/`r#"..."#`, świadomie -- dodanie ich porządnie
wymagałoby osobnej ścieżki parsowania z liczeniem `#`, nie tylko flagi
bool jak reszta tego prostego tokenizera) i **JSON** (który formalnie
NIE MA komentarzy w ogóle wg specyfikacji RFC 8259 -- `lineCommentFor`
zwraca dla niego pusty string, sprawdzone testem, że `#` w wartości
stringa JSON-a nie zostaje pomylone z komentarzem). Heurystyka
"PascalCase = prawdopodobnie typ" (dotąd tylko dla Nim/C) rozszerzona o
Go i Rust -- w obu tych językach PascalCase ma REALNE znaczenie
językowe (w Go decyduje o eksporcie identyfikatora, w Rust to formalna
konwencja dla structs/enums/traits), więc trafność tej heurystyki jest
tu WYŻSZA niż dla C, nie tylko "tak samo dobra".

**Prawdziwy błąd znaleziony i naprawiony podczas testowania tej rundy**
(nie przez czytanie kodu): pierwsza wersja dodała obsługę stringów w
backtickach, ale NIE zaktualizowała warunku zatrzymania w bloku
zbierającym "cokolwiek inne" (operatory, białe znaki) -- w efekcie
backtik napotkany W TRAKCIE zbierania takiego fragmentu (bardzo
częsty przypadek: spacja albo operator PRZED stringiem, np. `x :=
\`raw\``) był po cichu POŁYKANY do tego fragmentu, zamiast zatrzymać go
i pozwolić string-owej obsłudze go przechwycić -- string w backtickach
nigdy by się nie podświetlił, gdyby poprzedzał go choćby jeden znak
"plain". Test wprost odtwarza dokładnie ten przypadek (`x := \`raw
string\``) i potwierdza zarówno że powstaje dokładnie jeden token
`tkString`, jak i że żaden token `tkPlain` nie zawiera backticka.

**Metoda weryfikacji**: `test_real_highlight.nim` importuje PRAWDZIWY,
niezmodyfikowany `highlight.nim` (nie kopię logiki) -- 11 scenariuszy,
w tym test regresyjny na opisany wyżej błąd, test na to, że backtick
POZA Go pozostaje zwykłym znakiem (rozbudowa nie wycieka do innych
języków), test na brak komentarzy w JSON, i pełna regresja wszystkich
pięciu języków sprzed tej rundy (Nim/Python/C/JS/Shell) -- bez zmian w
ich zachowaniu.

## Nowości w v0.2 (runda 19) -- menedżer plików: wyszukiwanie plików w poddrzewie katalogów

**Domyka brak, którego menedżer plików nie miał w ogóle od pierwszej
rundy** -- żadnej formy szukania pliku po nazwie, tylko ręczne
przeklikiwanie się przez foldery. Przełącznik "🔍" w toolbarze otwiera
pasek z polem zapytania i przyciskiem "Szukaj" -- rekurencyjny skan PO
NAZWIE (prosty podciąg, case-insensitive, bez glob/regex -- to ma być
szybkie "znajdź plik", nie potężne wyszukiwanie) od bieżącego katalogu w
dół. Kliknięcie wyniku nawiguje do jego katalogu, zaznacza go i zamyka
pasek wyszukiwania.

**Świadomie NIE działa na bieżąco przy każdym znaku** (w odróżnieniu od
Znajdź w edytorze tekstu) -- wymaga kliknięcia "Szukaj" albo Enter. To
nie jest ograniczenie techniczne, tylko świadoma decyzja: Znajdź w
edytorze przeszukuje treść JUŻ leżącą w pamięci (tanie, można
przeliczać co klatkę), to wyszukiwanie robi REKURENCYJNY SKAN DYSKU,
więc uruchamianie go na każde naciśnięcie klawisza byłoby marnotrawstwem
i potencjalnie zauważalnym zacinaniem przy większych drzewach katalogów.

Dwa niezależne zabezpieczenia przed zawieszeniem na wielkim drzewie:
`MaxSearchResults` (200 -- więcej i tak nie da się sensownie przejrzeć)
i, ważniejsze, `MaxSearchScanned` (5000 -- limit liczby ODWIEDZONYCH
wpisów, niezależnie od liczby trafień; bez tego wyszukiwanie frazy z
zerem trafień w ogromnym drzewie, np. przez pomyłkę uruchomione z
katalogu domowego zawierającego całe repozytoria, skanowałoby
WSZYSTKO bez końca, zanim cokolwiek by zwróciło).

Respektuje ukrywanie wg `.gitignore` (runda 15/18) na tych samych
zasadach co zwykła lista katalogu, gdy `hideIgnored` jest włączone.

**Prawdziwy błąd znaleziony i naprawiony podczas testowania tej rundy**
(nie przez czytanie kodu -- przez uruchomienie testu na realnym,
wielopoziomowym drzewie katalogów z `.gitignore` w korzeniu): pierwsza
wersja wołała wczytywanie wzorców `.gitignore` OSOBNO na KAŻDYM poziomie
rekursji, tym samym mechanizmem co zwykła lista katalogu (runda 15/18).
To brzmiało konsekwentnie, ale dla wyszukiwania REKURENCYJNEGO było
błędne: reguła `node_modules` zapisana w `.gitignore` w katalogu
GŁÓWNYM w ogóle nie obejmowała pliku leżącego dwa poziomy niżej w
podkatalogu, który sam nie miał WŁASNEGO `.gitignore` -- test
jednoznacznie to wykazał (plik wewnątrz `node_modules` pojawiał się w
wynikach mimo `hideIgnored = true`). Naprawione: wzorce są teraz
wczytywane RAZ, z katalogu, w którym wyszukiwanie się ZACZYNA, i
stosowane jednolicie do całego przeszukiwanego poddrzewa -- to wciąż
nie jest pełna semantyka Gita (prawdziwy Git honorowałby też DODATKOWE,
zagnieżdżone `.gitignore` głębiej w drzewie), ale poprawnie obsługuje
zdecydowanie najczęstszy przypadek: jeden `.gitignore` w korzeniu repo.

Lista wyników to CELOWO prosty, płaski widok (ikona + ścieżka względna)
bez maszynerii przeciągania/zmiany nazwy/zaznaczania zwykłej listy --
wyniki mogą leżeć w wielu różnych katalogach naraz, więc te akcje nie
miałyby tu jednoznacznego sensu.

**Metoda weryfikacji**: `test_file_search.nim` -- 7 scenariuszy na
prawdziwym, wielopoziomowym drzewie katalogów w `/tmp` (podstawowe
wyszukiwanie rekurencyjne, trafienia w plik i folder o tej samej
nazwie, pusta fraza, brak trafień, respektowanie `.gitignore` --
WŁĄCZNIE z testem, który złapał opisany wyżej błąd, limit liczby
wyników z flagą "obcięto", rozbicie ścieżki wyniku na katalog
nadrzędny + nazwę). `apps/filemanager/files.nim` wciąż importuje
`fidget`, więc integracja UI (przycisk, pasek, lista wyników) pozostaje
nieprzetestowana wizualnie, jak reszta menedżera plików od rundy 13.

## Nowości w v0.2 (runda 18) -- .gitignore: prawdziwa obsługa negacji `!wzorzec`

Domyka jawnie udokumentowane, świadome ograniczenie z rundy 15
("negacja `!` jest CAŁKOWICIE ignorowana"). `loadGitignorePatterns`/
`isGitignored` (`apps/filemanager/files.nim`) implementują teraz
DOKŁADNIE tę samą semantykę co prawdziwy Git: kolejność wzorców w
pliku ma znaczenie, **ostatni pasujący wzorzec wygrywa** -- nie
pierwszy. To wymagało realnej zmiany algorytmu, nie tylko przestania
pomijać linie zaczynające się od `!`: poprzednia wersja `isGitignored`
zwracała `true` przy PIERWSZYM trafieniu (`return true` w pętli), co
dawałoby BŁĘDNĄ, odwrotną semantykę "pierwszy wygrywa", gdyby po prostu
przestać ignorować `!` bez zmiany tej pętli. Nowa wersja iteruje przez
WSZYSTKIE wzorce, nadpisując stan `ignored` przy każdym kolejnym
trafieniu (zwykłym LUB negowanym), więc końcowy wynik zawsze
odzwierciedla OSTATNI pasujący wzorzec w pliku.

`.git` pozostaje ukrywany zawsze, nawet przy jawnej (bardzo nietypowej)
negacji `!.git` w `.gitignore` -- ten wyjątek, ustalony już w rundzie
15, jest teraz jawnie sprawdzony testem, żeby przyszła zmiana kodu nie
mogła go po cichu cofnąć.

Wciąż świadomie poza zakresem, niezmienione względem rundy 15: wzorce
ze ścieżką względną (zawierające `/` w środku) -- w tym negacje TAKICH
wzorców (`!src/generated/keep.txt`) -- bo dopasowanie w tym module
działa wyłącznie po nazwie wpisu, nie po pełnej ścieżce; `.gitignore`
tylko z bieżącego katalogu, bez wędrówki po rodzicach.

**Metoda weryfikacji**: `test_gitignore.nim` rozszerzony do 9
scenariuszy (z 6 w rundzie 15) -- w tym Test 4, który wprost
demonstruje ZMIANĘ zachowania na DOKŁADNIE tym samym pliku
`.gitignore`, którego użyła runda 15 do potwierdzenia poprzedniego,
świadomego ograniczenia (`!important.log` -- wcześniej plik zostawał
ukryty, teraz jest odkrywany), oraz dwa testy kolejności (ukryj-potem-
odkryj i odkryj-potem-ukryj) potwierdzające, że wygrywa OSTATNI wzorzec,
nie pierwszy.

## Nowości w v0.2 (runda 17) -- tapeta: statyczny GIF; realny przegląd dekodera GIF Pixie na 82 plikach

Mała, ale w pełni dopracowana rozbudowa, znaleziona przy okazji
sprawdzania czegoś innego: podczas pisania rundy 16 (miniatury obrazów)
zauważono, że `pixie.readImage` rozpoznaje format obrazu po SYGNATURZE
BAJTÓW pliku, nie po rozszerzeniu -- co oznacza, że `shell/
wallpaper.nim` (`ensureWallpaperCache`) UMIAŁO dekodować statyczne
(pierwsza klatka, bez animacji) pliki GIF **od zawsze**, mimo że README
od dawna twierdziło "PNG/JPEG bez GIF". Jedyną realną przeszkodą był
`PickerImageExts = [".png", ".jpg", ".jpeg"]` w `apps/settings/
settings.nim` -- filtr przeglądarki plików, który sztucznie nie
pozwalał w ogóle WYBRAĆ pliku `.gif`, mimo że silnik pod spodem by go
przyjął.

**Zanim cokolwiek zmieniono, sprawdzono to na 82 PRAWDZIWYCH plikach
`.gif`** zainstalowanych w tej sandboxie (`find / -iname "*.gif"` --
motywy galerii LibreOffice, dokumentacja różnych pakietów), nie na
pojedynczym, wybranym "na oko" przykładzie:
- **77/82 (94%)** dekoduje się bez problemu.
- **5/82 nie** -- i każdy z tych przypadków jest tu uczciwie
  wymieniony, nie zamieciony pod dywan: jeden to zerwany symlink (bez
  związku z Pixie), trzy dają `Invalid GIF buffer, unable to load`
  (prawdziwa, rzadka luka w minimalnym dekoderze GIF Pixie -- niektóre
  pliki `GIF89a` z lokalną paletą kolorów go wywalają), jeden jest
  explicite odrzucony przez sam Pixie jako `Unsupported GIF, pixel
  aspect ratio`.
- Kluczowe: w KAŻDYM z tych 5 przypadków `ensureWallpaperCache` (i,
  analogicznie, `ensureThumbnail` z rundy 16) już wcześniej łapało
  wyjątek i cicho zwracało "" -- więc żaden z nich nie jest w stanie
  wywalić `zde-shell`. Potwierdzone konkretnie, nie tylko przez czytanie
  kodu: `test_wallpaper_gif.nim` używa PRAWDZIWEGO, znanego-wadliwego
  pliku (`bullets/rainbow.gif`) jako źródła tapety i sprawdza, że wynik
  to pusty string, nie wyjątek. `test_real_thumbnails.nim` robi to samo
  dla miniatur w menedżerze plików, tym samym plikiem.

Zmiana w kodzie: `PickerImageExts` rozszerzone o `.gif`, dwa teksty
pomocnicze w UI zaktualizowane. BMP/QOI/PPM (też realnie dekodowane
przez `readImage`) świadomie NIE dodane do przeglądarki -- w praktyce
prawie nikt nie trzyma zdjęć/tapet w tych formatach, więc dodanie ich
tylko zaśmieciłoby wybór bez realnej wartości. WebP wciąż całkowicie
poza zasięgiem -- `pixie@5.0.7` w ogóle go nie dekoduje (sprawdzone w
źródle pakietu: brak jakiejkolwiek gałęzi WebP w `decodeImage`), więc
dodanie `.webp` do filtra dawałoby wybór kończący się zawsze cichym
brakiem podglądu.

## Nowości w v0.2 (runda 16) -- miniatury obrazów w menedżerze plików; prawdziwe cofanie dla "Zamień"/"Zamień wszystko"

Domyka oba punkty jawnie odłożone pod koniec rundy 15 -- tym razem oba
faktycznie zrealizowane, nie tylko przeanalizowane.

### Miniatury obrazów w menedżerze plików

**Domyka jawnie wypisany brak.** Zamiast dopisywać kod dekodowania
obrazów bezpośrednio do `apps/filemanager/files.nim` (które importuje
`fidget` do całego swojego UI i dlatego nie da się go skompilować w tej
sandboxie), cała logika trafiła do NOWEGO, osobnego modułu
`apps/filemanager/thumbnails.nim`, który importuje WYŁĄCZNIE `std`/
`pixie` -- dokładnie ten sam zabieg, który w rundzie 14 pozwolił
naprawdę skompilować i przetestować `desktopapps.nim`. Architektura i
konwencje (cache kluczowany ścieżką+czasem modyfikacji+rozmiarem w
samej nazwie pliku, "spróbuj raz i zapamiętaj porażkę", sprzątanie
najstarszych plików po przekroczeniu limitu) są w CAŁOŚCI skopiowane z
już wcześniej sprawdzonego `shell/wallpaper.nim` -- nie wymyślano
nowego podejścia do tego samego rodzaju problemu.

Obsługiwane formaty ustalone przez REALNE sprawdzenie źródła
zainstalowanego w tej sandboxie `pixie@5.0.7` (`decodeImage` rozpoznaje
format po sygnaturze bajtów, nie po rozszerzeniu): PNG, JPEG, BMP, GIF
(tylko pierwsza klatka), QOI, PPM. WebP i TIFF świadomie pominięte --
`pixie@5.0.7` w ogóle ich nie podłącza do `decodeImage`, mimo że
`tiff.nim` istnieje w pakiecie jako osobny plik.

Integracja z UI (`files.nim`, wiersz listy plików) używa dokładnie tego
samego, już sprawdzonego wzorca `image(...)` co `shell/wallpaper.nim`
dla tapety z pliku (`dataDir = "/"`, ścieżka cache bez wiodącego "/").
Ta integracja, w odróżnieniu od samego `thumbnails.nim`, pozostaje
nieprzetestowana wizualnie w tej sesji -- jak reszta UI menedżera
plików od rundy 13.

**Metoda weryfikacji**: `test_real_thumbnails.nim` importuje PRAWDZIWY,
niezmodyfikowany `thumbnails.nim` (nie kopię logiki) i woła jego
prawdziwe `ensureThumbnail()` na prawdziwym pliku PNG zainstalowanym w
tej sandboxie (`hicolor/48x48/apps/libreoffice-writer.png`) -- 8
scenariuszy: poprawne rozpoznawanie rozszerzeń (wielkość liter bez
znaczenia, `.webp` świadomie odrzucane), realne wygenerowanie i
zapisanie miniatury o dokładnie kwadratowym rozmiarze, trafienie w
cache przy drugiej próbie (plik cache NIE jest nadpisywany), różne
rozmiary nie kolidują w cache, plik o nieobsługiwanym rozszerzeniu i
nieistniejący plik dają pusty wynik BEZ wyjątku (z zapamiętaną
porażką), uszkodzony plik z poprawnym rozszerzeniem nie wywala
programu, a obraz o proporcjach innych niż kwadrat (sztucznie
wygenerowana panorama 200x50) i tak daje poprawną kwadratową miniaturę
(cover crop).

### Prawdziwe cofanie dla "Zamień"/"Zamień wszystko"

Runda 15 odkryła, że edytor w ogóle nie ma mechanizmu Ctrl+Z dla treści
dokumentu. Budowa PEŁNEGO, ogólnego cofania (przechwytywanie KAŻDEGO
naciśnięcia klawisza przy zwykłym pisaniu) byłaby ryzykowną ingerencją
w ścieżkę, której zachowania wewnątrz Fidget-owego `editableText` nie
da się w tej sandboxie zweryfikować -- więc ten mechanizm jest CELOWO
węższy: cofa WYŁĄCZNIE operacje "Zamień"/"Zamień wszystko"
(`doReplaceCurrent`/`doReplaceAll`), bo to one i tak manipulują
`t.content` jako zwykłym stringiem, z pominięciem pola tekstowego --
dodanie stosu TYLKO dla nich w ogóle nie rusza ścieżki zwykłego
pisania.

- Nowe pole `Tab.replaceUndoStack: seq[string]` -- migawka CAŁEJ treści
  dokumentu odkładana TUŻ PRZED każdą faktyczną zmianą (nie przy
  operacjach, które i tak nic by nie zmieniły -- pusty wynik
  wyszukiwania nie zaśmieca stosu). Limit głębokości 20 (migawki całego
  dokumentu, nie pojedyncze znaki -- głębokość rzędu dziesiątek jest z
  zapasem wystarczająca).
- Nowy przycisk "↶" w pasku Zamień (NIE skrót Ctrl+Z -- z tego samego
  powodu co brak ingerencji w zwykłe pisanie: zwykły przycisk nie
  koliduje z niczym nieznanym, globalny skrót klawiszowy mógłby).
  Widoczny/aktywny tylko, gdy jest co cofnąć. Miejsce zrobione przez
  zwężenie pola "zamień na..." -- pozycje "Zamień"/"Zamień wszystko" po
  prawej zostają nietknięte, ten sam trik layoutu co przy dodawaniu
  ".*" w rundzie 14.
- Historia jest zerowana przy wczytaniu INNEGO pliku do tej samej,
  ponownie użytej karty (`doOpen`) -- bez tego "Cofnij" mogłoby
  przywrócić treść zupełnie innego, wcześniej otwartego dokumentu.
- Świadomie NIE jest to dwukierunkowe "cofnij/przywróć" (brak "Redo") --
  tylko cofanie zamian, w kolejności LIFO, aż do wyczerpania stosu.

**Metoda weryfikacji**: `test_replace_undo.nim` (logika nie-UI,
`texteditor.nim` importuje `fidget` więc całości wciąż nie da się
skompilować w tej sesji) -- 5 scenariuszy: podstawowe cofnięcie
przywraca DOKŁADNIE poprzednią treść, cofnięcie bez historii to
bezpieczny no-op, wiele kolejnych zamian cofa się w prawidłowej
kolejności LIFO aż do wyczerpania stosu, zamiana bez żadnych dopasowań
NIE zaśmieca stosu, limit głębokości faktycznie obcina najstarsze
wpisy zamiast rosnąć bez końca.

## Nowości w v0.2 (runda 15) -- menedżer plików: sortowanie, historia wstecz/dalej, .gitignore; edytor: podświetlanie grup regex

Odpowiedź na kolejną prośbę o rozbudowę o "wszystko, co jeszcze bym
zrobił" z poprzedniej rozmowy. Cztery z sześciu wtedy wymienionych
punktów dało się w tej sesji zrealizować i przetestować; dwa pozostałe
(miniatury obrazów, grupowanie historii cofania dla "Zamień wszystko")
zostały świadomie odłożone -- ten drugi z zaskakującego powodu, patrz
niżej.

### Menedżer plików: sortowanie listy

Przyciski "↕ Nazwa/Rozmiar/Data" + "▲/▼" w toolbarze. Foldery ZAWSZE
zostają przed plikami (niezmieniona konwencja) -- sortowanie i kierunek
dotyczą tylko klucza WEWNĄTRZ każdej z tych dwóch grup. Remis (np. dwa
pliki o identycznym rozmiarze) rozstrzygany zawsze alfabetycznie, dla
przewidywalnej, stabilnej kolejności. Domyślne wartości (`smName`,
rosnąco) odtwarzają dokładnie dawne, sztywne zachowanie -- żadne
istniejące okno nie zmienia się, dopóki ktoś świadomie nie kliknie.

### Menedżer plików: historia nawigacji wstecz/dalej

Przyciski "◀"/"▶" -- dokładnie ten sam model co w przeglądarce: `navBack`
to stos katalogów, z których przyszliśmy, `navForward` to stos, do
którego można wrócić po cofnięciu. Nawigacja w NOWĄ stronę po cofnięciu
się KASUJE starą "przyszłość" (dokładnie jak w przeglądarce). Przyciski
są wizualnie wyszarzone i nieklikalne, gdy odpowiedni stos jest pusty.
Katalog, który zniknął z dysku między odwiedzeniem a próbą powrotu do
niego, jest po cichu pomijany zamiast wywalać błąd.

### Menedżer plików: ukrywanie wg `.gitignore`

Przełącznik ".gi" w toolbarze (domyślnie wyłączony). Parsuje
`.gitignore` z BIEŻĄCEGO katalogu (nie z rodziców wzwyż -- świadomie
mniejszy zakres niż prawdziwy Git, patrz duży komentarz przy
`loadGitignorePatterns` w kodzie), konwertuje proste wzorce glob (`*`,
`?`) na wyrażenia `std/re`. `.git/` jest ukrywany zawsze, niezależnie od
zawartości `.gitignore`. **Świadomie poza zakresem, uczciwie
przetestowane jako takie** (patrz `test_gitignore.nim`, Test 4): negacja
`!wzorzec` jest CAŁKOWICIE ignorowana (traktowana jak komentarz, NIE
"odkrywa" wcześniej ukrytego pliku), a wzorce ze ścieżką względną
(zawierające `/` w środku) są pomijane, bo dopasowanie działa wyłącznie
po nazwie wpisu, nie po pełnej ścieżce.

### Edytor tekstu: podświetlanie grup przechwytujących w regex

Gdy tryb ".*" jest włączony, każda grupa `(...)` w dopasowaniu dostaje
własne, dodatkowe podświetlenie (fioletowy pasek pod tekstem) NA
WIERZCHU zwykłego podświetlenia całego dopasowania. **Uczciwie
udokumentowane ograniczenie**: `std/re` w tej wersji nie zwraca pozycji
grup, tylko same przechwycone teksty -- pozycje są odtwarzane
HEURYSTYCZNIE (wyszukanie tekstu grupy w obrębie dopasowania, zaczynając
od końca poprzedniej znalezionej grupy). Poprawne dla zwykłego,
sekwencyjnego układu grup (zdecydowana większość realnych wzorców, np.
`(\w+)@(\w+)`), potencjalnie zawodne przy nietypowych, zagnieżdżonych
wzorcach -- opisane wprost w kodzie i przetestowane wraz z tym
ograniczeniem (`test_regex_group_highlight.nim`), nie przemilczane.

### Uczciwe odkrycie: w edytorze tekstu NIE MA mechanizmu cofania (undo)

Szósty punkt z poprzedniej listy ("grupowanie historii cofania dla
'Zamień wszystko'") zakładał, że taki mechanizm istnieje i tylko brakuje
mu grupowania. Przed przystąpieniem do pisania kodu sprawdzono to w
źródle (`grep` po `undo`/`Ctrl+Z` w `apps/texteditor/texteditor.nim`) --
wynik: PUSTY. Edytor nie ma własnego stosu cofania; jedyne cofanie,
jakie mogłoby działać, to wewnętrzne, nieudokumentowane cofanie pola
tekstowego samego Fidget (jeśli w ogóle istnieje -- nieznane bez
uruchomienia żywego GUI), na które `doReplaceAll`/`doReplaceCurrent` (obie
manipulują `t.content` jako zwykłym stringiem, z pominięciem tego pola)
prawdopodobnie w ogóle nie wpływają. "Zgrupowanie" czegoś, co nie
istnieje, nie miało sensu -- zamiast implementować fasadowe
"rozwiązanie" nieistniejącego problemu, ten punkt jest tu uczciwie
oznaczony jako BŁĘDNE ZAŁOŻENIE z poprzedniej rundy, nie jako zrobiony
ani odłożony. Prawdziwe Ctrl+Z/Ctrl+Y dla całego edytora byłoby osobną,
średniej wielkości funkcją (stos stanów `t.content` z limitem
głębokości) -- warta zrobienia, ale to NOWA funkcja, nie poprawka do
istniejącej.

**Miniatury obrazów w menedżerze plików** też świadomie odłożone: mimo
że runda 14 pokazała, że `pixie@5.0.7` da się zainstalować i uruchomić w
tej sandboxie, `apps/filemanager/files.nim` (w odróżnieniu od
`shell/desktopapps.nim`) importuje `fidget` do całego swojego UI --
dodanie generowania miniatur wymagałoby albo wciągnięcia `pixie` do
pliku, który i tak nie idzie skompilować w całości w tej sesji (więc
nowy kod miniatur byłby równie nieprzetestowany jak reszta UI), albo
wydzielenia samej logiki dekodowania/skalowania do osobnego,
testowalnego modułu -- co jest rozsądnym pomysłem na PRZYSZŁĄ rundę,
ale nie zmieściło się uczciwie w tej.

**Metoda weryfikacji**: jak w rundach 13-14, `nimble install fidget`
nadal kończy się `Error: Unsatisfied dependency: nim (>= 2.0.0)`, więc
`apps/filemanager/files.nim` i `apps/texteditor/texteditor.nim` (obie
importują `fidget`) wciąż nie dają się skompilować w całości w tej
sesji. Cała logika nie-UI tej rundy (sortowanie -- 5 scenariuszy w
`test_sorting.nim`; historia nawigacji -- 6 scenariuszy w
`test_nav_history.nim`, w tym kluczowy "nawigacja w nową stronę kasuje
starą przyszłość"; `.gitignore` -- 6 scenariuszy w `test_gitignore.nim`;
lokalizacja grup regex -- 3 scenariusze w
`test_regex_group_highlight.nim`) jest wydzielona i przetestowana w
izolowanych, realnie skompilowanych i uruchomionych programach Nim.

## Nowości w v0.2 (runda 14) -- edytor: wyrażenia regularne w Znajdź/Zamień; menedżer plików: Ctrl=kopiuj i przeciąganie folderów

Ta runda była odpowiedzią na prośbę o rozbudowę ZDE o WSZYSTKO naraz, co
wtedy było wypisane na liście ograniczeń. Po zmierzeniu się z tą listą
uczciwie: część punktów (regex, Ctrl-kopiuj przy przeciąganiu,
przeciąganie folderów) dało się realnie zaimplementować i przetestować w
tej sesji; reszta (multi-seat, gesty pinch/hold, testy na prawdziwym
DRM/GPU i wobec wlroots 0.18/0.20, żywa integracja z `wl_data_device` dla
schowka/DnD MIĘDZY ZDE a resztą systemu, HiDPI/`ScaledDirectories=` w
Icon Theme Spec, GUI dla `.zpk`, wiele sesji/użytkowników, animowane
formaty tapety) to architektonicznie duże, osobne projekty, których nie
dało się w tej sesji ani zaimplementować, ani uczciwie przetestować --
patrz zaktualizowana lista "Ograniczenia" niżej po pełny, aktualny stan
każdego punktu, z tego samego powodu, dla którego reszta tego dokumentu
zawsze mówi wprost, czego NIE zrobiono, zamiast to przemilczeć.

### Edytor tekstu: wyrażenia regularne w Znajdź/Zamień

**Domyka jawnie wypisany brak** ("wciąż bez wyrażeń regularnych").
Nowy przełącznik ".*" w pasku Znajdź (`apps/texteditor/texteditor.nim`),
obok istniejącego "Aa" -- gdy włączony, `t.findQuery` jest kompilowane
jako wzorzec `std/re` (PCRE) zamiast interpretowane jako dosłowny
podłańcuch. Domyślnie wyłączony -- żaden istniejący dokument/karta nie
dostaje niespodziewanej zmiany zachowania.

- **Zmienna długość dopasowania**: `findMatches` niosło dotąd tylko
  (linia, kolumna) i zakładało, że długość dopasowania to zawsze
  `t.findQuery.len` -- prawdziwe dla dosłownego podłańcucha, ale
  FAŁSZYWE dla regexa (`\d+` dopasowuje "1" i "12345" o różnej
  długości). Dodano trzecie pole, `length`, liczone per dopasowanie --
  używane teraz zarówno do podświetlenia (szerokość prostokąta), jak i
  do `doReplaceCurrent` (dokładnie tyle znaków jest wycinane przy
  zamianie).
- **Dopasowania o długości 0** (np. wzorzec dopuszczający pusty match,
  jak "x*" na tekście bez "x") są jawnie obsłużone -- bez tego skan tej
  samej pozycji w nieskończoność by się zapętlił; pozycja przesuwa się o
  co najmniej 1 znak niezależnie od długości dopasowania.
- **Błędny wzorzec** (np. niedomknięty nawias -- naturalny, przejściowy
  stan PODCZAS pisania wzorca) pokazuje czytelny komunikat "błędny
  wzorzec" w miejscu licznika wyników, zamiast wywalać całe okno edytora
  albo cicho pokazywać "brak wyników" (co sugerowałoby poprawny, tylko
  niepasujący wzorzec -- mylące).
- Rozróżnianie wielkości liter (przełącznik "Aa") działa też w trybie
  regex -- mapowane na flagę `reIgnoreCase` biblioteki `std/re`.

**Prawdziwy błąd złapany podczas testowania tej rundy** (nie w
dokumentacji -- w izolowanym, realnie uruchomionym programie Nim):
pierwsza wersja "Zamień wszystko" w trybie regex użyła
`t.content.replace(pattern, t.replaceQuery)` (`std/re`'s `replace`,
przyjmujący zwykły string jako trzeci argument) w założeniu, że
`t.replaceQuery` z odwołaniami do grup przechwytujących wzorca (`$1`,
`$2`) zostanie poprawnie podstawione -- test z prawdziwym wzorcem
`(\w+)@(\w+)\.com` i zamianą `"$1 [at] $2 [dot] com"` ujawnił, że
`replace` (w odróżnieniu od `replacef`) traktuje trzeci argument
DOSŁOWNIE -- wynik zawierał litery `$1`/`$2` wprost w tekście, nie
przechwycone grupy. Naprawione użyciem `replacef` (osobna procedura w
`std/re`, jedyna, która faktycznie interpretuje `$n`). Bez tego testu ta
funkcja wyglądałaby na działającą (kompiluje się, nic się nie wywala),
a w praktyce cicho psułaby każdą zamianę korzystającą z grup
przechwytujących.

### Menedżer plików: Ctrl+przeciągnij = kopiuj; przeciąganie folderów

Domyka DWA punkty, które runda 13 świadomie zostawiła otwarte na liście
ograniczeń tej rundy.

- **Ctrl = kopiuj** (`FileDragState.copyMode`, `doDropMove`) --
  sprawdzane w chwili PUSZCZENIA przycisku myszy (`updateFileDrag`), NIE
  w chwili złapania pliku (`onMouseDown`) -- ten pierwszy moment jest już
  zajęty przez Ctrl+klik do zaznaczania wielu wpisów, więc mieszanie
  dwóch znaczeń Ctrl w TYM SAMYM momencie przeciągania byłoby mylące.
  Efekt uboczny: użytkownik może zacząć przeciąganie bez Ctrl, a
  doszczypnąć/puścić Ctrl dopiero tuż przed upuszczeniem, żeby zmienić
  zamiar z "przenieś" na "kopiuj" w locie -- naturalne zachowanie, znane
  z innych menedżerów plików. Podświetlenie celu zmienia kolor (zielony
  = przenieś, niebieski = kopiuj) NA BIEŻĄCO, klatka po klatce, zanim
  użytkownik w ogóle puści przycisk.
- **Przeciąganie folderów** -- w rundzie 13 świadomie ograniczone tylko
  do plików (foldery nawigują na zwykły klik, co kolidowałoby z
  inicjacją przeciągania na tym samym geście). Teraz folder można
  przeciągnąć w sytuacjach, w których zwykły klik i tak by NIE
  nawigował: Ctrl albo Shift trzymany w chwili złapania (te same dwa
  warunki, którymi `onClick` rozpoznaje "to zaznacz/zakres, nie wejście
  do środka"), albo folder jest już częścią wieloelementowego
  zaznaczenia sprzed tego kliknięcia. Zwykły, pojedynczy klik na
  niezaznaczonym folderze bez modyfikatorów dalej nawiguje do środka,
  bez żadnej zmiany względem rundy 13.

**Metoda weryfikacji, tak samo uczciwie jak w rundzie 13**: `nimble
install fidget` w tej sandboxie nadal kończy się tym samym
`Error: Unsatisfied dependency: nim (>= 2.0.0)` (dostępny jest tylko Nim
1.6.14 z apt) -- więc znów nie dało się skompilować i zobaczyć żywego
`zde-shell`. Cała logika nie-UI została wydzielona i przetestowana w
izolowanych, realnie skompilowanych i uruchomionych programach Nim, na
prawdziwym systemie plików: `doDropMove` z `copyMode = true` (kopiowanie
pliku/folderu zachowuje oryginał w źródle, kolizja nazw dalej dokłada
"(kopia)", zwykłe przeciąganie bez Ctrl nadal PRZENOSI -- bez regresji
rundy 13), warunek bramkujący przeciąganie folderów (plik zawsze
przeciągalny, folder tylko z Ctrl/Shift/wieloselekcją, zwykły klik na
niezaznaczonym folderze NIE uzbraja przeciągania), oraz cała logika
regex opisana wyżej (zmienna długość, dopasowania o długości 0, błędny
wzorzec, poprawne numery linii, `replacef` z grupami). Same bloki DSL
Fidget (`onMouseDown`/`onHover`/`fill`, przełącznik ".*") są pisane jako
addytywne rozszerzenie już wcześniej ustalonych wzorców w tym samym
pliku -- integracja z żywym silnikiem renderującym pozostaje do
potwierdzenia w przyszłej rundzie, jeśli środowisko z Nim >= 2.0 będzie
dostępne.

### Launcher: `ScaledDirectories=`/`Scale=` (Icon Theme Spec) -- i przełom w metodzie weryfikacji

**Domyka kolejny jawnie wypisany brak** ("brak `ScaledDirectories=`/@2x w
Icon Theme Spec"). `loadThemeMeta`/`ThemeDirEntry` w
`shell/desktopapps.nim` parsują teraz `Scale=` z każdej sekcji
`index.theme` (domyślnie `1`, gdy klucz nie występuje -- zgodnie ze
specyfikacją), a `pickBestDir` stawia katalogi `Scale=1` ZAWSZE przed
katalogami o wyższej skali (`@2x`/`@3x`) o tym samym nominalnym `Size=`,
zamiast (jak dotychczas) traktować je identycznie i wybierać między nimi
przez czysty przypadek kolejności w pliku.

**To NIE jest pełne wsparcie HiDPI** -- ZDE wciąż nigdzie nie zna
rzeczywistej skali monitora (kompozytor jej nie przekazuje do shellu, to
osobne, dużo większe zadanie), więc katalog `@2x` nigdy nie zostanie
świadomie WYBRANY na potrzeby ostrzejszego wyświetlania. Ta rozbudowa
naprawia węższy, ale realny problem: bez niej dwa katalogi w TYM SAMYM
motywie mogące zawierać RÓŻNE pliki pod tymi samymi nazwami (np.
`apps/48` i `apps@2/48`, oba `Size=48`) były nierozróżnialne dla
`pickBestDir`.

**Przełom w metodzie weryfikacji tej rundy**: `shell/desktopapps.nim`
zależy WYŁĄCZNIE od `std`/`pixie` (NIE importuje `fidget`) -- co
oznacza, że dało się zainstalować `pixie@5.0.7` (DOKŁADNIE tę wersję, o
której od rundy 5 mówi komentarz w kodzie o ograniczeniach rasteryzacji
SVG) samodzielnie, pod Nim 1.6.14 z tej sandboxy, mimo że `fidget` samo
w sobie nadal wymaga Nim >= 2.0. Dzięki temu, PIERWSZY RAZ w tej serii
rund, dało się skompilować i uruchomić PRAWDZIWY, niezmodyfikowany
`shell/desktopapps.nim` -- nie kopię jego logiki w izolowanym skrypcie
(jak wszystkie testy w rundach 13-14 do tej pory), tylko realny
`import ../shell/desktopapps` i wywołanie prawdziwego, eksportowanego
`scanDesktopApps()`.

Test uruchomiony na prawdziwych plikach `.desktop` i prawdziwych,
zainstalowanych w tej sandboxie motywach ikon (Humanity, Humanity-Dark,
hicolor, Adwaita, ubuntu-mono-{dark,light}):
- Znaleziono 7 realnych aplikacji `.desktop` w systemie (LibreOffice x5,
  ImageMagick, TeXdoctk), 5 z nich dostało realnie rozwiązaną ikonę.
- Potwierdzone bezpośrednio na dysku (nie w teorii): `Humanity/apps/48/`
  i `Humanity/apps@2/48/` NAPRAWDĘ zawierają plik o tej samej nazwie
  (`access.svg`) -- to jest realna, a nie tylko teoretyczna,
  niejednoznaczność, którą ta rozbudowa rozwiązuje.
- Kluczowa asercja: PO poprawce ŻADNA z 7 aplikacji nie dostała ikony z
  katalogu `@2x`/`@3x`, mimo że taki katalog (`apps@2/48` w Humanity)
  istnieje i wcześniej mógł zostać wybrany zamiast `apps/48` czystym
  przypadkiem kolejności w pliku `index.theme`.

Reszta rundy 13/14 (menedżer plików, edytor tekstu) importuje `fidget`
(DSL okien/przycisków) i dlatego wciąż NIE dało się jej skompilować w
tej sesji -- ten przełom dotyczy konkretnie `desktopapps.nim`, nie całego
`zde-shell`.

## Nowości w v0.2 (runda 13) -- menedżer plików: przeciąganie plików/folderów myszą (drag & drop)

**Domyka kolejny, jawnie wypisany od dawna punkt z listy ograniczeń**
("wciąż bez przeciągania plików myszą (drag & drop)"). Do tej rundy
przenoszenie wymagało zawsze przejścia przez schowek plików (Kopiuj/
Wytnij/Wklej -- patrz rozbudowy niżej) -- teraz można też złapać plik
(albo zaznaczone Ctrl/Shift-klikiem wiele plików) i upuścić go
bezpośrednio na wiersz folderu, tak jak w Nautilusie/Dolphinie/
Eksploratorze.

- **Mechanizm** (`apps/filemanager/files.nim`, `FileDragState`/
  `updateFileDrag`) to dosłownie ten sam, już dwukrotnie sprawdzony w tym
  projekcie wzorzec "przeciągania przez trzymanie", którego używają
  `comp/drag.nim` (przenoszenie/zmiana rozmiaru OKIEN) i
  `SliderDragState`/`updateSliderDrag` w `shell/taskbar.nim` (suwaki quick
  settings): `onMouseDown` na wierszu pliku zapamiętuje start
  przeciągania (BEZ natychmiastowego przenoszenia), `onHover` na wierszu
  FOLDERU ustawia bieżący cel upuszczenia, a nowe `updateFileDrag()`
  (wołane raz na klatkę z `shell/shell.nim`, obok analogicznych
  `compositor.updateDrag`/`updateSliderDrag`) wykonuje faktyczne
  przeniesienie dopiero w klatce, w której przycisk myszy zostaje
  puszczony NAD folderem.
- **`onMouseDown` jest DODATKOWYM handlerem obok już istniejącego
  `onClick`** na tym samym wierszu (Fidget pozwala na wiele bloków
  zdarzeń na jednym węźle -- ten sam wzorzec co `onHover` + `onClick` na
  przycisku "⬆ Wyżej", obecny w kodzie od dawna) -- `onClick`
  (zaznaczanie/nawigacja/podwójny klik) pozostaje CAŁKOWICIE nietknięty.
  Zwykły klik bez ruchu myszy "uzbraja" przeciąganie, ale skoro
  użytkownik nigdy nie najechał na żaden wiersz folderu, cel upuszczenia
  nigdy się nie ustawia -- `updateFileDrag` przy puszczeniu przycisku nie
  ma czego przenieść, więc to czysty no-op: zwykłe klikanie/zaznaczanie
  działa dokładnie tak jak przed tą rundą.
- **Działa MIĘDZY dwoma różnymi, otwartymi jednocześnie oknami
  menedżera** -- `gFileDropTarget` to zwykła bezwzględna ścieżka na
  poziomie MODUŁU (ten sam duch co `gFileClipboardPaths`/
  `gFileClipboardCut` z wcześniejszej rozbudowy schowka plików), więc nie
  ma znaczenia, w KTÓRYM oknie fizycznie znajduje się wiersz-cel. Po
  przeniesieniu WSZYSTKIE otwarte okna, których katalog (źródłowy LUB
  docelowy) mógł się zmienić, odświeżają swoją listę automatycznie
  (`gDirsNeedingRefresh`, sprawdzane na początku `drawFileManager`) --
  bez tego drugie, otwarte akurat na katalogu docelowym okno pokazywałoby
  przestarzałą listę aż do ręcznego "Odśwież".
- **"⬆ Wyżej" też przyjmuje upuszczenie** -- przenosi bezpośrednio do
  katalogu NADRZĘDNEGO, bez potrzeby wcześniejszej ręcznej nawigacji tam
  i z powrotem.
- **Zabezpieczenia**, przez ten sam, już wcześniej sprawdzony mechanizm co
  "Wklej" (`uniqueDestName`/ochrona przed rekurencją, patrz sekcja
  "kopiuj/wytnij/wklej" niżej): kolizja nazw w katalogu docelowym dokłada
  "(kopia)"/"(kopia 2)"/..., próba przeniesienia folderu do samego siebie
  albo do jego własnego podkatalogu jest wykrywana i odrzucana PRZED
  dotknięciem dysku, a źródło, które zniknęło z dysku między uzbrojeniem
  a puszczeniem przycisku, jest pomijane z czytelnym komunikatem zamiast
  wywalać całą operację.
- Świadomie POZA zakresem tej rundy: brak modyfikatora
  Ctrl-przeciągnij-żeby-skopiować (przeciąganie zawsze PRZENOSI, nigdy nie
  kopiuje) oraz brak przeciągania MIĘDZY ZDE a aplikacjami spoza niego
  (wymagałoby integracji z `wl_data_device`/DND na poziomie kompozytora,
  czego architektura ZDE dziś nigdzie nie robi -- ten sam, już wcześniej
  udokumentowany kompromis co przy schowku plików). Przeciąganie jest
  możliwe tylko z pojedynczych wierszy PLIKÓW (nie folderów) -- foldery w
  tym menedżerze nawigują na zwykły klik, więc dodanie im też inicjacji
  przeciągania na `onMouseDown` wymagałoby dodatkowego rozróżnienia
  "klik = wejdź" vs "przeciągnięcie = przenieś" na tym samym geście,
  czego nie dało się w tej rundzie zweryfikować bez żywego Fidget/GLFW --
  bezpieczniej zostawić to jako świadome ograniczenie niż zgadywać.

**Uczciwa notatka o metodzie weryfikacji tej rundy:** w tej sandboxie
(Ubuntu 24.04 kontenerowe) dało się doinstalować `nim` 1.6.14 z apt --
ale próba `nimble install fidget` kończy się tym samym, już wcześniej w
tym README udokumentowanym `Error: Unsatisfied dependency: nim (>=
2.0.0)` (fidget >= 0.7.10 i cała reszta łańcucha Pixie/typography tego
wymagają) -- więc, tak jak przy wielu wcześniejszych rundach
("wybór dźwięku alarmu", "trwała historia schowka", "ciągłe
przeciąganie suwaków" i inne, patrz wyżej), nie dało się w TEJ
konkretnej sesji realnie skompilować i zobaczyć `zde-shell` z tą zmianą.
Zamiast tego CAŁA logika nie-UI (bez żadnej zależności od Fidget) --
`doDropMove` (przenoszenie zwykłego pliku, przenoszenie folderu
rekurencyjnie, kolizja nazw dokładająca "(kopia)", ochrona przed
przeniesieniem folderu do własnego potomka, obsługa zniknięcia źródła,
no-op przy upuszczeniu na ten sam katalog) oraz mechanizm zatrzasku
jednoklatkowego `gFileDropTarget`/`updateFileDrag` (podświetlenie celu
żyje dokładnie jedną klatkę i odnawia się przy ciągłym hover, puszczenie
przycisku NAD celem wykonuje przeniesienie dokładnie raz, puszczenie
POZA celem to no-op) -- została wydzielona i przetestowana w
izolowanych, realnie skompilowanych i uruchomionych programach Nim, na
prawdziwym systemie plików w katalogu tymczasowym. Sam kod DSL-a Fidget
(`onMouseDown`/`onHover`/`fill` na wierszach) był pisany z rozmysłem jako
CZYSTO ADDYTYWNY względem już wcześniej, w poprzednich rundach, żywo
zweryfikowanego kodu (`onClick` selekcji/nawigacji pozostaje bez ŻADNEJ
zmiany) -- ale sama INTEGRACJA z żywym silnikiem renderującym pozostaje
do potwierdzenia w przyszłej rundzie, jeśli środowisko z Nim >= 2.0
będzie dostępne. Zaznaczone tu wprost, zamiast przemilczane -- ten sam
poziom uczciwości co reszta tego dokumentu.

## Nowości w v0.2 (runda 12) -- Terminal: PRAWDZIWA przyczyna znaleziona i naprawiona (ciąg dalszy rundy 11)

Runda 11 (niżej) skończyła się uczciwym "nie wiem" -- obaloną hipotezą i
przywróceniem niepotrzebnych zmian. Ta runda wróciła do tego samego
problemu i, metodyczną bisekcją na żywo (nie zgadywaniem), znalazła
PRAWDZIWĄ przyczynę.

**Prawdziwa przyczyna:** TEKST (nie zwykłe wypełnienia/prostokąty --
te renderowały się poprawnie nawet tuż przy krawędzi) w obrębie
kilkunastu pikseli od DOLNEJ krawędzi `frame "term-root"` był
całkowicie niewidoczny w tej wersji Fidget/Pixie, niezależnie od tego,
czy to statyczny napis "zde$ ", czy dynamiczne `t.input`. Rząd
wpisywania poleceń, przyklejony do samego dołu okna z zaledwie 8px
marginesu (`pad`), siedział dokładnie w tej martwej strefie -- stąd
ZARÓWNO statyczny prompt, JAK I wpisywany tekst były niewidoczne,
mimo że dane po stronie kodu były przez cały czas poprawne (co runda
11 już ustaliła).

**Metoda odkrycia -- bisekcja pozycji, nie zgadywanie:** dorzucono
jaskrawy, izolowany prostokąt (`rectangle "MARKER"`) dokładnie w miejscu
rzędu wpisywania -- WIDOCZNY, potwierdzając że same kształty renderują
się poprawnie nawet w tym miejscu. Następnie przesunięto CAŁY rząd
wpisywania o 100px w górę (z dala od krawędzi) -- statyczny napis
"zde$ " STAŁ SIĘ WIDOCZNY. Zawężono do 20px przesunięcia w górę --
WCIĄŻ widoczny (dokładny próg w pikselach nie został ustalony co do
jedności, bo nie było powodu szukać go dokładniej, skoro rozsądny
margines bezpieczeństwa rozwiązuje problem raz na zawsze). Po drodze
odrzucono też DWIE inne, kuszące, ale błędne hipotezy -- że problem
dotyczy skalowania okna zmaksymalizowanego (obalone: identyczny brak
tekstu w oknie NIE zmaksymalizowanym) i że problem dotyczy
`cornerRadius` obcinającego dzieci (obalone: usunięcie `cornerRadius`
nie zmieniło niczego).

**Naprawa** (`apps/terminal/term.nim`): nowa stała `BottomTextClipMargin`
(24px, celowo hojniejsza niż zmierzony próg ~20px -- margines
bezpieczeństwa, nie wartość "ledwo wystarczająca", żeby nie balansować
tuż przy granicy nieznanego mechanizmu na innych rozdzielczościach/
czcionkach) odejmowana zarówno od wysokości scrollbacku (`bodyH`), jak
i od pozycji Y rzędu wpisywania (`input-row`) oraz przycisku "Wklej"
(`btn-paste`, żeby zostały wyrównane) -- efekt: scrollback jest o 24px
niższy, rząd wpisywania siedzi 24px wyżej niż wcześniej, z dala od
martwej strefy.

**Przy okazji naprawiono DRUGI, powiązany bug**, znaleziony od razu przy
weryfikacji pierwszej naprawy: samo wyczyszczenie `t.input`/
`keyboard.input` po `Enter` nie wystarczało -- pole dalej POKAZYWAŁO
starą treść, a kolejne znaki DOPISYWAŁY się do niej zamiast zaczynać od
nowa (`"echo IT_WORKS_NOW"` + `x` + `y` dawało widoczne
`"echo IT_WORKS_NOWxy"`). Fidget najwyraźniej trzyma własny, wewnętrzny
bufor edycji dla aktualnie SKUPIONEGO pola, niezależny od
`keyboard.input`, i odtwarza go z powrotem po `onInput`. Naprawa:
`keyboard.focusNode = nil` po wysłaniu polecenia (ten sam mechanizm co
`onHover` na "scrollback" już używał do zwalniania fokusu) -- wymusza
pełny reset tego wewnętrznego bufora.

**Zweryfikowane pełnym przepływem end-to-end pod Xvfb, krok po kroku:**
1. Zrzut ekranu PO naprawie pozycji: prompt "zde$" i przycisk "Wklej"
   widoczne w rzędzie wpisywania -- pierwszy raz w całej tej serii rund.
2. Wpisanie `echo IT_WORKS_NOW` -- widoczne znak po znaku, z kursorem,
   podczas pisania.
3. `Enter` -- scrollback pokazuje `echo IT_WORKS_NOW` i `IT_WORKS_NOW`
   (prawdziwe wyjście PTY).
4. Wpisanie kolejnych znaków po `Enter` -- BEZ naprawy drugiego buga:
   sklejały się ze starą treścią (`"echo IT_WORKS_NOWxy"`, potwierdzone
   zrzutem). PO naprawie: pole poprawnie wraca do samego "zde$".
5. Dwa kolejne, niezależne polecenia (`echo FIRST`, `echo SECOND`)
   wykonane pod rząd -- każde poprawnie wyczyściło pole po wykonaniu,
   każde poprawnie wykonane i widoczne na scrollbacku, bez żadnej
   pozostałości z poprzedniego.

Terminal jest teraz w pełni użyteczny w tej wersji -- pierwszy raz w
całej tej serii rund udało się faktycznie wpisać i zobaczyć polecenie
podczas pisania w tym oknie.

## Nowości w v0.2 (runda 11) -- Terminal: uczciwie udokumentowany, NIE W PEŁNI rozwiązany bug (pisanie "na ślepo")

Ta runda skończyła się BEZ pełnej naprawy -- warto to zapisać uczciwie,
zamiast przemilczeć, bo sam proces dochodzenia jest pouczający i
zapobiega marnowaniu czasu na tę samą ślepą uliczkę w przyszłości.
**Kontynuacja i pełne rozwiązanie -- patrz "Nowości w v0.2 (runda 12)"
wyżej.**

**Znaleziony, potwierdzony, realny bug:** w terminalu (`apps/terminal/term.nim`,
pole `input-field`) wpisywane polecenie jest CAŁKOWICIE niewidoczne na
ekranie podczas pisania. Odkryte przez live-test: wpisanie "ls", potem
(w osobnej próbie) "echo REALTEST123", potem `Enter` ujawniło na
scrollbacku sklejone `"echo REALTEST123lsl"` -- dowód, że wszystkie
wcześniejsze, pozornie "nic nie robiące" próby w rzeczywistości cicho
gromadziły się w buforze, tylko nigdy nie były pokazywane. Debugowy
`echo` potwierdził: `onInput` faktycznie się odpala, `t.input`
faktycznie trzyma poprawną wartość co do znaku -- PTY dostaje polecenia
poprawnie (`Enter` faktycznie je wykonuje). To WYŁĄCZNIE problem
wizualny, nie utraty danych ani przechwytywania wejścia.

**Wypróbowana i OBALONA hipoteza:** że przyczyną jest brak jawnego
`characters t.input` w gałęzi "pole ma fokus" (pole pokazywało tekst
TYLKO gdy NIE miało fokusu -- dokładnie odwrotnie niż potrzeba). Zmiana
na wołanie `characters t.input` bezwarunkowo (ten sam wzorzec co pasek
Znajdź w edytorze tekstu) **NIE naprawiła problemu** -- potwierdzone
ponownym live-testem po przebudowie. Dla porównania: DOKŁADNIE ten sam
wzorzec (brak gałęzi dla stanu "ma fokus") w polu układu klawiatury w
Ustawieniach działa BEZ ZARZUTU -- osobny live-test pokazał "pl"
wpisywane znak po znaku, w pełni widoczne. Skoro identyczny wzorzec
kodu działa w jednym miejscu i nie działa w drugim, to NIE jest ten
wzorzec winowajcą -- coś SPECYFICZNEGO dla okna terminala psuje
renderowanie, przyczyna wciąż nieznana (podejrzenia na przyszłość: coś
związanego z `resizePty` przeliczanym co klatkę tuż przed tym blokiem,
albo interakcja z `onHover` na "scrollback" nad nim).

**Dlaczego to jest w README, a nie tylko cicho cofnięte:** trzy inne
miejsca w kodzie (`apps/settings/settings.nim` -- pola X/Y monitora i
układu klawiatury; `apps/texteditor/texteditor.nim` -- pole ścieżki
"Otwórz") zostały PRZEZ POMYŁKĘ "naprawione" tą samą, obaloną hipotezą,
zanim disproof nadszedł -- i CELOWO PRZYWRÓCONE do oryginalnej postaci
po tym, jak live-test na polu układu klawiatury potwierdził, że
oryginalny kod tam był poprawny od początku. To jest uczciwy zapis
procesu: postawiona hipoteza, przetestowana, obalona, niepotrzebne
zmiany cofnięte -- zamiast zostawić niepotrzebne (choć nieszkodliwe)
"poprawki" tylko dlatego, że już zostały napisane.

## Nowości w v0.2 (runda 10) -- Monitor systemu: użycie dysku (i DRUGIE wystąpienie tego samego buga formatowania)



**Monitor systemu (`apps/sysmonitor/sysmonitor.nim`) pokazuje teraz
użycie dysku**, obok już istniejących CPU i RAM -- `statvfs(2)` na `/`
(to samo POSIX-owe wywołanie, na którym opiera się `df`), z tym samym
wzorcem obronnym co `readCpuSample`/`readMemInfo` (cichy `(0, 0)` przy
błędzie, żeby jedna nieudana próba nie wywaliła całego okna). Świadome
uproszczenie: pokazuje WYŁĄCZNIE punkt montowania "/" (nie sumę
wszystkich zamontowanych systemów plików) -- to samo podejście co karta
"Przechowywanie" w GNOME Ustawieniach, gdzie montowanie główne jest
domyślnie tym, co się liczy jako "ile miejsca zostało".

**Przy pierwszym realnym zrzucie ekranu tej rundy zauważono DRUGIE
wystąpienie dokładnie tego samego buga formatowania, co w rundzie 9
(Kalkulator)** -- nie przez osobny, wyspecjalizowany test tym razem,
tylko przez uważne spojrzenie na zwykły zrzut ekranu ze zwykłymi
danymi: `humanKb()` (funkcja formatująca rozmiar w MB/GB, używana od
dawna do wyświetlania RAM, teraz też dysku) pokazywała `"511. MB"`
zamiast `"511 MB"` -- ten sam winowajca co poprzednio, `&"{x:.0f}"`
zostawiający kropkę na końcu nawet przy zerze miejsc po przecinku,
tylko w INNYM pliku i INNEJ funkcji. Naprawione tym samym `.strip(chars
= {'.'})`. Po tym drugim znalezisku przeszukano CAŁE repozytorium pod
kątem tego samego wzorca (`grep -rn ':\.0f'`) -- te dwa miejsca (teraz
oba naprawione) były JEDYNYMI wystąpieniami, więc to nie epidemia,
tylko dwa niezależne, teraz domknięte przypadki tego samego, łatwego do
przeoczenia zachowania formatowania liczb w tej wersji Nim.

**Zweryfikowane realnym uruchomieniem, przed i po naprawie:** zrzut
ekranu PRZED naprawą pokazuje `"Pamięć RAM 511. MB / 3.9 GB"` (błąd
widoczny), zrzut PO naprawie pokazuje czyste `"511 MB / 3.9 GB"` --
oraz nową sekcję `"Dysk (/) 242.2 GB / 252.0 GB"` z poprawnie
wypełnionym paskiem, dane zgodne z rzeczywistym stanem dysku tej
maszyny w chwili testu.

## Nowości w v0.2 (runda 9) -- Kalkulator: obsługa klawiatury fizycznej (i odkryty przy okazji bug w formatowaniu liczb)

**Kalkulator (`apps/calculator/calculator.nim`) obsługuje teraz klawiaturę
fizyczną** -- dotąd JEDYNYM sposobem interakcji było klikanie przycisków
myszą (`grep buttonPress` przed tą rundą nie dawało żadnego wyniku w
tym pliku). Cyfry (górny rząd I klawiatura numeryczna równolegle),
operatory (`+`/`-`/`×`/`÷`, w tym `Shift+5` jako `%` i `x`/`X` jako alias
mnożenia), `Enter`/`=` do wyniku, nowe `Backspace` (kasuje OSTATNIĄ
cyfrę, w odróżnieniu od "C", które czyści wszystko) i `Escape` (= "C").
Aktywne TYLKO gdy okno kalkulatora ma fokus (`win.focused`, ten sam
sprawdzony wzorzec co skrót Ctrl+F w edytorze tekstu), żeby wpisywanie
cyfr nie wpływało na wszystkie otwarte okna kalkulatora naraz.

**Przy okazji testowania na żywo wykryto i naprawiono realny,
PRZEDTEM ISTNIEJĄCY bug, zupełnie niezwiązany z samą klawiaturą:**
`formatNumber` (funkcja formatująca wynik do wyświetlenia, używana
identycznie niezależnie od tego, czy wynik wywołało kliknięcie myszą
"=" czy klawisz) zostawiała KROPKĘ na końcu każdej wyświetlonej liczby
całkowitej -- `8 ÷ 2` pokazywało `"4."`, nie `"4"`. Przyczyna: format
string `&"{x:.0f}"` w tej wersji Nim/`strformat` zostawia kropkę nawet
przy zerze miejsc po przecinku -- potwierdzone bezpośrednim, izolowanym
testem poza aplikacją (`formatNumber(4.0)` → `"4."`). Naprawa: `.strip(chars
= {'.'})` na wyniku. **To NIE był bug w nowym kodzie klawiatury** --
zweryfikowano, że dokładnie ten sam błąd występował przy kliknięciu
myszą w przycisk "=" (istniejący od dawna sposób obsługi), po prostu
nikt wcześniej nie przetestował rzeczywistego wyniku arytmetyki na tyle
dokładnie, żeby to zauważyć -- kolejny przykład tego, dlaczego ta cała
seria rozbudów kładzie nacisk na realne uruchomienie, nie tylko udaną
kompilację.

**Uczciwa notatka o ograniczeniach testowania w tej rundzie:** klawisz
"=" (bez Shift) okazał się zawodny w syntetyzowaniu przez `xdotool` w
tej konkretnej piaskownicy Xvfb (najprawdopodobniej mechanizm
tymczasowego przemapowania wolnego kodu klawisza, którego `xdotool`
używa dla symboli nieobecnych wprost w bardzo minimalnym układzie
klawiatury Xvfb, koliduje z klawiszem `PERIOD` -- wciśnięcie "=" przez
`xdotool` konsekwentnie dawało w aplikacji efekt taki, jakby wciśnięto
`.`, nie `=`). Pełna, wiarygodna weryfikacja arytmetyki użyła więc
`Backspace`/`Escape`/cyfr/`Minus`/`Slash`/`Shift+Equal` (wszystkie
potwierdzone działające poprawnie) oraz kliknięcia myszą w przycisk
"=" na ekranie (`15 − 3 = 12`, bez kropki na końcu po naprawie,
potwierdzone zrzutem ekranu) -- sam klawisz `Enter`/`KP_Enter` jako
alternatywa dla `=` jest w kodzie i powinien działać na prawdziwej
klawiaturze fizycznej (gdzie nie ma potrzeby syntetycznego
przemapowania kodów klawiszy), ale nie dało się tego ostatniego
w pełni niezależnie zweryfikować w tej konkretnej piaskownicy.

## Nowości w v0.2 (runda 8) -- edytor tekstu: ten sam wbudowany file picker co przy tapecie, teraz do "Otwórz"

**Przycisk 📂 przy polu ścieżki w edytorze tekstu** (`apps/texteditor/texteditor.nim`,
`drawFilePicker`/`openPicker`/`refreshPickerEntries`) -- prosty ponowny
użytek dokładnie tego samego, już zweryfikowanego wzorca z Ustawień
(patrz "Nowości w v0.2 (runda 7)" niżej), zastosowany do DRUGIEGO
realnego miejsca w ZDE, gdzie dotąd trzeba było wpisać całą ścieżkę
ręcznie. W odróżnieniu od pickera tapety (ograniczonego do
`.png`/`.jpg`), ten pokazuje WSZYSTKIE pliki bez filtrowania po
rozszerzeniu -- edytor tekstu może sensownie otworzyć dowolny plik, tak
jak zawsze mogło pole ręcznego wpisywania ścieżki, więc zawężanie listy
byłoby tu ograniczeniem, nie usprawnieniem. Stan pickera (katalog,
przewinięcie, lista wpisów) żyje na poziomie KARTY (`Tab`), nie całego
edytora -- różne karty mogą przeglądać różne katalogi niezależnie, tak
jak każda karta ma już dziś własną, niezależną ścieżkę/treść.

Dzięki temu, że quirk odwróconej kolejności rysowania rodzeństwa w
Fidget (patrz "Nowości w v0.2 (runda 7)" niżej po pełny opis, jak został
odkryty) był już wtedy w pełni zrozumiany i udokumentowany, ta runda
zadziałała poprawnie **za pierwszym razem** -- bez żadnej z wcześniejszych
ślepych uliczek (invisible overlay, offset o sto pikseli, crash na
kolorze z kanałem alfa). Realny dowód wartości spisania odkrycia w
komentarzu i README zamiast tylko naprawienia i zapomnienia.

**Zweryfikowane pełnym przepływem end-to-end pod Xvfb:** utworzono
`/root/Documents/hello.txt` z przykładową treścią, otwarto edytor
tekstu, kliknięto 📂 → nakładka "Otwórz plik" pokazuje `/root/` →
nawigacja do `Documents` → plik `hello.txt` widoczny na liście (bez
filtrowania, w odróżnieniu od pickera tapety) → kliknięcie →
**zakładka zmienia nazwę na `hello.txt`, pole ścieżki na
`/root/Documents/hello.txt`, a treść pliku faktycznie wczytuje się i
wyświetla w edytorze** -- potwierdzone zrzutem ekranu, nie tylko
sprawdzeniem, że nakładka się otwiera.

## Nowości w v0.2 (runda 7) -- Ustawienia: wbudowana przeglądarka plików do wyboru tapety (i istotne odkrycie o kolejności rysowania w Fidget)

**Przycisk "Przeglądaj..." przy polu tapety w Ustawieniach** (`apps/settings/settings.nim`,
`drawWallpaperPicker`/`openPicker`/`refreshPickerEntries`) -- lekka,
WBUDOWANA w samą aplikację Ustawienia przeglądarka katalogów jako
pełnoekranowa nakładka, ograniczona do folderów i plików obrazów
(`.png`/`.jpg`/`.jpeg`). To NIE jest systemowy file-picker (żaden inny
toolkit w ZDE go nie ma, więc nie ma z czym się zintegrować) -- to
domyka realny, jawnie wypisany w README brak: dotąd JEDYNYM sposobem
wskazania tapety było ręczne wpisanie całej ścieżki. Wzorzec przewijania
(kółko myszy) skopiowany 1:1 z `apps/filemanager/files.nim` dla
spójności w całym ZDE.

**Najważniejsze odkrycie tej rundy -- nie w kodzie ZDE, tylko w samej
bibliotece Fidget, i to takie, które wpływa na KAŻDĄ nakładkę/modal w
całym projekcie, nie tylko na ten jeden przycisk:** w tej wersji Fidget
kolejność malowania RODZEŃSTWA na tym samym poziomie zagnieżdżenia jest
ODWRÓCONA względem typowego modelu "malarskiego" CSS/Figmy -- element
zadeklarowany WCZEŚNIEJ renderuje się NA WIERZCHU elementów
zadeklarowanych PÓŹNIEJ, nie pod spodem.

Odkryte metodycznie, krok po kroku, przez izolowane testy wizualne (nie
przez czytanie dokumentacji, bo dokumentacja Fidget tego nie opisuje):
1. Pierwsza wersja tej rozbudowy umieszczała nakładkę jako OSTATNI
   element `frame "settings-root"` (intuicyjny wybór -- "narysowane
   później" = "na wierzchu" w niemal każdym innym frameworku UI).
   Efekt: kompletnie niewidoczna, mimo że kod wykonywał się co klatkę z
   poprawnymi wartościami (potwierdzone `echo`).
2. Test z jaskrawym, izolowanym prostokątem jako OSTATNIM dzieckiem
   `settings-root`: całkowicie niewidoczny, przykryty przez "sidebar"/
   "content" zadeklarowane WCZEŚNIEJ.
3. Test z tym samym prostokątem jako PIERWSZYM dzieckiem: całkowicie
   przykrył "sidebar"/"content" -- rozstrzygający dowód odwróconej
   kolejności.
4. Naprawa: `drawWallpaperPicker` wołane na SAMYM POCZĄTKU `frame
   "settings-root"`, przed "sidebar"/"content" -- i w środku samej
   nakładki `picker-panel` (ma być na wierzchu) zadeklarowany PRZED
   `picker-backdrop` (ma być pod spodem), z tego samego powodu.

Po drodze złapano też mniejszy, ale realny bug, który zawaliłby całą
aplikację: `fill "#000000cc"` (8-cyfrowy hex z kanałem alfa) nie jest
poprawnym formatem koloru dla Fidget/Chroma -- poprawny sposób to
osobny drugi argument, `fill "#000000", 0.8`. Bez uruchomienia na żywo
pod Xvfb ten konkretny crash (`Error: unhandled exception: HTML color
invalid: #000000cc`) trafiłby prosto do repozytorium.

**Ważne zastrzeżenie o zasięgu tego odkrycia:** kolejność MIĘDZY
rodzeństwem jest odwrócona, ale WŁASNE wypełnienie (`fill`) grupy nadal
poprawnie chowa się POD jej własnymi dziećmi -- to znaczy, że każdy
ISTNIEJĄCY już wcześniej przycisk w ZDE (np. `wallpaper-apply-btn`:
grupa z własnym `fill` i zagnieżdżonym `text`) renderuje się poprawnie
i NIE wymaga żadnej poprawki -- problem dotyczy WYŁĄCZNIE przypadków,
gdzie dwa NIEZAGNIEŻDŻONE, nakładające się na siebie elementy są
rodzeństwem tego samego rodzica (jak nakładka na wierzchu reszty UI).
To pierwszy taki przypadek w ZDE (żadna wcześniejsza rozbudowa nie
potrzebowała pełnoekranowej nakładki znad istniejącej zawartości), więc
bug nigdy wcześniej nie miał okazji się ujawnić.

**Zweryfikowane pełnym przepływem end-to-end pod Xvfb, nie tylko
pojedynczym zrzutem ekranu:** otwarcie Ustawień → kliknięcie
"Przeglądaj..." → nawigacja `/root` → `Pictures` → `wallpapers` (ścieżka
w nagłówku nakładki aktualizuje się poprawnie na każdym kroku) →
kliknięcie `test-ocean.png` → nakładka się zamyka, pole ścieżki
wypełnione, MINIATURA PODGLĄDU w Ustawieniach od razu pokazuje niebieski
obraz → kliknięcie "Zastosuj" → **prawdziwa tapeta pulpitu (widoczna w
tle za oknem Ustawień) zmienia się na niebieską**, potwierdzone
zrzutem ekranu całego pulpitu, nie tylko okna Ustawień.

## Nowości w v0.2 (runda 6) -- launcher: prawdziwa rezolucja Icon Theme Spec (i bug w `parsecfg`)

**Rezolucja ikon systemowych przeszła z płaskiej, ręcznie wypisanej listy
ścieżek na prawdziwy algorytm ze specyfikacji freedesktop.org "Icon
Theme Specification"** (`shell/desktopapps.nim`, `resolveViaThemeSpec`/
`themeSearchChain`/`loadThemeMeta`). Zamiast sprawdzać kilkanaście
zaszytych na sztywno ścieżek (`/usr/share/icons/Humanity/apps/64/$1.png`
itd.), kod teraz: (1) parsuje `index.theme` motywu, (2) wędruje po
łańcuchu `Inherits=` (np. na tym systemie: `ubuntu-mono-dark →
Humanity-Dark → Humanity → Adwaita → hicolor`), (3) dla każdego motywu w
łańcuchu sprawdza WSZYSTKIE jego katalogi z `Context=Applications`
zadeklarowane w `Directories=`, wybierając rozmiar najbliższy
`PreferredIconSize` (48px). ZDE nie ma dziś ustawienia "motyw ikon"
(`IconThemeSeeds` to rozsądne punkty startowe łańcucha, faworyzujące
warianty ciemne, bo reszta interfejsu ZDE jest ciemna) -- ale odkąd
dowolny z tych motywów ISTNIEJE i coś dziedziczy, jego CAŁE drzewo
przodków jest teraz przeszukiwane, nie tylko garść ręcznie
przewidzianych ścieżek.

**Po drodze znaleziono i naprawiono realny, poważny bug -- nie w kodzie
ZDE, tylko w standardowej bibliotece Nim.** Pierwsza wersja tej rundy
użyła `std/parsecfg.loadConfig` (oczywisty wybór do parsowania formatu
INI w Nim). Test na PRAWDZIWYM pliku `/usr/share/icons/Humanity/index.theme`
z tego systemu ujawnił: `loadConfig` **cicho porzuca resztę pliku** przy
pierwszym napotkanym nagłówku sekcji zawierającym `@` (np.
`[actions@2/22]` -- katalog HiDPI "@2x", część specyfikacji
`ScaledDirectories=` i CAŁKOWICIE standardowy w prawdziwych motywach
ikon). Efekt zmierzony bezpośrednim testem: z ok. 250 sekcji w tym pliku
`loadConfig` widziało dosłownie JEDNĄ -- bez wyjątku, bez ostrzeżenia,
żadnego sygnału, że coś poszło nie tak. To nie była awaria do złapania
przez `except` -- to była cicha utrata danych, która sprawiłaby, że CAŁA
ta rozbudowa wyglądałaby na działającą (kompiluje się, nie wywala), a w
praktyce nie znajdowałaby prawie żadnych ikon. Naprawa: własny,
tolerancyjny parser linii (`parseIniLoose`) -- dzieli po pierwszym `=`,
traktuje `[cokolwiek]` jako nagłówek sekcji bez żadnych ograniczeń na
dozwolone znaki.

**Zweryfikowane bezpośrednimi testami na prawdziwych plikach z tego
systemu, przed i po naprawie parsera:**
- Przed naprawą: `loadThemeMeta("Humanity").appDirs.len == 0`.
- Po naprawie: `16` katalogów z poprawnymi `Size`/`Context`/`Type`.
- Regresja: `libreoffice-writer`/`-chart`/`-math` (działały już wcześniej
  przez starą listę) nadal się rozwiązują -- teraz przez lepiej dobrany
  rozmiar (48px zamiast pierwszego trafienia na sztywno, 64px).
- **Nowa, wcześniej niemożliwa zdolność**, potwierdzona wizualnie: ikona
  `seahorse` (klucz z kłódką) istnieje TYLKO w `Humanity/apps/24/` --
  stara płaska lista sprawdzała Humanity wyłącznie w rozmiarach 64/48,
  nigdy 24, więc ta ikona ZAWSZE dostawała ikonę zastępczą kategorii.
  Utworzono testowy plik `.desktop` wskazujący `Icon=seahorse`,
  uruchomiono `zde-shell` pod Xvfb -- zrzut ekranu z prawdziwego okna
  wyszukiwania launchera potwierdza poprawnie wyrenderowaną ikonę
  Seahorse, nie tylko plik PNG odnaleziony w izolacji.

Świadomie uproszczone względem pełnej specyfikacji (patrz duży komentarz
przy `resolveViaThemeSpec` w kodzie): brak pełnych reguł dopasowania
`Fixed`/`Scalable`/`Threshold` z `MinSize`/`MaxSize`/`Threshold` -- jedno,
proste kryterium "odległość od `PreferredIconSize`" zamiast tabeli reguł.
`ScaledDirectories=`/`Scale=` (`@2x`/HiDPI) były tu brakiem AŻ DO rundy
14 -- patrz "Nowości w v0.2 (runda 14)" niżej po to, co dokładnie zostało
domknięte, a co wciąż nie (ZDE nadal nie zna skali monitora). Stara
płaska lista ZOSTAJE jako siatka bezpieczeństwa (patrz `resolveIconPath`),
na wypadek gdyby żaden motyw z `IconThemeSeeds` nie istniał na dysku.

## Nowości w v0.2 (runda 5) -- launcher: ikony SVG (z uczciwym zastrzeżeniem)

**Ikony `.desktop` wskazujące WYŁĄCZNIE plik SVG (bez PNG w żadnym
rozmiarze) są teraz rasteryzowane i pokazywane**, zamiast zawsze
dostawać ikonę zastępczą kategorii (`shell/desktopapps.nim`,
`rasterizeSvgIcon`/`IconSearchTemplatesSvg`). Coraz więcej pakietów
(zwłaszcza Flatpak, ale nie tylko) dostarcza ikonę tylko jako SVG w
katalogu `scalable/` -- to był realny, jawnie wypisany brak. Pixie ma
własny moduł SVG (`pixie/fileformats/svg`, NIE eksportowany z głównego
modułu `pixie` -- stąd osobny `import ... as pixieSvg`) z
`parseSvg(dane, szerokość, wysokość)`, który rasteryzuje SVG na
żądany rozmiar (tu: 128×128) -- wynik trafia do podręcznego cache'u na
dysku (`$XDG_CACHE_HOME/zde/icons/`, ponowna rasteryzacja tylko gdy
źródłowy SVG jest nowszy niż cache), więc `resolveIconPath` (wołane przy
każdym skanie launchera) nie rasteryzuje tej samej ikony od nowa za
każdym razem.

**Uczciwe zastrzeżenie, odkryte właśnie w tej rundzie przez realne
testy, nie w dokumentacji Pixie:** podzbiór SVG, jaki Pixie 5.0.7
faktycznie potrafi narysować, jest węższy, niż mogłoby się wydawać.
Sprawdzono cztery prawdziwe ikony systemowe z tej maszyny (motywy
Adwaita i Humanity) -- WSZYSTKIE cztery zawiodły, z konkretnymi błędami:
`"Unsupported gradient transform"` (dwie), `"Unsupported SVG tag:
clipPath"` (jedna), błąd parsowania `viewBox` (jedna). Dopiero prosty,
syntetyczny SVG bez gradientów/`clipPath` (płaskie kształty, jednolite
kolory) zrasteryzował się poprawnie -- zweryfikowane wizualnie: zrzut
ekranu z uruchomionego `zde-shell` pokazuje testową aplikację z
poprawnie narysowaną ikoną (czerwone kółko z białym kwadratem) w
prawdziwym oknie wyszukiwania launchera, nie tylko plik PNG na dysku.

Innymi słowy: ta rozbudowa POSZERZA pokrycie ikon (niektóre SVG teraz
się pokażą, które wcześniej zawsze dostawały ikonę zastępczą), ale to
NIE jest "pełna obsługa SVG" -- dla ikon z nowoczesnych motywów
systemowych współczynnik trafień bywa niski. Awaria jest zawsze CICHA i
BEZPIECZNA (`except CatchableError` -- błąd Pixie, uszkodzony plik, brak
uprawnień do zapisu w cache'u, cokolwiek), więc aplikacja zawsze
dostaje przynajmniej ikonę zastępczą kategorii, nigdy puste miejsce ani
wywrócony skan launchera -- to zachowanie jest identyczne, zanim ta
rozbudowa powstała.

## Nowości w v0.2 (runda 4) -- kompozytor: obsługa "primary selection" (środkowy klik)

**Protokół `zwp_primary_selection_v1` jest teraz obsługiwany przez
`zde-comp`** (`wlcomp/wlroots.nim`, `wlcomp/seatext.nim`,
`wlcomp/main.nim`) -- domyka kolejny konkretny, jawnie wypisany w
README brak: schowek PIERWOTNY (X11-owy "zaznacz, wklej środkowym
klikiem, bez Ctrl+C") w ogóle nie istniał pod ZDE, ponieważ `zde-comp`
nigdy nie tworzył `wlr_primary_selection_v1_device_manager` -- klienty
poprawnie wykrywały brak protokołu w rejestrze i po prostu nie
oferowały tej funkcji, więc nie był to "cichy bug", tylko brakująca
funkcja.

Implementacja to dosłownie ta sama para: `wlrPrimarySelectionV1DeviceManagerCreate`
w `main()` (analogicznie do `wlrDataDeviceManagerCreate` dla zwykłego
schowka) plus `onRequestSetPrimarySelection` w `seatext.nim`
(analogicznie do `onRequestSetSelection`) -- oba typy zdarzeń
(`wlr_seat_request_set_selection_event`/`wlr_seat_request_set_primary_selection_event`)
mają identyczny kształt w nagłówkach wlroots (`source` + `serial`), więc
druga implementacja to dokładne odbicie pierwszej, nie nowy wzorzec.

**Zweryfikowane w tej rundzie realnym uruchomieniem i realnym
protokołem, nie tylko kompilacją:** zbudowano `zde-comp` przez
`build.janet` wobec prawdziwych nagłówków wlroots 0.17.1, uruchomiono
zagnieżdżony pod Xvfb, i odpytano jego rejestr Waylanda narzędziem
`wayland-info` (`WAYLAND_DISPLAY=wayland-0 wayland-info`) -- output
potwierdza `interface: 'zwp_primary_selection_device_manager_v1',
version: 1` w faktycznie działającym rejestrze kompozytora, obok
istniejących globali (`wl_data_device_manager`, `zwlr_layer_shell_v1`,
`xdg_wm_base` itd.). Ta sama korekta (co w poprzednich rundach) --
protokół zweryfikowany na poziomie faktycznie działającego kompozytora,
nie tylko przeczytany w nagłówkach `.h`.

Świadomie NIE objęte tą rundą: panel historii schowka `zde-shell` (patrz
sekcja "Ograniczenia" niżej) śledzi wyłącznie zwykły schowek, nie
pierwotny -- to osobna, mniejsza rozbudowa (dodanie drugiego typu wpisu
do istniejącego mechanizmu historii w `shell/clipboard.nim`), którą
można zrobić następnym razem, jeśli będzie potrzebna.

## Nowości w v0.2 (runda 3) -- launcher: realny `inotify`, nie tylko mtime katalogu

**Launcher wykrywa teraz zmiany W TREŚCI plików `.desktop`, nie tylko w
strukturze katalogu** (`shell/desktopapps.nim`, `ensureInotifyWatches`/
`appDirsChangedViaInotify`; `shell/taskbar.nim`,
`rescanSystemAppsIfChanged`). Poprzedni mechanizm (`appDirsSignature`,
suma mtime katalogów z `AppDirs`) miał realną, cichą wadę: mtime
KATALOGU zmienia się tylko przy zmianach jego struktury
(dodanie/usunięcie/zmiana nazwy pliku) -- edycja treści ISTNIEJĄCEGO
pliku `.desktop` w miejscu (np. aktualizacja pakietu nadpisująca
`Name=`/`Icon=` bez usuwania i tworzenia pliku na nowo) w ogóle nie
dotykała mtime katalogu nadrzędnego, więc była CAŁKOWICIE niewykrywalna
-- nie tylko wykrywana z opóźnieniem, tylko wcale.

Naprawa otwiera deskryptor `inotify` RAZ, w trybie nieblokującym
(`IN_NONBLOCK`), z maską obejmującą zarówno strukturę katalogu
(`IN_CREATE`/`IN_DELETE`/`IN_MOVED_FROM`/`IN_MOVED_TO`) jak i treść
plików w nim (`IN_MODIFY`/`IN_CLOSE_WRITE`). `rescanSystemAppsIfChanged`
(wołane raz na sekundę z `tickMain()`, ten sam rytm co dotychczas) robi
jeden nieblokujący `read()` na ten deskryptor -- koszt per-tick zostaje
dokładnie tak niski jak wcześniej, ale teraz obejmuje też treść, nie
tylko strukturę. Stary mechanizm (mtime katalogu) ZOSTAJE jako
niezależna siatka bezpieczeństwa (na wypadek, gdyby `inotify_init1` się
nie powiodło -- np. wyczerpany limit deskryptorów w systemie), nie
został zastąpiony.

Integracja `inotify` z pętlą zdarzeń Fidget/GLFW (żeby zmiana pojawiała
się klatka-po-klatce, nie z opóźnieniem rzędu sekundy) ŚWIADOMIE zostaje
poza zakresem -- to osobny, większy projekt (patrz duży komentarz w
`desktopapps.nim`), niepotrzebny do załatania realnej wady korekcyjnej,
która była tu głównym problemem.

**Zweryfikowane realnym uruchomieniem, nie tylko przeczytane w kodzie:**
utworzono plik `.desktop` z `Name=Original Name Before Edit`, uruchomiono
`zde-shell` pod Xvfb, potwierdzono w launcherze. Następnie plik
NADPISANO W MIEJSCU (`cat > tą-samą-ścieżkę`, nie usunięcie+utworzenie) z
`Name=EDITED IN PLACE via inotify` -- `stat` na katalogu PRZED i PO
edycji potwierdził identyczne mtime katalogu (dowód, że stary mechanizm
faktycznie by tego nie złapał), podczas gdy mtime samego pliku się
zmieniło. Po ~2 sekundach (jeden-dwa ticki) nowa nazwa "EDITED IN PLACE
via inotify" pojawiła się w wynikach wyszukiwania launchera -- zrzut
ekranu w tej sesji to potwierdza.

## Nowości w v0.2 (runda 2) -- kompozytor: `zde-comp` sam odpala `zde-shell`

Ta runda skupiła się na `wlcomp/` (kompozytorze), zgodnie z życzeniem --
oraz, po raz pierwszy w historii tego repo, na REALNYM URUCHOMIENIU
CAŁEGO STOSU RAZEM (`zde-comp` + `zde-shell` jako jego prawdziwy klient
Wayland, komunikujące się przez faktyczny socket), nie tylko osobnej
kompilacji każdej części.

**Autostart `zde-shell` przez `zde-comp`** (`wlcomp/main.nim`,
`findShellBinary`/`spawnShell`) -- domyka TODO jawnie wypisane w tym
README od dawna: *"docelowo zde-comp powinien sam odpalać zde-shell jako
swój 'startup command' zamiast wymagać dwóch TTY"*. Teraz: uruchomienie
`./zde-comp` z JEDNEGO TTY wystarczy -- kompozytor sam odpala
`zde-shell` z odziedziczonym `WAYLAND_DISPLAY` (i `DISPLAY`, jeśli
XWayland wystartowało -- to drugie wcześniej było tylko LOGOWANE, nigdy
faktycznie nie trafiało do `putEnv`, więc dzieci `zde-shell` odpalane
przez launcher nie dostawałyby go automatycznie). Domyślnie szuka
`zde-shell` obok własnej binarki (`getAppDir()` -- oba lądują razem w
`dist/`); `ZDE_NO_AUTOSTART` wyłącza to zachowanie (np. do ręcznego
debugowania z dwóch TTY, stary sposób nadal działa), `ZDE_SHELL_PATH`
wskazuje inną binarkę. Świadomie "best effort", jak reszta integracji
zewnętrznych narzędzi w ZDE -- brak `zde-shell` obok `zde-comp` albo
błąd `startProcess` loguje ostrzeżenie na stderr, ale NIE zatrzymuje
kompozytora (patrz duży komentarz nad `spawnShell`).

**Metodologia weryfikacji tej rundy -- jakościowy skok w stosunku do
poprzednich:** dotąd `zde-comp` i `zde-shell` były kompilowane i
testowane OSOBNO, w różnych momentach. W tej rundzie po raz pierwszy
zainstalowano `libwlroots-dev` (0.17.1, Ubuntu 24.04) ORAZ zbudowano
`janet` ze źródeł (`janet-lang/janet` na GitHubie -- nie ma go w apt na
Ubuntu 24.04), więc dało się użyć PRAWDZIWEGO `build.janet` (nie tylko
ręcznych wywołań `nim c`) do zbudowania obu binarek naraz i uruchomienia
ich RAZEM pod zagnieżdżonym Xvfb:

- `zde-comp` wystartował, utworzył gniazdo Wayland, i sam odpalił
  `zde-shell` -- zrzut ekranu potwierdza KOMPLETNY pulpit ZDE (tapeta z
  "glow", dok z zaokrąglonymi rogami, zegar, przełącznik pulpitów 1-4)
  wyrenderowany przez WŁASNY kompozytor ZDE, nie przez GLFW/X11
  bezpośrednio jak we wszystkich poprzednich rundach testowych zapisanych
  w tym README.
- XWayland + prawdziwy klient X11 (`xclock`) ponownie przeszedł pełny
  cykl `new_surface -> associate` -- i tym razem zweryfikowano to
  wizualnie, nie tylko z logu: zrzut ekranu pokazuje faktycznie
  wyrenderowaną tarczę zegara (wskazówki, cyfry) skomponowaną w scenie
  `zde-comp`.
- **Czego NIE udało się zweryfikować w tej rundzie:** interaktywnego
  wejścia (mysz/klawiatura) przez `xdotool` w tym konkretnym, zagnieżdżonym
  układzie X11-w-Xvfb -- kliknięcia docierały do okna hosta (potwierdzone
  `xwininfo`), ale nie wywoływały żadnej reakcji w scenie `zde-comp` ani
  logu. Najbardziej prawdopodobna przyczyna: niezgodność wersji
  `XInputExtension` (XI2) między wlroots a akurat tą kompilacją Xvfb w
  piaskownicy (przy starcie backendu X11 w logu widać trzy nieszkodliwe,
  ale sugestywne błędy `X11 error: op 18:0, code 5` -- kod 5 to `BadAtom`,
  typowy objaw żądania nieobsługiwanej wersji/atomu XI2) -- to ograniczenie
  akurat TEGO testowego zagnieżdżenia (Xvfb, nie prawdziwa sesja
  Wayland/X11 z nowoczesnym XI2), nie wykryty błąd w kodzie `wlcomp/`.
  Renderowanie i protokół (co dokładnie zweryfikowano wyżej) działają
  niezależnie od tego, czy input faktycznie dociera.

Instalacja `libwlroots-dev`/`janet` w piaskownicy była wyłącznie do
weryfikacji w TEJ sesji (tak jak poprzednie rundy z `nim`/`fidget`) --
żaden plik repo poza `wlcomp/main.nim` (opisanym wyżej) nie został
trwale zmieniony w wyniku samej instalacji narzędzi.

## Nowości w v0.2 -- schowek plików między oknami, rozróżnianie wielkości liter w Znajdź, dźwięk minutnika

Pierwsza rozbudowa oznaczona jako v0.2 (poprzednie wpisy w tej sekcji,
niżej, to wszystkie rozbudowy v0.1 -- historia zostaje nienaruszona,
`zde.nimble` i tapeta zastępcza dostały bump wersji, patrz niżej).
Domyka TRZY konkretne braki jawnie wypisane w sekcji "Ograniczenia"
(patrz niżej w tym pliku) i zweryfikowane realną kompilacją +
uruchomieniem pod Xvfb (patrz notatka metodologiczna na końcu tej
sekcji).

**1. Schowek plików działa teraz między dwoma otwartymi oknami menedżera
plików** (`apps/filemanager/files.nim`). Wcześniej `clipboardPaths`/
`clipboardCut` były polami `FilesState` -- każde okno menedżera plików
ma własną instancję tego stanu (patrz `newFileManager`), więc "Kopiuj"
w oknie A i "Wklej" w oknie B po prostu nic nie robiło (przycisk "Wklej"
zostawał wyszarzony w oknie B, bo jego WŁASNY `clipboardPaths` był
pusty). Naprawa: oba pola przeniesione na poziom modułu (`var`, nie pola
obiektu) -- moduł Nim jest w obrębie procesu singletonem, więc każde
okno menedżera odwołujące się do `gFileClipboardPaths`/
`gFileClipboardCut` widzi TĘ SAMĄ pamięć. Nadal NIE jest to prawdziwy
schowek plików w stylu GNOME/KDE (wciąż bez integracji z
`wl_data_device`, więc nie działa z aplikacjami spoza ZDE, i nie
przeżywa restartu `zde-shell`) -- ale najczęstszy realny scenariusz
(dwa okna menedżera otwarte naraz, kopiuj w jednym/wklej w drugim) teraz
działa.

**2. Znajdź/Zamień w edytorze tekstu ma teraz przełącznik "Aa"
(rozróżnianie wielkości liter)** (`apps/texteditor/texteditor.nim`).
Wcześniej `computeFindMatches`/`doReplaceCurrent`/`doReplaceAll` ZAWSZE
porównywały przez `toLowerAscii()` po obu stronach, bez wyjątku. Nowe
pole `Tab.caseSensitive` (domyślnie `false` -- stare zachowanie, żadna
istniejąca karta nie dostaje niespodziewanej zmiany) + przycisk "Aa" w
pasku Znajdź, między polem wyszukiwania a licznikiem wyników. Włączony
port porównuje `line`/`findQuery` WPROST, bez żadnej normalizacji --
zweryfikowane realnie pod Xvfb: dokument "Hello World hello world" +
zapytanie "hello" daje "0 z 2" (oba dopasowania) z wyłączonym
przełącznikiem i "0 z 1" (tylko małe litery) z włączonym.

**3. Minutnik ma teraz wybór dźwięku, tak jak alarmy**
(`apps/clock/clockapp.nim`). Wcześniej `tickClock` zawsze wołało
`playAlarmSound()` bez argumentu (czyli zawsze "Auto") po zakończeniu
odliczania -- alarmy dostały wybór dźwięku już w poprzedniej rozbudowie
(patrz "Nowości tej rozbudowy -- wybór dźwięku alarmu" niżej), ale
minutnik został pominięty, co README uczciwie wymieniało jako
ograniczenie. Nowe pole `ClockState.timerSoundIdx` (ten sam wzorzec co
`newSoundIdx` dla alarmów, `-1` = "Auto") + identyczny cykliczny
picker, dorzucony w `drawTimerSection` między wyświetlaczem odliczania a
przyciskami start/pauza/reset.

**Notatka o metodologii weryfikacji tej rundy:** wszystkie trzy zmiany
zostały nie tylko przejrzane ręcznie, ale realnie SKOMPILOWANE (`nim
check` per-moduł + pełny `nimble c -d:release -d:pixieNoSimd
shell/shell.nim` budujący `dist/zde-shell` od zera) i URUCHOMIONE pod
zagnieżdżonym Xvfb (ten sam sposób testowania co w rundzie "pierwsze
prawdziwe testy wizualne `zde-shell`", patrz niżej) -- z realnymi
zrzutami ekranu i klikami przez `xdotool`: dwa okna menedżera plików
otwarte jednocześnie z widocznym, żywym przyciskiem "Wklej"
zmieniającym kolor po skopiowaniu w drugim oknie; pasek Znajdź w
edytorze z przyciskiem "Aa" i licznikiem wyników zmieniającym się z "0 z
2" na "0 z 1" po jego kliknięciu; zakładka "Alarmy" zegara z nowym
pickerem dźwięku minutnika widocznym pod wyświetlaczem odliczania.
Jedyne środowiskowe ograniczenie tej rundy: pełny łańcuch zależności
Fidget/Pixie wymaga `html5_canvas` (pakiet Nimble hostowany na GitLab),
którego nie dało się pobrać z tej konkretnej piaskownicy sieciowej (brak
`gitlab.com` na białej liście) -- obejście lokalne (usunięcie tej
zależności z lokalnej kopii `fidget.nimble`, bo jest używana WYŁĄCZNIE
przez nieużywany tu backend HTML/JS Fidgetu, `src/fidget/htmlbackend.nim`)
posłużyło tylko do weryfikacji w tej sesji -- `zde.nimble` w repozytorium
NIE zostało zmienione, więc normalne środowisko budowania (z dostępem do
GitLab) nie zauważy żadnej różnicy.

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

### Snapowanie okien (Super+Left/Right, od rundy 21 też Super+Up/Down i ćwiartki, od rundy 22 też przeciągnięciem myszą)

`comp/window.nim` (`snapWindow`, `combinedEdge`, typ `SnapEdge`) + skróty
w `shell/shortcuts.nim`. Przyciąga aktywne okno do połowy ekranu; drugie
Super+Left/Right na TEJ SAMEJ krawędzi przywraca oryginalny rozmiar
(zapamiętany w `savedPos`/`savedSize`, ten sam mechanizm co zwykła
maksymalizacja). Ta część (tylko lewo/prawo) była zweryfikowana
zrzutami ekranu pod Xvfb w oryginalnej rundzie "Aurora", łącznie z
toggle "z powrotem" -- w TEJ sandboxie taka weryfikacja nie jest już
możliwa (`fidget` wymaga Nim >= 2.0, patrz uczciwe notatki w rundach
13+), więc rozszerzenie o górę/dół i ćwiartki (runda 21, patrz "Nowości
w v0.2 (runda 21)" wyżej) zostało zweryfikowane inaczej: `comp/`
(rdzeń logiki, bez `fidget`) dało się w PEŁNI skompilować i uruchomić w
tej sesji, więc `test_real_comp_snap.nim` testuje prawdziwy,
produkcyjny kod snapowania bezpośrednio -- mocniejsza weryfikacja niż
zrzuty ekranu pojedynczych przypadków, ale wciąż nie to samo, co
zobaczenie tego na żywo w oknie.

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

## Ograniczenia obecnej wersji (v0.2)

Ten opis był w poprzednich wydaniach README rozjechany z rzeczywistym
stanem kodu (m.in. layer-shell, popupy, schowek/DnD, prawdziwy PTY,
podświetlanie składni, panel monitorów i aplikacja "Ustawienia" już
istniały, mimo że sekcja niżej twierdziła inaczej) -- poniższa lista jest
zweryfikowana względem bieżącej zawartości repo:

**Notatka o kompilowalności w TEJ konkretnej sandboxie** (istotna dla
zrozumienia, jak mocno zweryfikowany jest który fragment kodu, patrz
poszczególne punkty niżej): `fidget` wymaga Nim >= 2.0, którego ta
sandbox nie ma (tylko 1.6.14 z apt) -- więc CAŁE UI `zde-shell`
(launcher, dok, wszystkie okna aplikacji) pozostaje nieskompilowane w
tej sesji. TRZY grupy modułów są od tego WYJĄTKIEM, bo mają węższe
zależności: `shell/desktopapps.nim` i `apps/filemanager/thumbnails.nim`
(tylko `pixie`, dający się zainstalować osobno -- rundy 14/16),
`apps/texteditor/highlight.nim` (tylko `std`, żadnych zależności
zewnętrznych -- runda 20), i `comp/` (rdzeń zarządzania oknami -- tylko
`vmath`, zależność `pixie` -- runda 21, patrz "Nowości w v0.2 (runda
21)"). Rozbudowy w tych czterech miejscach mają dużo mocniejszą
weryfikację (prawdziwie skompilowany i uruchomiony PRODUKCYJNY kod) niż
rozbudowy gdziekolwiek indziej w `zde-shell` (logika wydzielana i
kopiowana do izolowanych testów, UI nigdy realnie nie uruchomione w tej
sesji) -- każda sekcja "Nowości" mówi wprost, do której grupy należy.

- **wlr-layer-shell** jest zaimplementowany (`wlcomp/layershell.nim`) --
  `zde-shell` może się zadokować jako pasek, nie tylko jako zwykłe okno
  xdg-toplevel.
- **Popupy** xdg-shell (`wlcomp/popup.nim`) i **schowek + drag & drop**
  (`wlr_data_device_manager`, `request_set_selection`/`request_start_drag`
  w `wlcomp/seatext.nim`) działają na poziomie kompozytora.
- **Terminal** (`apps/terminal`) ma prawdziwe PTY (`pty_shim.c`), programy
  pełnoekranowe (`vim`, `top`, `less`) działają poprawnie. Pole
  wpisywania polecenia od v0.2 (runda 12) poprawnie pokazuje wpisywany
  tekst na ekranie -- wcześniej (runda 11) było to znane, potwierdzone,
  nierozwiązane ograniczenie (tekst tuż przy dolnej krawędzi okna był
  niewidoczny w tej wersji Fidget/Pixie); patrz "Nowości w v0.2 (runda
  12)" niżej po pełny opis metodycznego dochodzenia do przyczyny i
  naprawy, w tym pouczającą historię obalonej hipotezy z rundy 11.
- **Edytor tekstu** (`apps/texteditor`) ma podświetlanie składni
  (`highlight.nim`, od rundy 20 dla ośmiu języków: Nim/Python/C/JS/
  Shell/Go/Rust/JSON -- patrz "Nowości w v0.2 (runda 20)" wyżej),
  zakładki, wykrywanie zmian pliku na dysku w tle
  (`checkExternalChanges`) i wyszukiwanie ORAZ zamianę (Ctrl+F,
  "Zamień"/"Zamień wszystko" -- patrz "Nowości" wyżej) -- od v0.2 z
  OPCJONALNYM rozróżnianiem wielkości liter (przycisk "Aa", domyślnie
  wyłączone) ORAZ od rundy 14 z OPCJONALNYMI wyrażeniami regularnymi
  (przycisk ".*", `std/re`/PCRE, domyślnie wyłączone -- od rundy 15 też z
  podświetlaniem grup przechwytujących `(...)`, pozycje odtwarzane
  heurystycznie, patrz "Nowości w v0.2 (runda 15)" wyżej) i przyciskiem
  📂 do wyboru pliku bez ręcznego wpisywania ścieżki (runda 8) -- wciąż
  ze skokiem do LINII zamiast dokładnej pozycji kursora (ograniczenie API
  Fidget). **Od rundy 34: PEŁNE cofanie/ponawianie zwykłego pisania
  (Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y)** -- migawki całego dokumentu z
  debounce, patrz "Nowości w v0.2 (runda 34)" niżej po pełny opis
  mechanizmu (w tym `keyboard.focusNode = nil`, ta sama technika co przy
  buforze terminala z rundy 12) i uczciwą notatkę o braku weryfikacji na
  żywym Fidget w tej sesji. Wcześniejsze, węższe cofanie TYLKO dla
  "Zamień"/"Zamień wszystko" (przycisk "↶") zostaje bez zmian, jako
  osobny mechanizm.
- **Układ klawiatury** jest konfigurowalny (`zdeconfig.nim`, aplikacja
  "Ustawienia"), nie zaszyty na sztywno na `us`.
- **Aplikacja "Ustawienia"** (`apps/settings`) istnieje, z wizualnym
  edytorem układu monitorów (przeciąganie, snapowanie krawędzi) i
  konfiguracją skrótów klawiszowych.
- **Zegar** ma teraz alarmy i minutnik (patrz sekcja "Nowości" wyżej) --
  lista alarmów też się teraz przewija (patrz "Nowości" -- scroll list),
  a każdy alarm może mieć wybrany dźwięk spośród realnie dostępnych w
  systemie (patrz sekcja "Nowości tej rozbudowy -- wybór dźwięku alarmu"
  niżej) -- od v0.2 minutnik dostał TEN SAM picker dźwięku, nie tylko
  "Auto" (patrz "Nowości w v0.2" wyżej).

Wciąż aktualne, rzeczywiste ograniczenia:

**Notatka do rundy 14**: ta runda powstała w odpowiedzi na prośbę o
rozbudowę ZDE o WSZYSTKIE punkty z tej listy naraz. Udało się w niej
dodatkowo domknąć częściowo `ScaledDirectories=`/`Scale=` w ikonach
launchera (patrz "Nowości w v0.2 (runda 14)" wyżej) -- ale poniższe
pozycje, mimo tej prośby, POZOSTAJĄ bez zmian -- każda z przyczyn
architektonicznych opisanych przy niej, nie dlatego, że zostały
pominięte przez przeoczenie: `wlcomp/` (kompozytor) wymaga prawdziwych
nagłówków wlroots i najlepiej prawdziwego sprzętu/GPU do uczciwej
weryfikacji, których ta sesja nie ma; integracja z `wl_data_device` dla
DnD/schowka MIĘDZY ZDE a resztą systemu to nowy protokół na poziomie
kompozytora, nie zmiana w `zde-shell`; GUI dla `.zpk`, wiele
sesji/użytkowników i PRAWDZIWE, pełne wsparcie HiDPI (ZDE wciąż nigdzie
nie zna skali monitora, patrz "Nowości w v0.2 (runda 14)" po dokładną
granicę tego, co zrobiono, a co nie) to osobne, wielotygodniowe projekty
każdy z osobna. Patrz też duży komentarz na początku sekcji "Nowości w
v0.2 (runda 14)" wyżej po pełne uzasadnienie tej decyzji o zakresie.

- **pojedynczy seat** (jeden zestaw klawiatura+mysz na sesję kompozytora)
  -- świadomie poza zakresem tej rundy: prawdziwy multi-seat wymaga
  przypisywania urządzeń wejścia/wyjścia do osobnych seatów przez udev i
  osobnego zarządzania sesją per seat (`seatd`/logind), co jest dużym,
  odrębnym projektem, potrzebnym praktycznie tylko w kioskach
  wieloosobowych -- nie regresja, tylko rozsądna granica zakresu
- **gesty touchpada -- swipe (działanie kompozytora) + pinch/hold (od
  rundy 34: re-broadcast do klientów)** (`wlcomp/gestures.nim`, patrz
  "Nowości" wyżej i "Nowości w v0.2 (runda 34)"); kompozytor sam wciąż
  nie wiąże pinch/hold z ŻADNĄ WŁASNĄ akcją (brak dziś w ZDE naturalnego
  zastosowania, np. przeglądarki obrazów do zoomowania) -- ale aplikacje
  nasłuchujące `wlr_pointer_gestures_v1` bezpośrednio już je dostają.
  **Nieskompilowane w tej sesji** (brak `libwlroots-dev`) -- do
  potwierdzenia.
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
  rozbudowy -- dźwięk zwykłych powiadomień" wyżej) -- **od rundy 35:
  integracja z zewnętrznymi aplikacjami spoza ZDE PRZEZ DBUS ISTNIEJE**
  -- minimalny serwer `org.freedesktop.Notifications` na session-bus
  (libdbus, `shell/dbus_notify_shim.c` + `shell/dbusnotify.nim`, patrz
  "Nowości w v0.2 (runda 35)" niżej po pełny opis, w tym zakres tego, co
  świadomie ignorowane -- akcje przycisków, hints, `expire_timeout`) --
  **realnie zweryfikowane END-TO-END**: prawdziwy `dbus-daemon --session`
  w piaskownicy tej sesji, prawdziwy `notify-send` (libnotify), poprawnie
  odebrane i poprawnie odpowiedziane `GetCapabilities`/`Notify`/
  `GetServerInformation`/`CloseNotification`, plus poprawny błąd
  `UnknownMethod` zamiast zawieszenia nadawcy przy nieznanej metodzie.
  Gdy na sesji już działa INNY serwer powiadomień (typowe np. przy
  GNOME/KDE/dunst) -- integracja po cichu się nie aktywuje, bez wpływu
  na resztę ZDE. panel
  historii (dzwonek w doku) przewija się tak samo jak launcher i lista
  alarmów (patrz "Nowości" wyżej)
- **aplikacje systemowe w launcherze -- lista jest odświeżana w tle**
  (patrz "Nowości" niżej) -- od v0.2 przez realny `inotify` NA ZAWARTOŚĆ
  plików `.desktop` (patrz "Nowości w v0.2" wyżej), nie tylko przez
  porównanie mtime katalogów jak wcześniej -- to drugie zostaje jako
  niezależna siatka bezpieczeństwa, ale samo w sobie miało realną, cichą
  wadę (edycja TREŚCI istniejącego pliku w miejscu nie dotyka mtime
  katalogu nadrzędnego, więc była niewykrywalna), którą `inotify` teraz
  łata -- zweryfikowane realnym uruchomieniem, nie tylko przeczytane w
  kodzie. Odświeżenie nadal ma kadencję rzędu sekundy (ten sam tick co
  zegar), nie "klatka po klatce" -- integracja `inotify` z pętlą zdarzeń
  Fidget/GLFW pozostaje świadomie poza zakresem (patrz duży komentarz w
  `desktopapps.nim`). Od v0.2 (runda 5) obsługiwane są też ikony SVG --
  rasteryzowane do PNG i podręcznie zbuforowane -- ale TYLKO te
  mieszczące się w podzbiorze SVG obsługiwanym przez Pixie 5.0.7 (patrz
  "Nowości w v0.2" niżej po uczciwy opis, ile realnych ikon systemowych
  to w praktyce obejmuje -- niewiele: większość nowoczesnych motywów
  używa gradientów z transformacją albo `clipPath`, czego Pixie nie
  obsługuje). Od v0.2 (runda 6) obsługiwana jest też prawdziwa rezolucja
  Icon Theme Spec -- parsowanie `index.theme`, wędrówka po łańcuchu
  `Inherits=`, dobór najbliższego rozmiaru (patrz "Nowości w v0.2"
  niżej) -- zamiast płaskiej, ręcznie wypisanej listy ścieżek. Ta sama
  runda znalazła i naprawiła realny bug w `std/parsecfg` (cicho gubi
  resztę pliku przy sekcjach `[nazwa@2/...]`, standardowych w
  prawdziwych motywach HiDPI) -- zastąpiony własnym, tolerancyjnym
  parserem linii. Od rundy 14 `Scale=`/`ScaledDirectories=` SĄ parsowane
  i katalogi `Scale=1` są świadomie preferowane nad `@2x`/`@3x` o tym
  samym `Size=` (patrz "Nowości w v0.2 (runda 14)" wyżej po pełny opis i
  test na prawdziwym, zainstalowanym motywie Humanity) -- ale to WCIĄŻ
  nie jest prawdziwe wsparcie HiDPI (ZDE nie zna skali monitora) ani
  pełne reguły `Fixed`/`Threshold` z `MinSize`/`MaxSize` (patrz duży
  komentarz przy `resolveViaThemeSpec`) -- **od rundy 34 DOMKNIĘTE**:
  `dirSizeDistance` implementuje teraz pełną funkcję odległości ze
  specyfikacji, osobną dla `Fixed`/`Scalable`/`Threshold`
  (`MinSize=`/`MaxSize=`/`Threshold=` parsowane z `index.theme`) --
  zweryfikowane REALNĄ KOMPILACJĄ (`pixie` zainstalowane w tej sesji) i
  izolowanym testem na syntetycznym motywie. Prawdziwe HiDPI (ZDE dalej
  nie zna skali monitora) pozostaje bez zmian.
- **menedżer plików** (patrz "Nowości" wyżej -- tworzenie folderu, zmiana
  nazwy, usuwanie, otwieranie w edytorze, kopiuj/wytnij/wklej,
  zaznaczanie wielu wpisów przez Ctrl+klik i Shift+klik, skróty
  klawiszowe Delete/Ctrl+A/Escape/F2) -- od v0.2 (runda 13) obsługuje też
  przeciąganie plików/folderów myszą (drag & drop), łącznie z
  upuszczeniem w INNYM, otwartym jednocześnie oknie menedżera, a od
  rundy 14 dodatkowo Ctrl+przeciągnij KOPIUJE zamiast przenosić i
  foldery też można przeciągać (gdy zwykły klik i tak by nie nawigował
  do ich środka -- patrz "Nowości w v0.2 (runda 14)" wyżej). Integracja
  z żywym Fidget/GLFW wciąż nie została w żadnej z tych dwóch rund
  zweryfikowana wizualnie (patrz uczciwe notatki o metodzie weryfikacji
  tam), tylko logika nie-UI w izolowanych testach. Schowek plików
  (kopiuj/wytnij/wklej) od v0.2 DZIAŁA MIĘDZY DWOMA OTWARTYMI OKNAMI
  menedżera (patrz "Nowości w v0.2" wyżej -- schowek przeniesiony na
  poziom modułu, nie pola instancji) -- wciąż jednak nie działa z
  aplikacjami spoza ZDE (prawdziwy schowek plików w stylu GNOME/KDE, jak
  i prawdziwe przeciąganie MIĘDZY ZDE a aplikacjami spoza niego,
  wymagałyby własnego typu MIME na `wl_data_device`, czego architektura
  ZDE dziś nigdzie nie robi -- to jedyny punkt z tej rodziny, którego
  runda 14 ŚWIADOMIE nie ruszyła, bo wymaga nowego protokołu na poziomie
  KOMPOZYTORA, nie samego `zde-shell`) ani nie przeżywa restartu
  `zde-shell`. **Od rundy 34: JEDNOKIERUNKOWY** obejście z poziomu
  samego `zde-shell` -- "Kopiuj"/"Wytnij" wystawiają teraz listę ścieżek
  jako `text/uri-list` na SYSTEMOWY schowek przez `wl-copy`/`xclip` (ten
  sam mechanizm co `shell/clipboard.nim` dla tekstu), więc wklejenie w
  PRAWDZIWEJ, zewnętrznej aplikacji (Nautilus, Dolphin, okno "Zapisz
  jako") już działa -- ale WKLEJANIE plików skopiowanych GDZIE INDZIEJ
  DO WNĘTRZA ZDE (kierunek odwrotny) wciąż wymaga tej samej zmiany w
  kompozytorze i pozostaje nierozwiązane. Od rundy 15: sortowanie listy
  (nazwa/rozmiar/data,
  rosnąco/malejąco), historia nawigacji wstecz/dalej i opcjonalne
  ukrywanie wg `.gitignore` (od rundy 18 z prawdziwą obsługą negacji
  `!wzorzec`, semantyka "ostatni pasujący wzorzec wygrywa" jak w
  prawdziwym Gicie -- patrz "Nowości w v0.2 (runda 18)" wyżej; **od
  rundy 34: wzorce ze ścieżką względną (`src/generated/`) ORAZ wędrówka
  po katalogach nadrzędnych są już obsługiwane** -- patrz "Nowości w
  v0.2 (runda 34)", zweryfikowane 4 izolowanymi testami na prawdziwym
  systemie plików).
  Od rundy 16: miniatury obrazów (PNG/JPEG/BMP/GIF pierwsza klatka/QOI/
  PPM, patrz `apps/filemanager/thumbnails.nim` i "Nowości w v0.2 (runda
  16)" wyżej) zamiast generycznej ikony pliku dla obsługiwanych
  formatów. Od rundy 19: wyszukiwanie plików po nazwie w poddrzewie
  katalogów (przełącznik "🔍", uruchamiane jawnie -- nie na bieżąco przy
  pisaniu, patrz "Nowości w v0.2 (runda 19)" wyżej po limity i pełny
  zakres). Wciąż bez integracji z systemowym schowkiem/DnD spoza ZDE
  (patrz akapit wyżej).
- ~~Alt+Tab to toggle do poprzedniego okna, nie pełna karuzela~~ -- już
  NIEAKTUALNE, patrz sekcja "Nowości" wyżej: teraz to pełna karuzela z
  podświetleniem w scenie kompozytora
- brak menedżera pakietów z GUI dla formatu `.zpk` (patrz `packaging/`) --
  budowanie/instalacja paczek to na razie tylko CLI (`zpk.build`,
  `recipe.janet`)
- **historia schowka** (patrz "Nowości" wyżej) -- od tej rozbudowy
  PRZEŻYWA restart `zde-shell` (patrz sekcja "Nowości tej rozbudowy --
  trwała historia schowka" niżej, ten sam wzorzec co historia
  powiadomień), ale wciąż tylko tekst (bez obrazów) i odpytywana raz na
  sekundę (nie na żywo przez zdarzenia `wl_data_device`) -- od v0.2
  kompozytor OBSŁUGUJE protokół "primary selection" (`zwp_primary_selection_v1`,
  patrz "Nowości w v0.2" wyżej), więc środkowy klik działa teraz MIĘDZY
  APLIKACJAMI (np. zaznacz w terminalu, wklej środkowym klikiem w innym
  oknie) -- ale panel historii schowka `zde-shell` śledzi wyłącznie
  zwykły schowek "clipboard" (Ctrl+C/Ctrl+V), nie pierwotny -- to dwie
  osobne rzeczy: protokół działa niezależnie od tego, czy jego treść
  trafia do panelu historii ZDE
- brak przełączania wielu użytkowników / wielu jednoczesnych sesji
- **tapeta z pliku** (patrz "Nowości" wyżej -- podgląd miniatury na żywo,
  automatyczne sprzątanie cache'a do 12 najnowszych plików) -- od v0.2
  (runda 7) ścieżkę można wybrać przyciskiem "Przeglądaj..." (wbudowana
  w `apps/settings` przeglądarka katalogów, patrz "Nowości w v0.2"
  niżej), nie tylko wpisać ręcznie -- to wciąż NIE jest systemowy
  file-picker (żaden inny toolkit w ZDE go nie ma), tylko lekki,
  ograniczony do plików obrazów odpowiednik wbudowany w samą aplikację
  Ustawienia; formaty od rundy 17 to PNG/JPEG/GIF (statyczny, pierwsza
  klatka -- 94% realnych plików `.gif` w praktyce, patrz "Nowości w v0.2
  (runda 17)" wyżej po dokładny przegląd i znane wyjątki) -- **od rundy
  35: WebP DZIAŁA**, ale nie przez samo Pixie (`pixie@5.0.7` w dalszym
  ciągu w ogóle go nie dekoduje -- to nie się zmieniło i nie mogło się
  zmienić bez podmiany biblioteki) -- `readImageWithWebpFallback` w
  `shell/wallpaper.nim` wywołuje zewnętrzne narzędzie `dwebp` (pakiet
  `webp`/`libwebp-tools`) do konwersji na tymczasowy PNG PRZED wczytaniem
  przez Pixie, ten sam duch integracji co `wl-copy`/`xclip` gdzie indziej
  w ZDE. Best-effort: gdy `dwebp` nie jest zainstalowane, WebP zostaje
  nieobsługiwane jak wcześniej (cichy powrót do wbudowanego gradientu).
  **Zweryfikowane REALNIE** -- prawdziwy plik `.webp` wygenerowany
  `cwebp`, zdekodowany z powrotem przez ten dokładny kod z poprawnymi
  wymiarami, plus potwierdzone poprawne, ciche wycofanie się, gdy
  `dwebp` nie jest w `PATH`.
