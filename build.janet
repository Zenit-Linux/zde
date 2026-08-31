(def root (os/cwd))
(def dist (string root "/dist"))
(def wlcomp-dir (string root "/wlcomp"))
(def shell-dir (string root "/shell"))

(def wayland-protocols-dir "/usr/share/wayland-protocols")

# ---------------------------------------------------------------------
# Małe helpery
# ---------------------------------------------------------------------

(defn log [& args]
  (print "\e[36m[build.janet]\e[0m " ;args))

(defn die [msg]
  (eprint "\e[31m[build.janet] BŁĄD:\e[0m " msg)
  (os/exit 1))

(defn run
  "Uruchamia komendę (tablica argumentów), pokazuje ją, przerywa build przy błędzie."
  [args &opt cwd]
  (log "$ " (string/join args " "))
  (def opts (if cwd @{:cwd cwd} @{}))
  (def ret (os/execute args :p opts))
  (unless (zero? ret)
    (die (string "polecenie zakończone kodem " ret ": " (string/join args " ")))))

(defn run-soft
  "Jak `run`, ale nie przerywa builda przy błędzie -- tylko ostrzega.
   Do rzeczy typu `apt-get update`, gdzie częściowa porażka (jedno zepsute
   repo spoza naszego projektu) jest normalna i nie przeszkadza w dalszej
   instalacji z pozostałych, poprawnie pobranych repozytoriów."
  [args &opt cwd]
  (log "$ " (string/join args " "))
  (def opts (if cwd @{:cwd cwd} @{}))
  (def ret (os/execute args :p opts))
  (unless (zero? ret)
    (log "  (ostrzeżenie: kod wyjścia " ret " -- kontynuuję mimo to)"))
  (zero? ret))

(defn tool-exists? [name]
  (= 0 (os/execute [ "sh" "-c" (string "command -v " name " >/dev/null 2>&1") ] :p)))

(defn require-tool [name hint]
  (unless (tool-exists? name)
    (die (string "brak narzędzia `" name "` w PATH. " hint))))

# ---------------------------------------------------------------------
# Wykrywanie dystrybucji i automatyczna instalacja brakujących pakietów
# ---------------------------------------------------------------------
#
# To, co wcześniej trzeba było robić ręcznie (jak `apt-cache search
# libwlroots` + wybranie właściwej wersjonowanej nazwy pakietu, `apt
# install`, `ln -s`) -- build.janet teraz próbuje zrobić samo, pytając o
# zgodę przed każdą operacją wymagającą uprawnień administratora.
# Obsługiwane menedżery: apt (Debian/Ubuntu), dnf (Fedora/RHEL), pacman
# (Arch), zypper (openSUSE), apk (Alpine). Ustaw ZDE_ASSUME_YES=1 w
# środowisku, żeby pominąć pytania (np. w CI).

(def assume-yes (= "1" (os/getenv "ZDE_ASSUME_YES")))

(defn am-root? []
  (= 0 (os/execute ["sh" "-c" "[ \"$(id -u)\" = \"0\" ]"] :p)))

(defn maybe-sudo [args]
  (if (or (am-root?) (not (tool-exists? "sudo")))
    args
    (array/concat @["sudo"] args)))

(defn capture-shell [cmd]
  "Uruchamia `cmd` przez `sh -c`, zwraca jego stdout (bez końcowej nowej
   linii) jako string, albo pusty string przy błędzie/braku wyjścia.
   Używane tylko do odpytywania (apt-cache search itp.) -- nigdy do niczego
   wymagającego uprawnień."
  (def tmp-file (string "/tmp/.zde-build-janet-capture-" (os/getpid) ".txt"))
  (os/execute ["sh" "-c" (string cmd " > " tmp-file " 2>/dev/null")] :p)
  (def out (try (string/trim (slurp tmp-file)) ([_] "")))
  (try (os/rm tmp-file) ([_] nil))
  out)

(defn dedupe [arr]
  (def seen @{})
  (def out @[])
  (each x arr
    (unless (get seen x)
      (put seen x true)
      (array/push out x)))
  out)

(defn detect-pkg-manager []
  (cond
    (tool-exists? "apt-get") :apt
    (tool-exists? "dnf") :dnf
    (tool-exists? "pacman") :pacman
    (tool-exists? "zypper") :zypper
    (tool-exists? "apk") :apk
    (tool-exists? "xbps-install") :xbps
    nil))

