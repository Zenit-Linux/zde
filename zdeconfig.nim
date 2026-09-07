import std/[json, os]

type
  MonitorConfig* = object
    name*: string      ## nazwa wyjścia (np. "eDP-1", "HDMI-A-1") -- pasuje do wlr_output.name
    x*, y*: int         ## pozycja w globalnym układzie (piksele)
    width*, height*: int
    enabled*: bool
    primary*: bool

  ZdeConfig* = object
    accentColor*: string
    xkbLayout*: string   ## kod układu klawiatury XKB, np. "us", "pl", "de"
    monitors*: seq[MonitorConfig]
    shortcuts*: seq[ShortcutConfig]  ## nadpisania domyślnych skrótów (patrz shell/shortcuts.nim)

  ShortcutConfig* = object
    action*: string  ## nazwa akcji, np. "openTerminal" -- patrz shell/shortcuts.nim
    combo*: string   ## np. "ctrl+alt+t", "super", "alt+tab"

proc defaultConfig*(): ZdeConfig =
  ZdeConfig(accentColor: "#5fb0ff", xkbLayout: "us", monitors: @[])

proc configPath*(): string =
  let base = if getEnv("XDG_CONFIG_HOME", "").len > 0:
               getEnv("XDG_CONFIG_HOME")
             else:
               getHomeDir() / ".config"
  base / "zde" / "settings.json"

proc loadConfig*(): ZdeConfig =
  result = defaultConfig()
  let p = configPath()
  if not fileExists(p): return
  try:
    let j = parseJson(readFile(p))
    if j.hasKey("accentColor") and j["accentColor"].kind == JString:
      result.accentColor = j["accentColor"].getStr()
    if j.hasKey("xkbLayout") and j["xkbLayout"].kind == JString:
      result.xkbLayout = j["xkbLayout"].getStr()
    if j.hasKey("monitors") and j["monitors"].kind == JArray:
      result.monitors = @[]
      for m in j["monitors"]:
        result.monitors.add(MonitorConfig(
          name: m{"name"}.getStr(""),
          x: m{"x"}.getInt(0),
          y: m{"y"}.getInt(0),
          width: m{"width"}.getInt(1920),
          height: m{"height"}.getInt(1080),
          enabled: m{"enabled"}.getBool(true),
          primary: m{"primary"}.getBool(false),
        ))
    if j.hasKey("shortcuts") and j["shortcuts"].kind == JArray:
      result.shortcuts = @[]
      for s in j["shortcuts"]:
        result.shortcuts.add(ShortcutConfig(
          action: s{"action"}.getStr(""),
          combo: s{"combo"}.getStr(""),
        ))
  except CatchableError:
    result = defaultConfig()  ## uszkodzony plik -- lepiej wystartować z sensownymi
                               ## wartościami niż w ogóle nie wystartować

proc saveConfig*(cfg: ZdeConfig) =
  try:
    let p = configPath()
    createDir(p.parentDir())
    var j = newJObject()
    j["accentColor"] = %cfg.accentColor
    j["xkbLayout"] = %cfg.xkbLayout
    var marr = newJArray()
    for m in cfg.monitors:
      var mo = newJObject()
      mo["name"] = %m.name
      mo["x"] = %m.x
      mo["y"] = %m.y
      mo["width"] = %m.width
      mo["height"] = %m.height
      mo["enabled"] = %m.enabled
      mo["primary"] = %m.primary
      marr.add(mo)
    j["monitors"] = marr
    var sarr = newJArray()
    for s in cfg.shortcuts:
      var so = newJObject()
      so["action"] = %s.action
      so["combo"] = %s.combo
      sarr.add(so)
    j["shortcuts"] = sarr
    writeFile(p, pretty(j))
  except CatchableError:
    discard  ## zapis to best-effort -- brak miejsca na dysku / brak uprawnień
             ## nie powinno wywalać aplikacji, tylko pominąć zapis
