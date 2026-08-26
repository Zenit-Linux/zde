version       = "0.1.0"
author        = "Zenit Linux"
description   = "Zenit Desktop Environment (ZDE) -- srodowisko graficzne Zenit Linux, w Nimie + Fidget"
license       = "MIT"
srcDir        = "."
skipDirs      = @["wlcomp", "apps", "comp", "dist"]
bin           = @["shell/shell"]
binDir        = "dist"

# Patrz duzy komentarz na gorze pliku odnosnie "fidget >= 0.7.10" (nie 0.7.9!)
# i "crunchy": nimble przy ">=" wybiera najnizsza pasujaca wersje, a fidget
# 0.7.9 ciagnie za soba pixie z bledem pakowania (brakujaca deklaracja
# zaleznosci "crunchy" w pixie.nimble -> "Error: cannot open file: crunchy").
requires "nim >= 1.4.0"
requires "fidget >= 0.7.10"
requires "crunchy >= 0.1.0"
requires "staticglfw >= 4.1.3"
requires "opengl >= 1.2.9"
requires "vmath >= 1.0"
requires "chroma >= 0.2"
requires "bumpy >= 1.1"
requires "flatty >= 0.3"
requires "zippy >= 0.7"
requires "cligen >= 1.5"
requires "supersnappy >= 2.0"
requires "bitstreams >= 0.1"
requires "html5_canvas >= 1.0"

# --- Zadania ---------------------------------------------------------------

task buildAll, "Buduje zde-comp i zde-shell (Wayland) przez build.janet":
  exec "janet build.janet"

task buildX11, "Buduje zde-shell na X11/GLFW przez build.janet":
  exec "janet build.janet :x11"

task buildComp, "Buduje tylko zde-comp (kompozytor) przez build.janet":
  exec "janet build.janet :comp-only"

task buildShell, "Buduje tylko zde-shell (Wayland) przez build.janet":
  exec "janet build.janet :shell-only"

task buildShellDirect, "Buduje zde-shell (X11) bez Janeta, przez `nimble c`":
  exec "nimble c -d:release -d:pixieNoSimd --hints:off -o:dist/zde-shell shell/shell.nim"

task clean, "Czysci katalog dist/ (przez build.janet, jesli dostepny)":
  exec "janet build.janet :clean"
