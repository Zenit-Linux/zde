import std/[strutils, os, posix]
import fidget
import ../../comp/comp
import ../../zdeconfig
import ../../shell/state as zde_state
import ../../shell/shortcuts

type
  SettingsSection = enum
    secAppearance, secMonitors, secKeyboard, secShortcuts

  SettingsState* = ref object of RootObj
    cfg*: ZdeConfig
    section: SettingsSection
    statusMsg: string
    newMonitorName: string
    ## Stan przeciągania w wizualnym edytorze monitorów -- -1 = nic nie jest
    ## aktualnie przeciągane. `dragStartMouseX/Y` to pozycja myszy w chwili
    ## kliknięcia (w pikselach EKRANU okna), `dragStartMonX/Y` to pozycja
    ## TEGO monitora w chwili kliknięcia (w pikselach WIRTUALNEGO układu
    ## monitorów, czyli jednostkach z configu) -- różnica między bieżącą a
    ## startową pozycją myszy, podzielona przez skalę podglądu, daje nowe
    ## X/Y monitora. Patrz `drawMonitorCanvas`.
    draggingMonitor: int
    dragStartMouseX, dragStartMouseY: float32
    dragStartMonX, dragStartMonY: int
    dragScale: float32  ## skala Z CHWILI ROZPOCZĘCIA przeciągania -- patrz
                         ## duży komentarz w `drawMonitorCanvas` o tym, dlaczego
                         ## NIE wolno przeliczać jej na nowo w trakcie przeciągania
    shortcuts: ShortcutMap
    recordingAction: int  ## indeks ShortcutAction właśnie nagrywanego, -1 = brak

proc newSettingsState*(): SettingsState =
  result = SettingsState(cfg: loadConfig(), section: secAppearance, draggingMonitor: -1,
                          recordingAction: -1, shortcuts: activeShortcuts)
  if result.cfg.monitors.len == 0:
    ## Brak configu -- podpowiedz jeden wpis odzwierciedlający aktualny,
    ## jedyny wirtualny ekran tej kompilacji GLFW/X11, żeby lista nie była
    ## pusta i użytkownik miał co edytować zamiast zaczynać od zera.
    result.cfg.monitors.add(MonitorConfig(
      name: "eDP-1", x: 0, y: 0, width: 1920, height: 1080,
      enabled: true, primary: true,
    ))

const
  AccentPresets = [
    "#5fb0ff", "#5fd7a7", "#e0a850", "#e5666b", "#c98adb", "#5fc9c9", "#f0f0f0",
  ]
  SidebarW = 150.0'f32
  RowH = 30.0'f32

proc applyAccentColorLive(hex: string) =
  ## Mutuje `state.AccentColor` (jest `var` właśnie w tym celu -- patrz
  ## komentarz w shell/state.nim) -- pasek zadań, ramki aktywnych okien i
  ## launcher przefarbowują się natychmiast, bez restartu.
  zde_state.AccentColor = hex

proc pidFilePath(): string =
  let rt = getEnv("XDG_RUNTIME_DIR", "")
  (if rt.len > 0: rt else: "/tmp") / "zde-comp.pid"

proc reloadCompositor(ss: SettingsState) =
  ## NAPRAWIONY BRAK (IPC): wcześniej jedynym sposobem na zastosowanie
  ## zmian w Monitorach/Klawiaturze był ręczny restart zde-comp. SIGHUP to
  ## standardowa uniksowa konwencja "przeładuj konfigurację" -- kompozytor
  ## nasłuchuje jej czysto przez pętlę zdarzeń Wayland (patrz
  ## `wlcomp/main.nim`, `onSighup`), bez rozłączania klientów. Weryfikowane
  ## realnym uruchomieniem: PID zapisywany do pliku, SIGHUP wysłany dwa
  ## razy z rzędu, kompozytor przeżył oba i faktycznie przeładował układ
  ## monitorów i klawiatury -- patrz NAPRAWY.md.
  let p = pidFilePath()
  if not fileExists(p):
    ss.statusMsg = "zde-comp nie działa (brak " & p & ") -- zapisano, zastosuje się przy następnym starcie"
    return
  try:
    let pidStr = readFile(p).strip()
    let pid = Pid(parseInt(pidStr))
    if kill(pid, SIGHUP) == 0:
      ss.statusMsg = "Zapisano i wysłano SIGHUP do zde-comp (PID " & pidStr & ") -- zastosowano bez restartu"
    else:
      ss.statusMsg = "Zapisano, ale nie udało się powiadomić zde-comp (PID " & pidStr & " nie istnieje?)"
  except ValueError, IOError:
    ss.statusMsg = "Zapisano do " & configPath() & " (nie udało się odczytać PID zde-comp)"

