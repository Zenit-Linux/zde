# packaging/

Ten katalog pozwala zapakować ZDE (`zde-comp` + `zde-shell`) jako pakiet
`.zpk`, instalowalny przez `zpm` (patrz projekt `zpk` -- builder pakietów
`.zpk` dla Zenit Linux).

## Co tu jest

* `zpk.build` -- manifest pakietu "zde" (format wymagany przez `zpk`).
* `recipe.janet` -- skrypt budujący: woła `janet build.janet` w katalogu
  głównym repo i kopiuje wynikowe binarki (`dist/zde-comp`,
  `dist/zde-shell`) do `usr/local/bin/` wewnątrz stage dir.

## Użycie

Do zbudowania `.zpk` potrzebujesz zainstalowanego `zpk`
(https://github.com/Zenit-Linux/zpk) oraz wszystkich zależności
systemowych ZDE opisanych w głównym `README.md` (Nim, Janet,
wayland-protocols, wlroots >= 0.18, itd.):

```
cd packaging
zpk validate
zpk build --verbose       # zbuduje packaging/out/zde-X.Y.Z-<arch>.zpk
zpk verify out/zde-X.Y.Z-<arch>.zpk
```

Wynikowy plik `.zpk` instaluje się tak samo jak każdy inny pakiet:

```
zpm install packaging/out/zde-X.Y.Z-<arch>.zpk
```

## Zmienna `ZPK_PACKAGING_PREBUILT_DIST`

Jeśli ZDE zostało już zbudowane wcześniej w tym samym biegu (np. w CI,
gdzie `janet build.janet` i tak już się wykonało jako osobny krok),
ustaw `ZPK_PACKAGING_PREBUILT_DIST=<ścieżka-do-dist>` przed `zpk build`,
żeby `recipe.janet` nie budowało po raz drugi:

```
janet build.janet
ZPK_PACKAGING_PREBUILT_DIST="$(pwd)/dist" zpk build --verbose
```

## Wersjonowanie

`package.version` w `zpk.build` MUSI być ręcznie zsynchronizowane z
`version` w `../zde.nimble` -- HCL nie ma wyrażeń ani odwołań między
plikami.