(defn distro-name []
  (def f "/etc/os-release")
  (def n
    (if (os/stat f)
      (capture-shell (string "grep '^PRETTY_NAME=' " f " | head -1 | cut -d= -f2 | tr -d '\"'"))
      ""))
  (if (empty? n) "nieznana dystrybucja" n))

(defn confirm [question]
  (if assume-yes
    true
    (do
      (prin (string question " [Y/n] "))
      (flush)
      (def ans (string/ascii-lower (string/trim (or (getline) ""))))
      (or (= ans "") (= ans "y") (= ans "yes") (= ans "t") (= ans "tak")))))

(defn pkgconfig-exists-any? [names]
  (var found false)
  (each n names
    (when (and (not found) (= 0 (os/execute ["pkg-config" "--exists" n] :p)))
      (set found true)))
  found)

(defn pkg-install-cmd [mgr pkgs]
  (case mgr
    :apt (array/concat @["apt-get" "install" "-y"] pkgs)
    :dnf (array/concat @["dnf" "install" "-y"] pkgs)
    :pacman (array/concat @["pacman" "-S" "--noconfirm" "--needed"] pkgs)
    :zypper (array/concat @["zypper" "--non-interactive" "install"] pkgs)
    :apk (array/concat @["apk" "add"] pkgs)
    :xbps (array/concat @["xbps-install" "-y"] pkgs)
    (die (string "Nieobsługiwany menedżer pakietów: " mgr))))

(var apt-refreshed false)

(defn install-package-noconfirm [mgr pkg]
  "Instaluje JEDEN pakiet bez dodatkowego pytania (zgoda zbierana raz, dla
   całej listy kandydatów, w ensure-system-dep). Zwraca true, jeśli sam
   menedżer pakietów zgłosił sukces (to jeszcze nie znaczy, że to był
   właściwy pakiet -- to sprawdza dopiero check-fn wywołujący tę funkcję)."
  (when (and (= mgr :apt) (not apt-refreshed))
    (log "odświeżam listę pakietów apt (raz, na początku)...")
    (run-soft (maybe-sudo @["apt-get" "update"]))
    (set apt-refreshed true))
  (def cmd (maybe-sudo (pkg-install-cmd mgr [pkg])))
  (log "$ " (string/join cmd " "))
  (= 0 (os/execute cmd :p)))

(defn pkgmgr-search-versioned [mgr pattern]
  "Odpowiednik ręcznego `apt-cache search X` + wybrania właściwej
   wersjonowanej nazwy (jak `libwlroots-0.20-dev`) -- ale zaimplementowane
   dla kilku menedżerów pakietów, nie tylko apt. `pattern` to regex (grep
   -E) dopasowywany do nazwy pakietu; wynik sortowany wersyjnie (sort -V),
   więc najnowsza wersja ląduje na końcu."
  (def out
    (case mgr
      :apt (capture-shell (string "apt-cache search '' 2>/dev/null | awk '{print $1}' | grep -E '" pattern "' | sort -V"))
      :dnf (capture-shell (string "dnf -q list --available 2>/dev/null | awk '{print $1}' | sed 's/\\..*//' | grep -E '" pattern "' | sort -Vu"))
      :pacman (capture-shell (string "pacman -Ssq 2>/dev/null | grep -E '" pattern "' | sort -V"))
      :zypper (capture-shell (string "zypper -q packages 2>/dev/null | awk -F'|' '{gsub(/ /,\"\",$3); print $3}' | grep -E '" pattern "' | sort -Vu"))
      :apk (capture-shell (string "apk search 2>/dev/null | sed 's/-[0-9].*//' | grep -E '" pattern "' | sort -Vu"))
      ""))
  (if (empty? out) @[] (filter (fn [s] (not (empty? s))) (string/split "\n" out))))