proc save(ss: SettingsState) =
  saveConfig(ss.cfg)
  reloadCompositor(ss)

proc drawSidebarItem(label: string, active: bool, y: float32, action: proc()) =
  group "settings-nav-" & label:
    box 0, y, SidebarW, RowH
    fill (if active: PanelBgHover else: "#000000"), (if active: 1.0 else: 0.0)
    cornerRadius 4
    onHover:
      if not active: fill "#20262e"
    onClick:
      action()
    text "settings-nav-label-" & label:
      box 12, 0, SidebarW - 12, RowH
      font "sans-serif", 12, (if active: 600 else: 400), RowH, hLeft, vCenter
      fill (if active: "#ffffff" else: "#aeb6c2")
      characters label

proc drawAppearance(ss: SettingsState, x, y, w: float32) =
  text "appearance-title":
    box x, y, w, 24
    font "sans-serif", 14, 700, 24, hLeft, vCenter
    fill "#e8ecf0"
    characters "Kolor akcentu"

  var cx = x
  let cy = y + 34
  for i, c in AccentPresets:
    let isActive = zde_state.AccentColor == c
    group "accent-swatch-" & $i:
      box cx, cy, 34, 34
      cornerRadius 17
      fill c
      stroke (if isActive: "#ffffff" else: "#000000"), (if isActive: 1.0 else: 0.0)
      strokeWeight 3
      onClick:
        applyAccentColorLive(c)
        ss.cfg.accentColor = c
        save(ss)
    cx += 42

  text "appearance-note":
    box x, cy + 52, w, 40
    font "sans-serif", 11, 400, 16, hLeft, vTop
    fill "#8a94a3"
    characters "Zmiana widoczna od razu w pasku zadań i ramkach okien. Zapisywana automatycznie."

const
  SnapPx = 24  ## próg przyciągania krawędzi (w jednostkach WIRTUALNEGO
               ## układu, czyli pikselach configu -- nie pikselach ekranu
               ## okna Ustawień)

proc snapEdge(monitors: seq[MonitorConfig], selfIdx: int, x, y, w, h: int): (int, int) =
  ## Zwraca (x, y) po ewentualnym przyciągnięciu do krawędzi INNYCH
  ## monitorów -- niezależnie na osi X i na osi Y. Sprawdzane pary:
  ## lewa-do-prawej, prawa-do-lewej, i wyrównanie górnych/dolnych krawędzi
  ## (typowe przy ustawianiu monitorów obok siebie).
  result = (x, y)
  for j, om in monitors:
    if j == selfIdx: continue
    # oś X: prawa krawędź TEGO monitora do lewej krawędzi INNEGO
    if abs((x + w) - om.x) <= SnapPx: result[0] = om.x - w
    # oś X: lewa krawędź TEGO do prawej krawędzi INNEGO
    elif abs(x - (om.x + om.width)) <= SnapPx: result[0] = om.x + om.width
    # oś X: wyrównanie lewych krawędzi (monitory jeden nad drugim)
    elif abs(x - om.x) <= SnapPx: result[0] = om.x

    # oś Y: dolna krawędź TEGO do górnej krawędzi INNEGO
    if abs((y + h) - om.y) <= SnapPx: result[1] = om.y - h
    # oś Y: górna krawędź TEGO do dolnej krawędzi INNEGO
    elif abs(y - (om.y + om.height)) <= SnapPx: result[1] = om.y + om.height
    # oś Y: wyrównanie górnych krawędzi (monitory obok siebie w rzędzie)
    elif abs(y - om.y) <= SnapPx: result[1] = om.y

