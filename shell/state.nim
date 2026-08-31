import fidget
import ../comp/comp
import ../apps/terminal/term
import ../apps/sysmonitor/sysmonitor

export comp
export term
export sysmonitor

var
  compositor* = newCompositor(vec2(1280, 800))
  clockText* = "--:--:--"
  lastClockUpdate* = 0.0
  terminals*: seq[TerminalState] = @[]  ## rejestr żywych terminali do odpytywania w tick()
  sysmonitors*: seq[SysMonState] = @[]   ## rejestr okien monitora systemu do odpytywania w tick()

const
  Bg1* = "#0f1115"
  Bg2* = "#151920"
  PanelBg* = "#1b2027"
  PanelBgHover* = "#242b34"
  AccentColor* = "#5fb0ff"
  TitlebarH* = 30.0'f32
