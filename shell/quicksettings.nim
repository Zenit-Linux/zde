import std/[os, osproc, strutils, math]

## Rozbudowa v0.1 ("Aurora" -- quick settings). ZDE nie ma (i nie będzie
## miało w tym zakresie) własnego demona audio ani sterownika
## podświetlenia -- to są rzeczy, które w każdej normalnej dystrybucji
## Linuksa obsługuje PipeWire/PulseAudio (dźwięk) i jądro przez
## `/sys/class/backlight` (jasność, zwykle z udev regułami dającymi
## zwykłemu użytkownikowi prawo zapisu). Ten moduł jest więc CELOWO
## cienką warstwą best-effort nad zewnętrznymi narzędziami -- dokładnie
## ten sam wzorzec co `shell/clipboard.nim` (wl-copy/xclip) i
## `shell/desktopapps.nim` (uruchamianie aplikacji): sprawdzamy, co jest
## zainstalowane, i używamy pierwszego pasującego. Gdy NIC nie jest
## dostępne, odpowiednia sekcja panelu (`shell/taskbar.nim`,
## `drawQuickSettings`) po prostu się nie pokazuje -- nie ma sensu
## rysować suwaka, który i tak niczego by nie zmienił.

# ---------------------------------------------------------------------------
# Głośność
# ---------------------------------------------------------------------------

type VolumeBackend = enum vbNone, vbWpctl, vbPactl, vbAmixer

proc detectVolumeBackend(): VolumeBackend =
  ## `wpctl` (PipeWire) i `pactl` (PulseAudio/PipeWire-pulse) w tej
  ## kolejności -- oba dziś obsługują ten sam serwer dźwięku w
  ## większości dystrybucji, `wpctl` jest tylko nowszy/natywny dla
  ## PipeWire. `amixer` (czyste ALSA, bez serwera dźwięku) jako ostatnia
  ## deska ratunku.
  if findExe("wpctl").len > 0: return vbWpctl
  if findExe("pactl").len > 0: return vbPactl
  if findExe("amixer").len > 0: return vbAmixer
  vbNone

let volumeBackend = detectVolumeBackend()

proc hasVolumeControl*(): bool = volumeBackend != vbNone

proc getVolume*(): tuple[percent: int, muted: bool] =
  ## Zwraca (0, false) gdy nie da się odczytać -- wywołujący i tak
  ## powinien wcześniej sprawdzić `hasVolumeControl()`.
  case volumeBackend
  of vbNone: (0, false)
  of vbWpctl:
    try:
      let output = execProcess("wpctl", args = ["get-volume", "@DEFAULT_AUDIO_SINK@"], options = {poUsePath})
      ## Format: "Volume: 0.45" albo "Volume: 0.45 [MUTED]"
      let muted = "MUTED" in output
      let parts = output.splitWhitespace()
      let pct = if parts.len >= 2: int(parseFloat(parts[1]) * 100.0 + 0.5) else: 0
      (pct, muted)
    except ValueError, OSError, IndexDefect:
      (0, false)
  of vbPactl:
    try:
      let output = execProcess("pactl", args = ["get-sink-volume", "@DEFAULT_SINK@"], options = {poUsePath})
      ## Format zawiera co najmniej jedno " NN%" -- bierzemy pierwsze.
      let idx = output.find('%')
      var pct = 0
      if idx > 0:
        var startIdx = idx - 1
        while startIdx > 0 and output[startIdx - 1] in {'0'..'9'}: dec startIdx
        pct = parseInt(output[startIdx ..< idx])
      let mutedOut = execProcess("pactl", args = ["get-sink-mute", "@DEFAULT_SINK@"], options = {poUsePath})
      (pct, "yes" in mutedOut.toLowerAscii())
    except ValueError, OSError:
      (0, false)
  of vbAmixer:
    try:
      let output = execProcess("amixer", args = ["get", "Master"], options = {poUsePath})
      let muted = "[off]" in output
      let idx = output.find('%')
      var pct = 0
      if idx > 0:
        var startIdx = idx - 1
        while startIdx > 0 and output[startIdx - 1] in {'0'..'9'}: dec startIdx
        pct = parseInt(output[startIdx ..< idx])
      (pct, muted)
    except ValueError, OSError:
      (0, false)

