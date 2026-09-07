import fidget
import ../comp/comp
import ../apps/terminal/term
import ../apps/sysmonitor/sysmonitor
import ../zdeconfig

export comp
export term
export sysmonitor

var
  compositor* = newCompositor(vec2(1280, 800))
  clockText* = "--:--:--"
  lastClockUpdate* = 0.0
  terminals*: seq[TerminalState] = @[]  ## rejestr żywych terminali do odpytywania w tick()
  sysmonitors*: seq[SysMonState] = @[]   ## rejestr okien monitora systemu do odpytywania w tick()

  ## NAPRAWIONY BRAK: kolor akcentu był `const`, więc jedynym sposobem na
  ## jego zmianę było przebudowanie zde-shell. Aplikacja "Ustawienia"
  ## (apps/settings/settings.nim) zmienia to na żywo (i zapisuje do
  ## zdeconfig.nim, żeby przetrwało restart) -- stąd musi być `var`, nie
  ## `const`. Wczytane raz przy starcie procesu poniżej.
  AccentColor* = loadConfig().accentColor

const
  Bg1* = "#0f1115"
  Bg2* = "#151920"
  PanelBg* = "#1b2027"
  PanelBgHover* = "#242b34"
  TitlebarH* = 30.0'f32
