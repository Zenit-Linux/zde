import std/[os, strutils]

## config.nims -- Zenit Desktop Environment
## ---------------------------------------------------------------------------
## Część paczek w ekosystemie nimble bywa spakowana tak, że ich główny plik
## .nim leży w katalogu głównym paczki zamiast w oczekiwanym `src/` (albo
## odwrotnie, zależnie od tego, jak dokładnie trafiły do lokalnego cache'a
## nimble -- `pkgs/` kontra nowszy `pkgs2/`). Ten plik wykrywa i naprawia
## takie przypadki automatycznie, żeby `nim c`/`nimble build` działały bez
## ręcznego dłubania w `--path`.
##
## Oryginalnie ta logika obsługiwała tylko `opengl` -- rozszerzyłem ją o
## resztę paczek, na których faktycznie natrafiłem podczas budowania ZDE
## w środowisku z ograniczonym/niestandardowym cache'em nimble.

const watchedPackages = [
  "opengl", "staticglfw", "cligen", "supersnappy", "bitstreams",
  "html5_canvas", "pixie", "typography", "fidget",
]

proc candidatePkgDirs(): seq[string] =
  let nimbleDir = getEnv("NIMBLE_DIR", getHomeDir() / ".nimble")
  for sub in ["pkgs2", "pkgs"]:
    let d = nimbleDir / sub
    if dirExists(d):
      result.add(d)

proc mainNimName(pkgDirName: string): string =
  ## Katalogi w `pkgs2` mają postać `nazwa-wersja-hashgita40znakow`
  ## (np. "staticglfw-4.1.3-60ff67c7990e64e19bb7ce41cf416ece732115b0"),
  ## a w starszym `pkgs` po prostu `nazwa-wersja`. Trzeba zdjąć oba
  ## przyrostki, W TEJ KOLEJNOŚCI (najpierw hash, potem wersję) --
  ## naiwne "utnij po ostatnim myślniku" myli się na pkgs2, bo hash
  ## zwykle zaczyna się cyfrą i wygląda jak człon wersji.
  var name = pkgDirName

  let hashDash = name.rfind('-')
  if hashDash > 0:
    let suffix = name[hashDash + 1 .. ^1]
    if suffix.len == 40 and suffix.allCharsInSet({'0'..'9', 'a'..'f'}):
      name = name[0 ..< hashDash]

  let verDash = name.rfind('-')
  if verDash > 0 and name[verDash + 1].isDigit():
    name = name[0 ..< verDash]

  name

proc findPackageRoot(pkgPrefix: string): string =
  ## Zwraca katalog zawierający `<pkgPrefix>.nim`, jeśli nie jest tam, gdzie
  ## nimble by go oczekiwał (`<paczka>/src/<nazwa>.nim`); pusty string, gdy
  ## wszystko jest w porządku albo paczka nie jest zainstalowana.
  for pkgsDir in candidatePkgDirs():
    for kind, path in walkDir(pkgsDir):
      if kind != pcDir: continue
      let dirName = extractFilename(path)
      if not dirName.startsWith(pkgPrefix & "-") and dirName != pkgPrefix:
        continue
      let expectedName = mainNimName(dirName)
      if fileExists(path / "src" / (expectedName & ".nim")):
        return ""  # już we właściwym miejscu
      if fileExists(path / (expectedName & ".nim")):
        return path
  ""

for pkgsDir in candidatePkgDirs():
  ## `--NimblePath` mówi Nimowi "szukaj paczek w tym katalogu tak, jak
  ## robiłby to `nimble`" -- każdy podkatalog to osobna paczka. To załatwia
  ## 95% przypadków samo. Poniższa pętla dogrywa `--path` tylko dla tych
  ## kilku paczek, których .nim leży w NIEstandardowym miejscu (patrz
  ## findPackageRoot) -- --NimblePath samo tego nie naprawi.
  switch("NimblePath", pkgsDir)

for pkg in watchedPackages:
  let root = findPackageRoot(pkg)
  if root.len > 0:
    echo "[config.nims] Znana niespójność paczki '" & pkg & "': główny plik .nim jest w " &
         root & ", nie w .../src -- dokładam poprawny --path."
    switch("path", root)

## Wyłączamy SIMD w pixie bezwarunkowo (define honorowany przez wszystkie
## wersje pixie, nie tylko starsze) -- w zamian tracimy trochę wydajności
## renderowania tekstu/kształtów, ale zyskujemy pewność, że zbuduje się
## też na mniej typowych CPU/toolchainach.
switch("define", "pixieNoSimd")