proc setVolume*(percent: int) =
  let p = clamp(percent, 0, 100)
  try:
    case volumeBackend
    of vbNone: discard
    of vbWpctl:
      discard execProcess("wpctl", args = ["set-volume", "@DEFAULT_AUDIO_SINK@", $p & "%"], options = {poUsePath})
    of vbPactl:
      discard execProcess("pactl", args = ["set-sink-volume", "@DEFAULT_SINK@", $p & "%"], options = {poUsePath})
    of vbAmixer:
      discard execProcess("amixer", args = ["set", "Master", $p & "%"], options = {poUsePath})
  except OSError:
    discard

proc toggleMute*() =
  try:
    case volumeBackend
    of vbNone: discard
    of vbWpctl:
      discard execProcess("wpctl", args = ["set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"], options = {poUsePath})
    of vbPactl:
      discard execProcess("pactl", args = ["set-sink-mute", "@DEFAULT_SINK@", "toggle"], options = {poUsePath})
    of vbAmixer:
      discard execProcess("amixer", args = ["set", "Master", "toggle"], options = {poUsePath})
  except OSError:
    discard

# ---------------------------------------------------------------------------
# Jasność ekranu
# ---------------------------------------------------------------------------

proc findBacklightDir(): string =
  ## Pierwszy katalog pod `/sys/class/backlight/` -- w praktyce systemy
  ## z jednym panelem (laptopy) mają dokładnie jeden. Wielomonitorowe
  ## konfiguracje z kilkoma sterowalnymi podświetleniami to rzadkość i
  ## świadomie poza zakresem (dotyczy głównie zewnętrznych monitorów,
  ## które i tak zwykle nie eksponują jasności przez ten sam mechanizm).
  if not dirExists("/sys/class/backlight"): return ""
  for kind, path in walkDir("/sys/class/backlight"):
    if kind == pcDir or kind == pcLinkToDir:
      return path
  ""

let backlightDir = findBacklightDir()
let hasBrightnessctl = findExe("brightnessctl").len > 0

proc hasBrightnessControl*(): bool = backlightDir.len > 0

proc getBrightness*(): int =
  ## Procent (0-100), albo 0 gdy nie da się odczytać.
  if backlightDir.len == 0: return 0
  try:
    let cur = parseInt(readFile(backlightDir / "brightness").strip())
    let max = parseInt(readFile(backlightDir / "max_brightness").strip())
    if max <= 0: return 0
    int(cur.float / max.float * 100.0 + 0.5)
  except ValueError, IOError, OSError:
    0

proc setBrightness*(percent: int) =
  if backlightDir.len == 0: return
  let p = clamp(percent, 1, 100)  ## nigdy 0 -- zgaszony ekran bez fizycznego przycisku to pułapka dla użytkownika
  try:
    if hasBrightnessctl:
      ## `brightnessctl` samo dba o uprawnienia (udev/setgid) -- preferowane
      ## nad bezpośrednim zapisem do sysfs, który w większości dystrybucji
      ## wymaga roota i tu prawie na pewno zawiedzie dla zwykłego użytkownika.
      discard execProcess("brightnessctl", args = ["set", $p & "%"], options = {poUsePath})
    else:
      let max = parseInt(readFile(backlightDir / "max_brightness").strip())
      let raw = int(p.float / 100.0 * max.float)
      writeFile(backlightDir / "brightness", $raw)
  except ValueError, IOError, OSError:
    discard  ## najpewniej brak uprawnień do zapisu bez brightnessctl -- best-effort, po cichu nic
