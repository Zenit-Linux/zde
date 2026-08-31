# ZDE -- Zenit Desktop Environment

Środowisko graficzne dla Zenit Linux, napisane w Nimie (+ Fidget do UI).
Stack:

- **`zde-comp`** -- kompozytor Wayland + XWayland (Nim FFI → libwlroots >= 0.18,
  API oparte o `wlr_output_state`; zweryfikowane kompilacją wobec
  prawdziwych nagłówków 0.18 i 0.20).
  To jest *serwer* -- odpowiednik Xorg/Sway/Muttera. Uruchamia się jako
  pierwszy, z TTY.
- **`zde-shell`** -- pasek zadań / launcher / chrome okien (Fidget). To
  *klient* Wayland, łączy się z socketem, który wystawia `zde-comp`.
- `apps/terminal`, `apps/filemanager`, `apps/clock`, `apps/texteditor`,
  `apps/calculator`, `apps/sysmonitor` -- wbudowane aplikacje shellu.
- `comp/` -- logika okien używana przez `zde-shell`, rozbita na kilka plików
  (nie mylić z `wlcomp/` -- to osobna, dużo niższopoziomowa warstwa: prawdziwy kompozytor).

### Struktura plików

```
wlcomp/            -- zde-comp (kompozytor)
  types.nim           wspólne typy: Server/Output/Toplevel/Keyboard
  output.nim          wyjścia (monitory): init, klatki, odłączanie
  toplevel.nim        okna xdg-shell: focus, move/resize, hit-testing
  input.nim           klawiatura + kursor/mysz
  main.nim            tylko inicjalizacja i spięcie sygnałów
  wlroots.nim         bindingi FFI do libwlroots/wayland-server
  shim.c/.h           C glue dla funkcji `static inline` z wayland-server

shell/              -- zde-shell (pasek/launcher/chrome okien)
  state.nim           stan globalny (compositor, zegar) + stałe kolorów
  waylandlink.nim      linkowanie protokołów Wayland przy -d:wayland (patrz niżej)
  wallpaper.nim        tło pulpitu
  chrome.nim           pasek tytułu / obramowanie / przyciski okna
  taskbar.nim          pasek zadań + launcher
  launcher_apps.nim    uruchamianie poszczególnych aplikacji z launchera
  shell.nim            główna pętla rysowania + start

comp/                -- silnik okien używany przez zde-shell (focus/z-order/drag)
  types.nim            wspólne typy: ZdeWindow, Compositor, DragState
  window.nim           cykl życia okien: tworzenie/zamykanie, focus, z-order
  drag.nim             przeciąganie/zmiana rozmiaru myszą
  comp.nim             fasada re-eksportująca powyższe (import bez zmian)
apps/                -- aplikacje uruchamiane z launchera
  terminal/            terminal (bash przez potoki, bez pty)
  filemanager/         przeglądarka plików
  clock/               zegar analogowy + cyfrowy + data
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

## Ograniczenia obecnej wersji (v1)

Patrz też komentarze na górze `wlcomp/main.nim` -- to jest świadomie
zawężony zakres, nie przeoczenie:

- brak protokołu **wlr-layer-shell** -- `zde-shell` pojawia się jako zwykłe
  okno xdg-toplevel, a nie zadokowany pasek zajmujący stały pasek ekranu
- brak **popupów** xdg-shell (menu kontekstowe, tooltips, comboboxy aplikacji)
- brak **schowka** (data-device/selection) i **drag & drop**
- pojedynczy seat, układ klawiatury na sztywno `us`
- hit-testing kursora działa (`wlr_scene_node_at`), ale bez specjalnej
  obsługi zagnieżdżonych subsurface'ów
- terminal (`apps/terminal`) nie ma prawdziwego PTY -- działa przez zwykłe
  potoki do `bash`, więc programy pełnoekranowe (`vim`, `top`, `less`) nie
  będą działać poprawnie
- edytor tekstu (`apps/texteditor`) nie ma podświetlania składni, wielu
  zakładek ani wykrywania zmian pliku na dysku w tle
- zegar (`apps/clock`) nie ma alarmów/timerów -- to czysto wizualny widget
- brak menedżera okien wielomonitorowego UI (dodawanie/przestawianie
  wyjść działa "pod spodem" w `zde-comp`, ale nie ma do tego panelu
  ustawień)
- brak dedykowanej aplikacji "Ustawienia" (motyw, tapeta, skróty klawiszowe)
