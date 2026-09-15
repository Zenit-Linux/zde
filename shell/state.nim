import fidget
import ../comp/comp
import ../apps/terminal/term
import ../apps/sysmonitor/sysmonitor
import ../apps/clock/clockapp
import ../apps/texteditor/texteditor
import ../zdeconfig

export comp
export term
export sysmonitor
export clockapp
export texteditor

var
  compositor* = newCompositor(vec2(1280, 800))
  clockText* = "--:--:--"
  lastClockUpdate* = 0.0
  terminals*: seq[TerminalState] = @[]  ## rejestr żywych terminali do odpytywania w tick()
  sysmonitors*: seq[SysMonState] = @[]   ## rejestr okien monitora systemu do odpytywania w tick()
  ## NOWA FUNKCJA (rozbudowa v0.1): rejestr żywych okien zegara -- ten sam
  ## wzorzec co `terminals`/`sysmonitors` powyżej. Bez tego rejestru
  ## alarmy i minutnik zegara odliczałyby TYLKO wtedy, gdy okno zegara jest
  ## akurat rysowane (a Fidget rysuje tylko widoczne, niezminimalizowane
  ## okna) -- z rejestrem `tickClock` jest wołane raz na sekundę z
  ## `shell.nim`, niezależnie od tego, czy okno jest akurat na wierzchu.
  clocks*: seq[ClockState] = @[]
  ## Rozbudowa v0.1 ("Aurora" -- wykrywanie zmian na dysku): ten sam
  ## wzorzec co `clocks` powyżej -- bez rejestru `checkExternalChanges`
  ## odpytywałoby dysk TYLKO gdy okno edytora jest akurat rysowane.
  texteditors*: seq[EditorState] = @[]

  ## NAPRAWIONY BRAK: kolor akcentu był `const`, więc jedynym sposobem na
  ## jego zmianę było przebudowanie zde-shell. Aplikacja "Ustawienia"
  ## (apps/settings/settings.nim) zmienia to na żywo (i zapisuje do
  ## zdeconfig.nim, żeby przetrwało restart) -- stąd musi być `var`, nie
  ## `const`. Wczytane raz przy starcie procesu poniżej.
  AccentColor* = loadConfig().accentColor
  ## Rozbudowa (tapeta z pliku): ten sam wzorzec co `AccentColor` wyżej --
  ## `var`, żywo mutowane przez `apps/settings/settings.nim`
  ## (`applyWallpaperLive`), odczytywane przez `shell/wallpaper.nim`
  ## (`drawWallpaper`) co klatkę. "" = brak tapety z pliku, użyj
  ## wbudowanego gradientu (dawne, jedyne dotąd zachowanie).
  WallpaperPath* = loadConfig().wallpaperPath

const
  Bg1* = "#0f1115"
  Bg2* = "#151920"
  PanelBg* = "#1b2027"
  PanelBgHover* = "#242b34"
  TitlebarH* = 30.0'f32

  ## --------------------------------------------------------------------
  ## Rozbudowa v0.1 -- "Aurora": spójny zestaw tokenów wizualnych używanych
  ## przez `wallpaper.nim`, `chrome.nim`, `taskbar.nim` i `launcher_apps.nim`
  ## (poprzednio każdy plik miał swoje zaszyte na sztywno hexy). Trzymanie
  ## ich w jednym miejscu to nie tylko porządek -- zmiana jednego koloru
  ## tutaj naprawdę zmienia wygląd całego shellu za jednym razem, zamiast
  ## grepowania po kilkunastu plikach.
  ## --------------------------------------------------------------------

  ## Głębsze tło pulpitu (pod gradientem tapety) -- ciemniejsze niż `Bg1`,
  ## żeby gradient miał gdzie "opaść" u dołu ekranu.
  BgDeep* = "#0a0b0e"
  ## Druga barwa gradientu tapety (u góry ekranu) -- lekko chłodny, prawie
  ## niewidoczny odcień błękitu, żeby pulpit nie był płaską czernią.
  BgTop* = "#12161f"

  ## Powierzchnie "szkła" -- panele (dock, launcher, karty) na lekko
  ## przezroczystym, chłodnym tle, tak jak w nowoczesnych powłokach
  ## (GNOME/macOS/Windows 11). `GlassAlpha` to stała nieprzezroczystość
  ## używana konsekwentnie, żeby dock/launcher/toasty wyglądały jak ta sama
  ## rodzina materiału.
  Glass* = "#161a22"
  GlassAlpha* = 0.86
  GlassBorder* = "#2c3440"

  ## Tekst -- dwa poziomy ważności, żeby hierarchia była czytelna bez
  ## pogrubiania wszystkiego.
  TextPrimary* = "#eef1f5"
  TextMuted* = "#8992a3"
  TextFaint* = "#5b6472"

  ## Akcenty stanu (używane w `notifications.nim`, paskach postępu itp.).
  StateGood* = "#5fd7a7"
  StateWarn* = "#e0a850"
  StateBad* = "#e5666b"

  ## Promienie zaokrągleń -- dwa rozmiary, żeby duże panele (dock, karty,
  ## okna) i małe elementy (przyciski, chipy) miały spójną, ale
  ## rozróżnialną skalę zaokrąglenia zamiast przypadkowych liczb w każdym
  ## pliku.
  RadiusLg* = 14.0
  RadiusMd* = 10.0
  RadiusSm* = 6.0
