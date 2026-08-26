### build.janet -- Zenit Desktop Environment
### ---------------------------------------------------------------------
### Orkiestrator budowania całego ZDE. Nim + nimble budują poszczególne
### binarki, ale to Janet spina cały proces w jedną komendę i robi rzeczy,
### których `nimble` sam z siebie nie zrobi: generowanie nagłówków
### protokołów Wayland przez `wayland-scanner`, sprawdzanie zależności
### systemowych przed startem, wybór trybu (X11 / Wayland) i pakowanie
### gotowych binarek do `dist/`.
###
### Użycie:
###   janet build.janet              # buduje wszystko (zde-comp + zde-shell na Wayland)
###   janet build.janet :x11         # zde-shell na X11/GLFW zamiast Wayland (fallback)
###   janet build.janet :comp-only   # tylko kompozytor
###   janet build.janet :shell-only  # tylko shell
###   janet build.janet :clean       # czyści dist/ i cache

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

(defn tool-exists? [name]
  (= 0 (os/execute [ "sh" "-c" (string "command -v " name " >/dev/null 2>&1") ] :p)))

(defn require-tool [name hint]
  (unless (tool-exists? name)
    (die (string "brak narzędzia `" name "` w PATH. " hint))))

# ---------------------------------------------------------------------
# Sprawdzenie zależności systemowych
# ---------------------------------------------------------------------

(defn check-system-deps []
  (log "sprawdzam zależności systemowe...")
  (require-tool "nim" "zainstaluj pakiet `nim` (>= 1.4, zalecane >= 2.0).")
  (require-tool "nimble" "zainstaluj pakiet `nimble` (zwykle razem z nim).")
  (require-tool "gcc" "zainstaluj `build-essential`/`gcc`.")
  (require-tool "wayland-scanner" "zainstaluj `libwayland-bin`.")
  (require-tool "pkg-config" "zainstaluj `pkg-config`.")
  (unless (os/stat wayland-protocols-dir)
    (die (string "brak katalogu " wayland-protocols-dir " -- zainstaluj pakiet `wayland-protocols`.")))
  (log "OK: wszystkie wymagane narzędzia są dostępne."))

(defn require-pkgconfig [pkg apt-hint]
  (unless (= 0 (os/execute ["pkg-config" "--exists" pkg] :p))
    (die (string "pkg-config nie widzi paczki `" pkg "` -- `pkg-config --cflags " pkg
                 "` nic nie zwraca. Zwykle znaczy to, że brakuje pakietu -dev: "
                 apt-hint
                 ". Jeśli jest zainstalowany w nietypowym miejscu, sprawdź zmienną"
                 " PKG_CONFIG_PATH (`pkg-config --variable pc_path pkg-config`"
                 " pokaże, gdzie pkg-config aktualnie szuka).")))
  (log "OK: pkg-config widzi `" pkg "`."))

(defn check-comp-deps []
  (log "sprawdzam zależności zde-comp (wlroots/wayland/xkbcommon)...")
  (require-pkgconfig "wlroots" "sudo apt install libwlroots-dev")
  (require-pkgconfig "wayland-server" "sudo apt install libwayland-dev")
  (require-pkgconfig "xkbcommon" "sudo apt install libxkbcommon-dev"))

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

(defn generate-client-protocols []
  (log "generuję nagłówki protokołów Wayland dla zde-shell (GLFW/staticglfw)...")
  # staticglfw dołącza je przez #include "wayland-xxx-client-protocol.h"
  # względem własnego katalogu źródłowego -- kopiujemy je tam bezpośrednio,
  # zamiast walczyć z dodatkowym -I (patrz też komentarz w README o tym
  # sandboxowym obejściu).
  (def nimble-dir (or (os/getenv "NIMBLE_DIR") (string (os/getenv "HOME") "/.nimble")))
  (def pkgs-dir (string nimble-dir "/pkgs"))
  (var target nil)
  (each entry (os/dir pkgs-dir)
    (when (string/has-prefix? "staticglfw-" entry)
      (set target (string pkgs-dir "/" entry "/src/staticglfw"))))
  (unless target
    (die "nie znaleziono zainstalowanej paczki `staticglfw` w ~/.nimble -- uruchom `nimble install staticglfw` przed budowaniem."))
  (each [name xml] client-protocols
    (generate-protocol target name xml "client"))
  (log "protokoły klienckie skopiowane do: " target))

# ---------------------------------------------------------------------
# Budowanie poszczególnych binarek
# ---------------------------------------------------------------------

(defn nimble-pkg-paths []
  "Zwraca listę --path: dla wszystkich zainstalowanych paczek nimble --
   patrz notatka w README o tym, dlaczego nie polegamy tu na samym
   `nimble build` (rozjazd wersji pixie/zippy/bitstreams w niektórych
   środowiskach z ograniczonym dostępem do sieci)."
  (def nimble-dir (or (os/getenv "NIMBLE_DIR") (string (os/getenv "HOME") "/.nimble")))
  (def pkgs-dir (string nimble-dir "/pkgs"))
  (def paths @[])
  (when (os/stat pkgs-dir)
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
  (when (= backend :wayland)
    (generate-client-protocols))
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