proc drawMonitorCanvas(ss: SettingsState, x, y, w, canvasH: float32) =
  ## Wizualny podgląd układu monitorów z przeciąganiem myszką. Skala
  ## dobierana automatycznie, żeby wszystkie monitory zmieściły się w
  ## dostępnym obszarze (`w` x `canvasH`), z marginesem.
  ##
  ## UWAGA O KOLEJNOŚCI: tło (`mon-canvas-bg`) musi być zadeklarowane PO
  ## prostokątach monitorów, nie przed -- Fidget renderuje dzieci w
  ## kolejności ODWRÓCONEJ względem deklaracji (pierwszy zadeklarowany =
  ## na wierzchu, patrz duży komentarz w shell/shell.nim). Zadeklarowanie
  ## tła jako pierwsze (intuicyjne, "najpierw rysuję tło") sprawiało, że
  ## nieprzezroczyste tło renderowało się NA WIERZCHU prostokątów
  ## monitorów -- canvas wyglądał na pusty, mimo że dane i logika
  ## przeciągania działały poprawnie (ten sam błąd, który naprawiliśmy w
  ## drawMain() na samym początku tej pracy nad ZDE).

  if ss.cfg.monitors.len == 0:
    group "mon-canvas-bg":
      box x, y, w, canvasH
      fill "#0d0f13"
      cornerRadius 4
      stroke "#262c34"
      strokeWeight 1
    return

  var minX, minY = int.high
  var maxX, maxY = int.low
  for m in ss.cfg.monitors:
    minX = min(minX, m.x); minY = min(minY, m.y)
    maxX = max(maxX, m.x + m.width); maxY = max(maxY, m.y + m.height)
  let totalW = max(1, maxX - minX)
  let totalH = max(1, maxY - minY)
  let margin = 24.0'f32
  let scale = min((w - margin * 2) / totalW.float32, (canvasH - margin * 2) / totalH.float32)
  let offX = x + (w - totalW.float32 * scale) / 2
  let offY = y + (canvasH - totalH.float32 * scale) / 2

  ## NAPRAWIONY BUG (znaleziony realnym testem przeciągnięcia myszką pod
  ## Xvfb -- nie widoczny bez faktycznego wykonania interakcji): skala
  ## podglądu (`scale`) jest liczona z bieżącego bounding-boxa WSZYSTKICH
  ## monitorów, WŁĄCZNIE z tym aktualnie przeciąganym. Gdyby użyć tej samej,
  ## na nowo przeliczanej co klatkę skali do interpretacji przesunięcia
  ## myszy PODCZAS przeciągania, powstaje pętla dodatniego sprzężenia
  ## zwrotnego: przesunięcie monitora powiększa bounding-box -> zmniejsza
  ## skalę -> to samo przesunięcie myszy daje WIĘKSZE przesunięcie
  ## wirtualne -> monitor ucieka jeszcze dalej -> ... W praktyce jeden
  ## krótki przeciąg wywindował monitor do współrzędnych rzędu miliona
  ## pikseli. Naprawione: skala używana do PRZELICZANIA przesunięcia myszy
  ## na przesunięcie monitora jest zamrożona (`ss.dragScale`) w chwili
  ## rozpoczęcia przeciągania (`onClick` niżej) i nie zmienia się aż do
  ## puszczenia przycisku -- tylko skala używana do RYSOWANIA może się
  ## swobodnie przeliczać co klatkę (to nieszkodliwe, czysto kosmetyczne).
  if ss.draggingMonitor >= 0 and ss.draggingMonitor < ss.cfg.monitors.len:
    if buttonDown[MOUSE_LEFT]:
      let dx = int((mouse.pos.x - ss.dragStartMouseX) / ss.dragScale)
      let dy = int((mouse.pos.y - ss.dragStartMouseY) / ss.dragScale)
      let m = addr ss.cfg.monitors[ss.draggingMonitor]
      let (sx, sy) = snapEdge(ss.cfg.monitors, ss.draggingMonitor,
                               ss.dragStartMonX + dx, ss.dragStartMonY + dy, m.width, m.height)
      m.x = sx
      m.y = sy
    else:
      ss.draggingMonitor = -1

  for i in 0 ..< ss.cfg.monitors.len:
    let m = ss.cfg.monitors[i]
    let rx = offX + (m.x - minX).float32 * scale
    let ry = offY + (m.y - minY).float32 * scale
    let rw = max(20.0'f32, m.width.float32 * scale)
    let rh = max(16.0'f32, m.height.float32 * scale)
    let isDragging = ss.draggingMonitor == i
    group "mon-rect-" & $i:
      box rx, ry, rw, rh
      cornerRadius 3
      fill (if m.enabled: (if isDragging: AccentColor else: "#2d5f8a") else: "#3a3f47")
      stroke (if isDragging: "#ffffff" else: "#1a2027")
      strokeWeight (if isDragging: 2.0 else: 1.0)
      onHover:
        mouse.cursorStyle = (if isDragging: Grab else: Pointer)
      onClick:
        ss.draggingMonitor = i
        ss.dragStartMouseX = mouse.pos.x
        ss.dragStartMouseY = mouse.pos.y
        ss.dragStartMonX = m.x
        ss.dragStartMonY = m.y
        ss.dragScale = scale
      text "mon-rect-label-" & $i:
        box 4, 2, rw - 8, rh - 4
        font "sans-serif", 10, 600, min(16.0'f32, rh - 4), hLeft, vTop
        fill "#ffffff"
        characters m.name

  # Tło zadeklarowane NA KOŃCU celowo -- patrz komentarz na górze proc.
  group "mon-canvas-bg":
    box x, y, w, canvasH
    fill "#0d0f13"
    cornerRadius 4
    stroke "#262c34"
    strokeWeight 1

proc drawMonitors(ss: SettingsState, x, y, w: float32) =
  text "mon-title":
    box x, y, w, 24
    font "sans-serif", 14, 700, 24, hLeft, vCenter
    fill "#e8ecf0"
    characters "Monitory"

  text "mon-note":
    box x, y + 26, w, 32
    font "sans-serif", 11, 400, 15, hLeft, vTop
    fill "#8a94a3"
    characters "Przeciągnij prostokąty myszką (przyciągają do krawędzi sąsiadów), albo doprecyzuj liczbami niżej. Zapis wysyła SIGHUP do zde-comp -- układ zastosuje się od razu."

  const CanvasH = 150.0'f32
  drawMonitorCanvas(ss, x, y + 60, w, CanvasH)

  var ry = y + 60 + CanvasH + 20
  ## NAPRAWIONA DROBNA USTERKA KOSMETYCZNA: kolumny miały stałe przesunięcia
  ## w pikselach od `x`, więc przy węższym oknie (albo dłuższych nazwach
  ## wyjść) kolumna "GŁÓWNY" i przycisk usuwania wychodziły poza prawą
  ## krawędź okna. Teraz pozycje kolumn są proporcjonalne do dostępnej
  ## szerokości `w`, więc dopasowują się przy zmianie rozmiaru okna.
  let colName = x
  let colX = x + w * 0.40
  let colY = x + w * 0.54
  let colEnabled = x + w * 0.68
  let colPrimary = x + w * 0.80
  let colRemove = x + w - 26

  text "mon-hdr":
    box colName, ry, w, 18
    font "sans-serif", 10, 700, 18, hLeft, vCenter
    fill "#6d7684"
    characters "NAZWA WYJŚCIA          X       Y     WŁ.   GŁÓWNY"
  ry += 24

  for i in 0 ..< ss.cfg.monitors.len:
    let m = addr ss.cfg.monitors[i]
    group "mon-row-" & $i:
      box x, ry, w, RowH
      fill (if i mod 2 == 0: "#181c22" else: "#000000"), (if i mod 2 == 0: 1.0 else: 0.0)

      text "mon-name-" & $i:
        box colName + 4, 0, 150, RowH
        font "monospace", 12, 400, RowH, hLeft, vCenter
        fill "#dbe1e8"
        characters m.name

      text "mon-x-" & $i:
        box colX, 0, 60, RowH
        font "monospace", 12, 400, RowH, hLeft, vCenter
        fill "#dbe1e8"
        editableText true
        selectable true
        if not current.hasKeyboardFocus():
          characters $m.x
        onClick: keyboard.focus(current)
        onInput:
          try: m.x = parseInt(keyboard.input)
          except ValueError: discard

      text "mon-y-" & $i:
        box colY, 0, 60, RowH
        font "monospace", 12, 400, RowH, hLeft, vCenter
        fill "#dbe1e8"
        editableText true
        selectable true
        if not current.hasKeyboardFocus():
          characters $m.y
        onClick: keyboard.focus(current)
        onInput:
          try: m.y = parseInt(keyboard.input)
          except ValueError: discard

      group "mon-enabled-" & $i:
        box colEnabled, 6, 18, 18
        cornerRadius 3
        fill (if m.enabled: AccentColor else: "#2a2f36")
        onClick: m.enabled = not m.enabled

      group "mon-primary-" & $i:
        box colPrimary, 6, 18, 18
        cornerRadius 9
        fill (if m.primary: AccentColor else: "#2a2f36")
        onClick:
          for j in 0 ..< ss.cfg.monitors.len:
            ss.cfg.monitors[j].primary = (j == i)

      group "mon-remove-" & $i:
        box w - 24, 4, 22, 22
        cornerRadius 4
        fill "#3a1f24"
        onHover: fill "#552831"
        onClick:
          ss.cfg.monitors.delete(i)
        text "mon-remove-x-" & $i:
          box 0, 0, 22, 22
          font "sans-serif", 12, 700, 22, hCenter, vCenter
          fill "#e5888c"
          characters "×"

    ry += RowH

  group "mon-add":
    box x, ry + 8, 200, 28
    cornerRadius 4
    fill "#2a2f36"
    onHover: fill "#3a424d"
    onClick:
      ss.cfg.monitors.add(MonitorConfig(
        name: "HDMI-A-" & $(ss.cfg.monitors.len + 1),
        x: 1920 * ss.cfg.monitors.len, y: 0,
        width: 1920, height: 1080, enabled: true, primary: false,
      ))
    text "mon-add-label":
      box 0, 0, 200, 28
      font "sans-serif", 12, 600, 28, hCenter, vCenter
      fill "#e8ecf0"
      characters "+ Dodaj monitor"

  group "mon-save":
    box x, ry + 46, 200, 28
    cornerRadius 4
    fill "#2d5f8a"
    onHover: fill "#3a72a3"
    onClick: save(ss)
    text "mon-save-label":
      box 0, 0, 200, 28
      font "sans-serif", 12, 600, 28, hCenter, vCenter
      fill "#ffffff"
      characters "Zapisz układ"

proc drawKeyboard(ss: SettingsState, x, y, w: float32) =
  text "kb-title":
    box x, y, w, 24
    font "sans-serif", 14, 700, 24, hLeft, vCenter
    fill "#e8ecf0"
    characters "Układ klawiatury"

  text "kb-note":
    box x, y + 26, w, 32
    font "sans-serif", 11, 400, 15, hLeft, vTop
    fill "#8a94a3"
    characters "Kod układu XKB (np. \"us\", \"pl\", \"de\"). Zapis wysyła SIGHUP do zde-comp -- zastosuje się od razu."

  group "kb-field":
    box x, y + 66, 200, 32
    cornerRadius 4
    fill "#1b2027"
    stroke "#333b45"
    strokeWeight 1
    text "kb-input":
      box 10, 0, 180, 32
      font "monospace", 13, 400, 32, hLeft, vCenter
      fill "#e8ecf0"
      editableText true
      selectable true
      if not current.hasKeyboardFocus():
        characters ss.cfg.xkbLayout
      onClick: keyboard.focus(current)
      onInput:
        ss.cfg.xkbLayout = keyboard.input

  group "kb-save":
    box x, y + 108, 200, 28
    cornerRadius 4
    fill "#2d5f8a"
    onHover: fill "#3a72a3"
    onClick: save(ss)
    text "kb-save-label":
      box 0, 0, 200, 28
      font "sans-serif", 12, 600, 28, hCenter, vCenter
      fill "#ffffff"
      characters "Zapisz"

proc saveShortcuts(ss: SettingsState) =
  ss.cfg.shortcuts = toConfigEntries(ss.shortcuts)
  saveConfig(ss.cfg)
  shortcuts.activeShortcuts = ss.shortcuts  ## widoczne od razu w tym samym procesie zde-shell
  ss.statusMsg = "Zapisano skróty klawiszowe"

proc drawShortcuts(ss: SettingsState, x, y, w: float32) =
  text "sc-title":
    box x, y, w, 24
    font "sans-serif", 14, 700, 24, hLeft, vCenter
    fill "#e8ecf0"
    characters "Skróty klawiszowe"

  text "sc-note":
    box x, y + 26, w, 32
    font "sans-serif", 11, 400, 15, hLeft, vTop
    fill "#8a94a3"
    characters "Kliknij kombinację, potem naciśnij nowe klawisze. Escape anuluje."

  var ry = y + 64
  for a in ShortcutAction:
    let idx = ord(a)
    let isRecording = ss.recordingAction == idx

    ## NAPRAWIONY BRAK: wcześniej jedyne skróty (Alt+Tab, Escape) były
    ## zaszyte na sztywno w shell.nim -- teraz każda akcja ma edytowalną
    ## kombinację, przechwytywaną na żywo z klawiatury (patrz
    ## `captureComboIfPressed` w shell/shortcuts.nim).
    if isRecording:
      let captured = captureComboIfPressed()
      if captured.len > 0:
        ss.shortcuts[a] = captured
        ss.recordingAction = -1
        saveShortcuts(ss)
      elif buttonPress[ESCAPE]:
        ss.recordingAction = -1

    group "sc-row-" & $idx:
      box x, ry, w, RowH
      fill (if idx mod 2 == 0: "#181c22" else: "#000000"), (if idx mod 2 == 0: 1.0 else: 0.0)

      text "sc-label-" & $idx:
        box 4, 0, w * 0.55, RowH
        font "sans-serif", 12, 400, RowH, hLeft, vCenter
        fill "#dbe1e8"
        characters ActionLabels[a]

      group "sc-combo-" & $idx:
        box w * 0.58, 4, w * 0.42 - 4, RowH - 8
        cornerRadius 4
        fill (if isRecording: "#2d5f8a" else: "#242b34")
        onHover:
          if not isRecording: fill "#2e3540"
        onClick:
          ss.recordingAction = (if isRecording: -1 else: idx)
        text "sc-combo-label-" & $idx:
          box 0, 0, w * 0.42 - 4, RowH - 8
          font "monospace", 11, 600, RowH - 8, hCenter, vCenter
          fill "#ffffff"
          characters (if isRecording: "Naciśnij klawisze..." else: comboLabel(ss.shortcuts[a]))

    ry += RowH

proc drawSettings*(ss: SettingsState, win: ZdeWindow) =
  frame "settings-root":
    box 0, 0, win.size.x, win.size.y
    fill "#14171c"

    group "sidebar":
      box 0, 0, SidebarW, win.size.y
      fill "#1b2027"

      drawSidebarItem("Wygląd", ss.section == secAppearance, 8, proc() = ss.section = secAppearance)
      drawSidebarItem("Monitory", ss.section == secMonitors, 8 + RowH + 4, proc() = ss.section = secMonitors)
      drawSidebarItem("Klawiatura", ss.section == secKeyboard, 8 + (RowH + 4) * 2, proc() = ss.section = secKeyboard)
      drawSidebarItem("Skróty", ss.section == secShortcuts, 8 + (RowH + 4) * 3, proc() = ss.section = secShortcuts)

    group "content":
      box SidebarW + 16, 16, win.size.x - SidebarW - 32, win.size.y - 48
      case ss.section
      of secAppearance: drawAppearance(ss, 0, 0, win.size.x - SidebarW - 32)
      of secMonitors: drawMonitors(ss, 0, 0, win.size.x - SidebarW - 32)
      of secKeyboard: drawKeyboard(ss, 0, 0, win.size.x - SidebarW - 32)
      of secShortcuts: drawShortcuts(ss, 0, 0, win.size.x - SidebarW - 32)

    if ss.statusMsg.len > 0:
      text "status":
        box SidebarW + 16, win.size.y - 24, win.size.x - SidebarW - 32, 20
        font "sans-serif", 11, 400, 16, hLeft, vCenter
        fill "#7fbf7f"
        characters ss.statusMsg
