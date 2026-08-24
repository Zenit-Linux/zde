import std/[os, strutils]

proc findOpenglRoot(): string =
  ## Zwraca katalog zawierający prawdziwy opengl.nim, albo "" jeśli:
  ##  - paczka nie jest jeszcze zainstalowana,
  ##  - albo już leży tam, gdzie nimble się tego spodziewa (src/) i nic
  ##    nie trzeba dokładać.
  let nimbleDir = getEnv("NIMBLE_DIR", getHomeDir() / ".nimble")
  let pkgsDir = nimbleDir / "pkgs2"
  if not dirExists(pkgsDir):
    return ""
  for kind, path in walkDir(pkgsDir):
    if kind != pcDir: continue
    if not extractFilename(path).startsWith("opengl-"): continue
    if fileExists(path / "src" / "opengl.nim"):
      return ""  # już we właściwym miejscu, nic do naprawienia
    if fileExists(path / "opengl.nim"):
      return path
  ""

let openglRoot = findOpenglRoot()
if openglRoot.len > 0:
  echo "[config.nims] Znana niespójność paczki 'opengl': opengl.nim jest w " &
       openglRoot & ", nie w .../src -- dokładam poprawny --path."
  switch("path", openglRoot)
