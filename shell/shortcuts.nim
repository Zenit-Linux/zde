import std/[strutils, tables]
import fidget
import ../zdeconfig

type
  ShortcutAction* = enum
    actToggleLauncher
    actCycleFocus
    actOpenTerminal
    actOpenFileManager
    actOpenEditor
    actOpenSettings
    actCloseWindow
    actLockScreen
    actLogout

  ParsedShortcut* = object
    ctrl*, alt*, shift*, super*: bool
    key*: Button

const
  ActionNames*: array[ShortcutAction, string] = [
    "toggleLauncher", "cycleFocus", "openTerminal", "openFileManager",
    "openEditor", "openSettings", "closeWindow", "lockScreen", "logout",
  ]
  ActionLabels*: array[ShortcutAction, string] = [
    "Otwórz/zamknij launcher", "Przełącz między oknami", "Otwórz terminal",
    "Otwórz menedżer plików", "Otwórz edytor tekstu", "Otwórz ustawienia",
    "Zamknij aktywne okno", "Zablokuj ekran", "Wyloguj",
  ]
  DefaultCombos*: array[ShortcutAction, string] = [
    "super+space", "alt+tab", "ctrl+alt+t", "ctrl+alt+e", "ctrl+alt+n",
    "ctrl+alt+s", "ctrl+alt+q", "ctrl+alt+l", "ctrl+alt+shift+q",
  ]

  NamedKeys = {
    "tab": TAB, "escape": ESCAPE, "enter": ENTER, "space": SPACE,
    "delete": DELETE, "backspace": BACKSPACE, "insert": INSERT,
    "home": HOME, "end": END, "pageup": PAGE_UP, "pagedown": PAGE_DOWN,
    "up": ARROW_UP, "down": ARROW_DOWN, "left": ARROW_LEFT, "right": ARROW_RIGHT,
    "f1": F1, "f2": F2, "f3": F3, "f4": F4, "f5": F5, "f6": F6,
    "f7": F7, "f8": F8, "f9": F9, "f10": F10, "f11": F11, "f12": F12,
  }.toTable

proc parseKeyName(s: string): Button =
  if NamedKeys.hasKey(s): return NamedKeys[s]
  if s.len == 1:
    let c = s[0].toUpperAscii()
    if c in 'A'..'Z' or c in '0'..'9':
      return Button(ord(c))
  UNBOUND

proc parseCombo*(combo: string): ParsedShortcut =
  for part in combo.split('+'):
    let p = part.strip().toLowerAscii()
    case p
    of "ctrl", "control": result.ctrl = true
    of "alt": result.alt = true
    of "shift": result.shift = true
    of "super", "meta", "win": result.super = true
    of "": discard
    else: result.key = parseKeyName(p)

proc comboLabel*(combo: string): string =
  ## Ładna etykieta do wyświetlenia w UI, np. "ctrl+alt+t" -> "Ctrl+Alt+T".
  var parts: seq[string] = @[]
  for part in combo.split('+'):
    let p = part.strip()
    if p.len == 0: continue
    parts.add(p[0].toUpperAscii() & p[1 ..^ 1].toLowerAscii())
  parts.join("+")

proc matches*(s: ParsedShortcut): bool =
  ## Sprawdza, czy skrót WŁAŚNIE został wciśnięty w tej klatce
  ## (`buttonPress` -- zdarzenie "właśnie wciśnięto", nie "trzymane").
  ##
  ## NAPRAWIONY BUG (znaleziony realnym testem `xdotool` pod Xvfb --
  ## Ctrl+Alt+T w ogóle nie działało): `keyboard.ctrlKey`/`altKey` w
  ## Fidget (`fidget/opengl/base.nim`) NIE są trwałym stanem "czy modyfikator
  ## jest AKTUALNIE wciśnięty" -- są nadpisywane przy KAŻDYM zdarzeniu
  ## klawisza, niezależnie którego: `keyboard.altKey = setKey and (...)`,
  ## gdzie `setKey` to stan TEGO KONKRETNEGO zdarzenia (down/up), nie Alt.
  ## Kiedy kilka zdarzeń (Ctrl-down, Alt-down, T-down, T-up, Alt-up,
  ## Ctrl-up) trafia do jednej klatki (częste przy krótkich odstępach
  ## między zdarzeniami, zwłaszcza pod wolniejszym, programowym
  ## renderowaniem), `keyboard.altKey`/`ctrlKey` odzwierciedlają stan z
  ## OSTATNIEGO przetworzonego zdarzenia w tej klatce -- czyli zwykle
  ## "puszczono", nawet jeśli w danym momencie modyfikator faktycznie był
  ## trzymany. Naprawione: zamiast `keyboard.ctrlKey` itp. sprawdzamy
  ## wprost `buttonDown[LEFT_CONTROL] or buttonDown[RIGHT_CONTROL]` --
  ## `buttonDown` dla KONKRETNEGO klawisza jest ustawiane tylko przez
  ## zdarzenia TEGO klawisza, więc nie ma tego problemu.
  if s.key == UNBOUND: return false
  let ctrlDown = buttonDown[LEFT_CONTROL] or buttonDown[RIGHT_CONTROL]
  let altDown = buttonDown[LEFT_ALT] or buttonDown[RIGHT_ALT]
  let shiftDown = buttonDown[LEFT_SHIFT] or buttonDown[RIGHT_SHIFT]
  let superDown = buttonDown[LEFT_SUPER] or buttonDown[RIGHT_SUPER]
  if ctrlDown != s.ctrl: return false
  if altDown != s.alt: return false
  if shiftDown != s.shift: return false
  if superDown != s.super: return false
  buttonPress[s.key]