(defn resolve-candidates [mgr spec]
  "spec to struct {:apt [...] :dnf [...] ...}, gdzie elementy list mogą
   być zwykłymi nazwami pakietów (string) albo {:search \"regex\"} do
   dynamicznego wyszukania wersjonowanej nazwy. Zwraca płaską,
   posortowaną-od-najlepszej listę konkretnych nazw pakietów do
   wypróbowania po kolei."
  (def raw (get spec mgr @[]))
  (def out @[])
  (each cand raw
    (if (struct? cand)
      (each n (reverse (pkgmgr-search-versioned mgr (get cand :search)))
        (array/push out n))
      (array/push out cand)))
  (dedupe out))

(defn ensure-system-dep [check-fn spec what manual-hint]
  "Rdzeń auto-instalacji: jeśli check-fn zwraca true, nic nie robi. W
   przeciwnym razie wykrywa menedżer pakietów, wyszukuje kandydatów
   (spec), pyta raz o zgodę na CAŁĄ listę, po czym próbuje po kolei
   zainstalować i za każdym razem od nowa sprawdza check-fn -- pierwsza
   udana kombinacja kończy pętlę."
  (if (check-fn)
    (log "OK: " what)
    (do
      (log what " nie jest dostępne -- próbuję dobrać i zainstalować pakiet automatycznie...")
      (def mgr (detect-pkg-manager))
      (unless mgr
        (die (string "Brak " what " i nie wykryto obsługiwanego menedżera pakietów "
                     "(apt/dnf/pacman/zypper/apk) na (" (distro-name) "). " manual-hint)))
      (def candidates (resolve-candidates mgr spec))
      (when (empty? candidates)
        (die (string "Nie wiem, jak automatycznie zainstalować " what " na "
                     "(" (distro-name) ", menedżer: " mgr "). " manual-hint)))
      (unless (confirm (string "Zainstalować " what " na (" (distro-name) ")? Spróbuję kolejno: "
                               (string/join candidates ", ")))
        (die (string "Przerwano przez użytkownika -- zainstaluj ręcznie: " manual-hint)))
      (var installed false)
      (each name candidates
        (unless installed
          (when (and (install-package-noconfirm mgr name) (check-fn))
            (set installed true))))
      (unless installed
        (die (string "Nie udało się automatycznie zainstalować " what
                     " (próbowano: " (string/join candidates ", ") "). " manual-hint)))
      (log "OK: " what " zainstalowane pomyślnie."))))

(defn ensure-tool [name spec manual-hint]
  (ensure-system-dep (fn [] (tool-exists? name)) spec name manual-hint))

(defn ensure-pkgconfig [names spec what manual-hint]
  (ensure-system-dep (fn [] (pkgconfig-exists-any? names)) spec what manual-hint))

# --- Konkretne zależności: nazwy pakietów per dystrybucja ---------------

(def dep-nim
  {:apt ["nim"] :dnf ["nim"] :pacman ["nim"] :zypper ["nim"] :apk ["nim"]})
(def dep-nimble
  {:apt ["nimble"] :dnf ["nimble"] :zypper ["nimble"] :apk ["nimble"]})
(def dep-gcc
  {:apt ["gcc" "build-essential"] :dnf ["gcc"] :pacman ["gcc" "base-devel"]
   :zypper ["gcc"] :apk ["gcc" "build-base"]})
(def dep-pkgconfig
  {:apt ["pkg-config"] :dnf ["pkgconf-pkg-config" "pkgconf"] :pacman ["pkgconf"]
   :zypper ["pkg-config"] :apk ["pkgconf"]})
(def dep-wayland-scanner
  {:apt ["libwayland-bin"] :dnf ["wayland-devel"] :pacman ["wayland"]
   :zypper ["wayland-devel"] :apk ["wayland-dev"]})
(def dep-wayland-protocols
  {:apt ["wayland-protocols"] :dnf ["wayland-protocols-devel"] :pacman ["wayland-protocols"]
   :zypper ["wayland-protocols-devel"] :apk ["wayland-protocols"]})
(def dep-wayland-dev
  {:apt ["libwayland-dev"] :dnf ["wayland-devel"] :pacman ["wayland"]
   :zypper ["wayland-devel"] :apk ["wayland-dev"]})
(def dep-xkbcommon-dev
  {:apt ["libxkbcommon-dev"] :dnf ["libxkbcommon-devel"] :pacman ["libxkbcommon"]
   :zypper ["libxkbcommon-devel"] :apk ["libxkbcommon-dev"]})
## wlroots -- to właśnie ten pakiet miał wersjonowaną nazwę u użytkownika
## (`libwlroots-0.20-dev`), której nie dało się odgadnąć na sztywno.
## Dlatego {:search ...} jako PIERWSZY kandydat (nowsze Ubuntu/Debian nie
## mają już samego "libwlroots-dev"), z prostą nazwą jako fallback.
(def wlroots-pkgconfig-names
  ["wlroots" "wlroots-0.20" "wlroots-0.19" "wlroots-0.18" "wlroots-0.17"])
(def dep-wlroots-dev
  {:apt [{:search "^libwlroots-?[0-9.]*-?dev$"} "libwlroots-dev"]
   :dnf ["wlroots-devel"]
   :pacman [{:search "^wlroots[0-9.]*$"} "wlroots"]
   :zypper ["wlroots-devel"]
   :apk ["wlroots-dev"]})
(def dep-x11-glfw-libs
  {:apt ["libx11-dev" "libxrandr-dev" "libxinerama-dev" "libxcursor-dev" "libxi-dev"
         "libxxf86vm-dev" "libglfw3-dev" "libgl1-mesa-dev"]
   :dnf ["libX11-devel" "libXrandr-devel" "libXinerama-devel" "libXcursor-devel"
         "libXi-devel" "libXxf86vm-devel" "glfw-devel" "mesa-libGL-devel"]
   :pacman ["libx11" "libxrandr" "libxinerama" "libxcursor" "libxi" "libxxf86vm"
            "glfw" "mesa"]
   :zypper ["libX11-devel" "libXrandr-devel" "libXinerama-devel" "libXcursor-devel"
            "libXi-devel" "libXxf86vm-devel" "glfw-devel" "Mesa-libGL-devel"]
   :apk ["libx11-dev" "libxrandr-dev" "libxinerama-dev" "libxcursor-dev" "libxi-dev"
         "glfw-dev" "mesa-dev"]})

# ---------------------------------------------------------------------
# Sprawdzenie zależności systemowych
# ---------------------------------------------------------------------

(defn check-system-deps []
  (log "sprawdzam zależności systemowe (dystrybucja: " (distro-name) ")...")
  (ensure-tool "nim" dep-nim
    "zainstaluj `nim` (>= 1.4, zalecane >= 2.0) -- w ostateczności ręcznie z https://nim-lang.org/install.html.")
  (ensure-tool "nimble" dep-nimble
    "zwykle instaluje się razem z nim -- na Arch/inne bez osobnej paczki jest w pakiecie `nim`.")
  (ensure-tool "gcc" dep-gcc
    "zainstaluj kompilator C ręcznie (gcc albo clang + odpowiedni alias).")
  (ensure-tool "wayland-scanner" dep-wayland-scanner
    "zainstaluj narzędzia deweloperskie Wayland ręcznie.")
  (ensure-tool "pkg-config" dep-pkgconfig
    "zainstaluj pkg-config/pkgconf ręcznie.")
  (ensure-system-dep (fn [] (not (nil? (os/stat wayland-protocols-dir))))
    dep-wayland-protocols "wayland-protocols (pliki .xml protokołów)"
    (string "zainstaluj pakiet z plikami .xml protokołów Wayland ręcznie i upewnij się, "
            "że trafiają do " wayland-protocols-dir "."))
  (log "OK: wszystkie wymagane narzędzia są dostępne."))

(defn check-comp-deps []
  (log "sprawdzam zależności zde-comp (wlroots/wayland/xkbcommon)...")
  (ensure-pkgconfig wlroots-pkgconfig-names dep-wlroots-dev "wlroots (>= 0.18)"
    (string "Zainstaluj nagłówki deweloperskie wlroots >= 0.18 ręcznie -- sprawdź dokładną "
            "nazwę pakietu poleceniem `apt-cache search wlroots` (albo odpowiednikiem na "
            "Twojej dystrybucji), np. `libwlroots-0.20-dev`."))
  (ensure-pkgconfig ["wayland-server"] dep-wayland-dev "wayland-server"
    "zainstaluj nagłówki deweloperskie wayland-server ręcznie.")
  (ensure-pkgconfig ["xkbcommon"] dep-xkbcommon-dev "xkbcommon"
    "zainstaluj nagłówki deweloperskie libxkbcommon ręcznie."))

(defn linker-lib-exists? [libName]
  "Sprawdza, czy `-l<libName>` faktycznie rozwiąże się konsolidatorowi --
   w PRZECIWIEŃSTWIE do `ldconfig -p` (które widzi tylko wersjonowane
   biblioteki runtime .so.N i dawało fałszywy pozytyw: libXxf86vm.so.1
   był obecny, ale brakowało niewersjonowanego symlinku `libXxf86vm.so`
   z pakietu -dev, którego właśnie potrzebuje `-lXxf86vm` przy linkowaniu).
   `gcc -print-file-name` pyta dokładnie o to, czego pyta się linker."
  (def out (capture-shell (string "gcc -print-file-name=lib" libName ".so")))
  (and (not (empty? out)) (not= out (string "lib" libName ".so"))))

(defn check-shell-common-deps []
  "Biblioteki X11/GLFW/GL potrzebne PRZY LINKOWANIU zde-shell niezależnie
   od wybranego backendu (`staticglfw` linkuje je bezwarunkowo, także w
   trybie -d:wayland -- stąd `cannot find -lXxf86vm` nawet przy budowaniu
   wariantu Wayland, jeśli tych bibliotek zabraknie). Sprawdzane każda
   osobno, dokładnie tak jak zapytałby o nią linker (patrz
   linker-lib-exists?) -- nie jednym pkg-config-owym 'x11' jako proxy."
  (log "sprawdzam biblioteki X11/GL wymagane przez staticglfw (niezależnie od backendu)...")
  (def needed ["X11" "Xrandr" "Xinerama" "Xcursor" "Xi" "Xxf86vm" "GL"])
  (ensure-system-dep
    (fn [] (all linker-lib-exists? needed))
    dep-x11-glfw-libs "biblioteki X11/GLFW/GL"
    "zainstaluj nagłówki deweloperskie X11 (w tym legacy Xxf86vm) + GLFW3 + OpenGL ręcznie.")
  (log "OK: biblioteki X11/GL."))

# ---------------------------------------------------------------------
# Generowanie nagłówków protokołów Wayland (dla zde-comp i zde-shell)
# ---------------------------------------------------------------------

(def server-protocols
  # [nazwa-wyjściowa ścieżka-do-xml]
  [["xdg-shell" (string wayland-protocols-dir "/stable/xdg-shell/xdg-shell.xml")]])

(def client-protocols
  [["xdg-shell" (string wayland-protocols-dir "/stable/xdg-shell/xdg-shell.xml")]
   ["xdg-decoration" (string wayland-protocols-dir "/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml")]
   ["viewporter" (string wayland-protocols-dir "/stable/viewporter/viewporter.xml")]
   ["relative-pointer-unstable-v1" (string wayland-protocols-dir "/unstable/relative-pointer/relative-pointer-unstable-v1.xml")]
   ["pointer-constraints-unstable-v1" (string wayland-protocols-dir "/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml")]
   ["idle-inhibit-unstable-v1" (string wayland-protocols-dir "/unstable/idle-inhibit/idle-inhibit-unstable-v1.xml")]])

(defn generate-protocol [out-dir name xml kind]
  # kind: "server" albo "client"
  (unless (os/stat xml)
    (die (string "brak pliku protokołu: " xml
                 " -- zainstaluj/zaktualizuj pakiet wayland-protocols.")))
  (def header (string out-dir "/wayland-" name "-" kind "-protocol.h"))
  (def code (string out-dir "/wayland-" name "-" kind "-protocol.c"))
  (run ["wayland-scanner" (string kind "-header") xml header])
  (run ["wayland-scanner" "private-code" xml code]))

(defn generate-server-protocols []
  (log "generuję nagłówki protokołów Wayland dla zde-comp...")
  (def out (string wlcomp-dir "/protocol"))
  (os/mkdir out)
  # Konwencja nazw zgodna z tym, czego oczekują nagłówki wlroots (zwykłe
  # #include "xdg-shell-protocol.h", bez przedrostka/przyrostka) --
  # inna niż przy protokołach klienckich dla GLFW poniżej.
  (each [name xml] server-protocols
    (unless (os/stat xml)
      (die (string "brak pliku protokołu: " xml " -- zainstaluj/zaktualizuj wayland-protocols.")))
    (def header (string out "/" name "-protocol.h"))
    (def code (string out "/" name "-protocol.c"))
    (run ["wayland-scanner" "server-header" xml header])
    (run ["wayland-scanner" "private-code" xml code])))

(defn nimble-pkgs-dirs []
  "Zwraca WSZYSTKIE istniejące katalogi z paczkami nimble -- nowoczesny
   nimble (>= 2.x) ma tylko `pkgs2`, starszy tylko `pkgs`. Wcześniej ten
   kod zakładał na sztywno `pkgs`, co wywalało się z `cannot open
   directory` na maszynach, które mają wyłącznie `pkgs2`."
  (def nimble-dir (or (os/getenv "NIMBLE_DIR") (string (os/getenv "HOME") "/.nimble")))
  (def candidates [(string nimble-dir "/pkgs2") (string nimble-dir "/pkgs")])
  (filter (fn [d] (os/stat d)) candidates))

(defn nimble-pkg-installed? [prefix]
  "Sprawdza, czy w ~/.nimble/pkgs(2) jest jakikolwiek katalog zaczynający
   się od `prefix-` (np. \"fidget-\") -- używane, żeby wiedzieć, czy trzeba
   w ogóle odpalać `nimble install`."
  (var found false)
  (each pkgs-dir (nimble-pkgs-dirs)
    (each entry (os/dir pkgs-dir)
      (when (string/has-prefix? (string prefix "-") entry)
        (set found true))))
  found)

## Paczki nimble potrzebne do zbudowania zde-shell (Fidget + jego
## zależności). Ta sama lista co w `requires` w zde.nimble -- trzymana też
## tutaj, żeby `ensure-nimble-deps` mogło sprawdzić obecność KAŻDEJ z
## osobna zamiast tylko ślepo odpalać `nimble install` za każdym razem.
(def required-nimble-pkgs
  ["fidget" "staticglfw" "opengl" "vmath" "chroma" "bumpy" "flatty"
   "zippy" "cligen" "supersnappy" "bitstreams" "html5_canvas" "pixie"
   "typography" "crunchy"])

(defn ensure-nimble-deps []
  "Odpowiednik ręcznego `nimble install` -- sprawdza, czy wszystkie paczki
   nimble wymagane przez zde-shell (Fidget i jego drzewo zależności) już
   są zainstalowane; jeśli którejś brakuje, doinstalowuje.
   CELOWO instalujemy PO NAZWIE (`nimble install -y fidget`), nie gołe
   `nimble install -y` bez argumentu -- to drugie działa w trybie
   \"zainstaluj PROJEKT z bieżącego katalogu\", co przy okazji próbuje
   zbudować i nasz własny `bin` (`shell/shell`) zanim jeszcze sprawdziliśmy
   i doinstalowaliśmy biblioteki X11/GLFW -- dawało to mylący,
   przedwczesny błąd `cannot find -lXxf86vm` w środku instalacji paczek,
   mimo że finalny, właściwy build i tak przechodził poprawnie później.
   Instalacja po nazwie ściąga te same zależności (nimble i tak rozwiąże
   całe drzewo transitive), ale nie dotyka naszego `bin`."
  (def missing (filter (fn [p] (not (nimble-pkg-installed? p))) required-nimble-pkgs))
  (if (empty? missing)
    (log "OK: wszystkie paczki nimble (fidget i zależności) już zainstalowane.")
    (do
      (log "brakuje paczek nimble: " (string/join missing ", ") " -- doinstalowuję...")
      (each pkg missing
        (unless (nimble-pkg-installed? pkg)  # mogła już dojść jako zależność wcześniejszej
          (run ["nimble" "install" "-y" pkg])))
      (def still-missing (filter (fn [p] (not (nimble-pkg-installed? p))) required-nimble-pkgs))
      (unless (empty? still-missing)
        (die (string "Zainstalowano co się dało, ale nadal brakuje: "
                     (string/join still-missing ", ") ". Sprawdź komunikaty nimble powyżej "
                     "-- może być potrzebne ręczne `nimble install <nazwa>` dla którejś z nich.")))
      (log "OK: paczki nimble zainstalowane."))))

(defn generate-client-protocols []
  (log "generuję nagłówki protokołów Wayland dla zde-shell (GLFW/staticglfw)...")
  # CELOWO generujemy do WŁASNEGO katalogu projektu (shell/wlprotocol/),
  # nie do katalogu zainstalowanej paczki `staticglfw` w ~/.nimble --
  # patrz duży komentarz w shell/waylandlink.nim po wyjaśnienie dlaczego
  # (wcześniejsza wersja patchowała staticglfw w cache'u nimble, co nie
  # przechodziło do repo i psuło się przy każdym świeżym `nimble install`
  # na innej maszynie -- `undefined reference to wl_proxy_*` mimo że
  # nagłówki były poprawnie wygenerowane).
  (def target (string shell-dir "/wlprotocol"))
  (unless (os/stat target)
    (os/mkdir target))
  (each [name xml] client-protocols
    (generate-protocol target name xml "client"))
  (log "protokoły klienckie wygenerowane do: " target))

# ---------------------------------------------------------------------
# Budowanie poszczególnych binarek
# ---------------------------------------------------------------------

(defn nimble-pkg-paths []
  "Zwraca listę --path: dla wszystkich zainstalowanych paczek nimble --
   patrz notatka w README o tym, dlaczego nie polegamy tu na samym
   `nimble build` (rozjazd wersji pixie/zippy/bitstreams w niektórych
   środowiskach z ograniczonym dostępem do sieci)."
  (def paths @[])
  (each pkgs-dir (nimble-pkgs-dirs)
    (each entry (os/dir pkgs-dir)
      (def full (string pkgs-dir "/" entry))
      (def with-src (string full "/src"))
      (array/push paths (string "--path:" (if (os/stat with-src) with-src full)))))
  paths)

(defn build-comp []
  (log "buduję zde-comp (kompozytor Wayland + XWayland)...")
  (check-comp-deps)
  (generate-server-protocols)
  (run ["nim" "c" "--hints:off" "-d:release"
        (string "--path:" wlcomp-dir)
        (string "-o:" dist "/zde-comp")
        (string wlcomp-dir "/main.nim")])
  (log "-> " dist "/zde-comp"))

(defn build-shell [backend]
  # backend: :wayland albo :x11
  (log "buduję zde-shell (backend: " backend ")...")
  (ensure-nimble-deps)
  # X11/GLFW linkuje się bezwarunkowo (patrz komentarz w check-shell-common-deps)
  # -- sprawdzamy to NIEZALEŻNIE od wybranego backendu, nie tylko dla :x11.
  (check-shell-common-deps)
  (if (= backend :wayland)
    (do
      (ensure-pkgconfig ["wayland-client"] dep-wayland-dev "wayland-client"
        "zainstaluj nagłówki deweloperskie klienta Wayland ręcznie.")
      (generate-client-protocols))
    (do))
  (def flags @["nim" "c" "--hints:off" "-d:release" "-d:pixieNoSimd"])
  (when (= backend :wayland) (array/push flags "-d:wayland"))
  (array/concat flags (nimble-pkg-paths))
  (array/push flags (string "-o:" dist "/zde-shell"))
  (array/push flags (string shell-dir "/shell.nim"))
  (run flags))

# ---------------------------------------------------------------------
# main
# ---------------------------------------------------------------------

(defn ensure-dist []
  (unless (os/stat dist) (os/mkdir dist)))

(defn clean []
  (log "czyszczę " dist " ...")
  (when (os/stat dist)
    (run ["rm" "-rf" dist]))
  (log "gotowe."))

(defn main [&]
  (def mode (get (dyn :args) 1))
  (cond
    (= mode ":clean") (clean)

    (= mode ":comp-only")
    (do (check-system-deps) (ensure-dist) (build-comp))

    (= mode ":shell-only")
    (do (check-system-deps) (ensure-dist) (build-shell :wayland))

    (= mode ":x11")
    (do (check-system-deps) (ensure-dist) (build-shell :x11))

    true
    (do
      (check-system-deps)
      (ensure-dist)
      (build-comp)
      (build-shell :wayland)
      (log "")
      (log "Build zakończony. Pliki w " dist "/:")
      (log "  zde-comp   -- uruchamiaj z TTY (patrz README, sekcja 'Uruchomienie')")
      (log "  zde-shell  -- klient Wayland; uruchom PO zde-comp, z ustawionym WAYLAND_DISPLAY"))))
