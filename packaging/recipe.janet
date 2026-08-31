(def stage (os/getenv "ZPM_PACKAGE_STAGE_DIR"))

(defn fail [msg]
  (eprint "recipe.janet: " msg)
  (os/exit 1))

(defn run [cmd]
  # `os/shell` zwraca kod wyjścia polecenia (jak C-owe system()) --
  # zero == sukces.
  (def code (os/shell cmd))
  (unless (zero? code)
    (fail (string "'" cmd "' zakończone kodem " code))))

(defn ensure-dir [path]
  # `os/mkdir` w Janet nie jest rekurencyjne i zgłasza błąd, jeśli katalog
  # już istnieje -- oba przypadki są tu nieszkodliwe (świeży katalog
  # roboczy z ZPM_PACKAGE_STAGE_DIR może już mieć część drzewa "usr/...",
  # np. z poprzedniego, przerwanego builda), więc łykamy błąd i jedziemy
  # dalej.
  (try (os/mkdir path) ([_] nil)))

# packaging/recipe.janet leży w <repo>/packaging -- korzeń repo to
# katalog wyżej, niezależnie od tego, skąd faktycznie wywołano `zpk
# build` (zpk zawsze ustawia cwd recipe na katalog z zpk.build).
(def repo-root (string (os/cwd) "/.."))
(def dist (string repo-root "/dist"))

(def prebuilt-dist (os/getenv "ZPK_PACKAGING_PREBUILT_DIST"))

(def bin-dist-dir
  (if (and prebuilt-dist (> (length prebuilt-dist) 0))
    # CI/operator już zbudował ZDE wcześniej w tym samym biegu (np.
    # osobny krok `janet build.janet` przed wywołaniem `zpk build`) --
    # nie buduj drugi raz, użyj gotowego katalogu dist/.
    prebuilt-dist
    (do
      (run (string "command -v janet >/dev/null 2>&1 || "
                   "{ echo \"recipe.janet: brak 'janet' w PATH -- patrz README, sekcja Budowanie\" >&2; exit 1; }"))
      # Pełny build (kompozytor Wayland zde-comp + shell zde-shell na
      # Waylandzie) -- sprawdza też zależności systemowe (wlroots,
      # wayland-protocols, itd.), patrz build.janet.
      (run (string "cd " repo-root " && janet build.janet"))
      dist)))

(def binaries ["zde-comp" "zde-shell"])

(def bin-dir (string stage "/usr/local/bin"))
(ensure-dir stage)
(ensure-dir (string stage "/usr"))
(ensure-dir (string stage "/usr/local"))
(ensure-dir bin-dir)

(each name binaries
  (def src (string bin-dist-dir "/" name))
  (unless (os/stat src :mode)
    (fail (string "nie znaleziono zbudowanej binarki: " src)))
  (def dest (string bin-dir "/" name))
  (spit dest (slurp src))
  (run (string "chmod +x " dest)))