proc buttonToComboKey*(b: Button): string =
  ## Odwrotność `parseKeyName` -- krótka nazwa klawisza do zapisu w combo
  ## stringu (np. LETTER_T -> "t", TAB -> "tab").
  if ord(b) in ord(LETTER_A) .. ord(LETTER_Z) or ord(b) in ord(NUMBER_0) .. ord(NUMBER_9):
    return $chr(ord(b)).toLowerAscii()
  for k, v in NamedKeys:
    if v == b: return k
  ""

const CapturableKeys = block:
  var keys: seq[Button] = @[]
  for i in ord(LETTER_A) .. ord(LETTER_Z): keys.add(Button(i))
  for i in ord(NUMBER_0) .. ord(NUMBER_9): keys.add(Button(i))
  for k, v in NamedKeys: keys.add(v)
  keys

proc captureComboIfPressed*(): string =
  ## Do UI nagrywania skrótów w Ustawieniach: zwraca combo string, jeśli
  ## jakiś nie-modyfikatorowy klawisz został WŁAŚNIE wciśnięty w tej
  ## klatce (razem z aktualnym stanem modyfikatorów), inaczej "". Sprawdza
  ## tylko jawnie wymienione, "przechwytywalne" klawisze (litery/cyfry/
  ## nazwane) -- `Button` ma dziury w numeracji (np. LETTER_A = 65), więc
  ## iterowanie po WSZYSTKICH surowych wartościach enuma wywaliłoby się
  ## na konwersji nieprawidłowego inta z powrotem na Button.
  for b in CapturableKeys:
    if buttonPress[b]:
      var parts: seq[string] = @[]
      ## Patrz komentarz w `matches` wyżej -- `buttonDown` na konkretnych
      ## klawiszach modyfikatorów, nie `keyboard.superKey`/`ctrlKey` itp.
      if buttonDown[LEFT_SUPER] or buttonDown[RIGHT_SUPER]: parts.add("super")
      if buttonDown[LEFT_CONTROL] or buttonDown[RIGHT_CONTROL]: parts.add("ctrl")
      if buttonDown[LEFT_ALT] or buttonDown[RIGHT_ALT]: parts.add("alt")
      if buttonDown[LEFT_SHIFT] or buttonDown[RIGHT_SHIFT]: parts.add("shift")
      let keyName = buttonToComboKey(b)
      if keyName.len == 0: continue
      parts.add(keyName)
      return parts.join("+")
  ""

type
  ShortcutMap* = array[ShortcutAction, string]  ## akcja -> aktualna kombinacja (combo string)

proc loadShortcuts*(cfg: ZdeConfig): ShortcutMap =
  ## Domyślne kombinacje, nadpisane wpisami z configu (jeśli są).
  for a in ShortcutAction:
    result[a] = DefaultCombos[a]
  for sc in cfg.shortcuts:
    for a in ShortcutAction:
      if ActionNames[a] == sc.action and sc.combo.len > 0:
        result[a] = sc.combo

proc toConfigEntries*(m: ShortcutMap): seq[ShortcutConfig] =
  for a in ShortcutAction:
    if m[a] != DefaultCombos[a]:  # zapisujemy tylko odstępstwa od domyślnych -- czytelniejszy plik
      result.add(ShortcutConfig(action: ActionNames[a], combo: m[a]))

## Aktywna mapa skrótów, czytana przez `shell.nim` w każdej klatce. Żyje
## TUTAJ (nie w `shell.nim` ani `state.nim`) specjalnie, żeby uniknąć
## cyklu importów: `shell.nim` -> `launcher_apps.nim` ->
## `apps/settings/settings.nim` -- gdyby Ustawienia chciały zawołać
## `reloadShortcuts()` zdefiniowane w `shell.nim`, mielibyśmy
## `settings.nim` importujące z powrotem `shell.nim`, czyli cykl. Trzymając
## żywy stan i funkcję przeładowania w tym neutralnym module, obie strony
## (shell.nim -- do odczytu co klatkę, settings.nim -- do zapisu po
## zmianie) mogą go importować bez cyklu.
var activeShortcuts* = loadShortcuts(loadConfig())

proc reloadShortcuts*() =
  activeShortcuts = loadShortcuts(loadConfig())
