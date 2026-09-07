import std/[os, posix, strutils]
import fidget

{.passC: "-I" & currentSourcePath().parentDir().}
{.compile: "pam_shim.c".}
{.passL: "-lpam".}

proc zdePamAuthenticate(username, password: cstring): cint
  {.importc: "zde_pam_authenticate", header: "pam_shim.h".}

type
  LockState* = ref object of RootObj
    locked*: bool
    password: string
    errorMsg: string
    checking: bool
    wasLocked: bool  ## do wykrycia PRZEJŚCIA w stan zablokowany w drawLockOverlay
                      ## (patrz komentarz przy lockScreen -- stamtąd celowo przeniesione)

var lockState* = LockState(locked: false)

proc currentUsername(): string =
  let u = getEnv("USER", "")
  if u.len > 0: return u
  getEnv("LOGNAME", "root")

proc lockScreen*() =
  ## Celowo NIE dotyka tu żadnych globali Fidget (`keyboard`/`mouse`) --
  ## `lockScreen()` bywa wołane z różnych miejsc (skrót klawiszowy, pozycja
  ## menu, przycisk), niekoniecznie w kontekście jednoznacznie bezpiecznym
  ## dla analizy GC-safety Nim. Zaobserwowane na realnym buildzie (Nim
  ## 2.2.10, ściślejsza weryfikacja niż w środowisku deweloperskim): jawne
  ## dotknięcie `keyboard.focusNode` w tym miejscu dawało twardy błąd
  ## kompilacji "'lockScreen' is not GC-safe as it accesses 'keyboard'".
  ## Zamiast siłować się z pragmami (`{.gcsafe.}` to obietnica, którą Nim
  ## i tak weryfikuje, jeśli jest jawna -- wymuszenie jej tutaj nie
  ## pomaga, skoro obietnica faktycznie nie daje się udowodnić), po prostu
  ## przenosimy dotknięcie `keyboard` do `drawLockOverlay` niżej -- ten kod
  ## i tak wykonuje się co klatkę w normalnym kontekście rysowania Fidget,
  ## razem z resztą kodu dotykającego tych samych globali bez żadnych
  ## problemów. `wasLocked` wykrywa PRZEJŚCIE w stan zablokowany, żeby
  ## zwolnić fokus dokładnie raz, przy pierwszej klatce blokady.
  lockState.locked = true
  lockState.password = ""
  lockState.errorMsg = ""

proc attemptUnlock(ls: LockState) =
  let user = currentUsername()
  ls.checking = true
  ## Uwierzytelnienie PAM to jednorazowe, wyzwolone naciśnięciem Enter
  ## wywołanie (nie coś wołane co klatkę z `tick()`) -- ta sama
  ## kategoria "krótkie, akceptowalne zablokowanie UI na akcję
  ## użytkownika" co `shell/clipboard.nim`. `pam_authenticate` zwykle
  ## kończy się w pojedynczych milisekundach do dziesiątek milisekund.
  if zdePamAuthenticate(user.cstring, ls.password.cstring) == 1:
    ls.locked = false
    ls.password = ""
    ls.errorMsg = ""
  else:
    ls.errorMsg = "Błędne hasło (albo brak uprawnień PAM w tym środowisku -- patrz komentarz w pam_shim.c)"
    ls.password = ""
    keyboard.input = ""
  ls.checking = false

proc pidFilePath(): string =
  let rt = getEnv("XDG_RUNTIME_DIR", "")
  (if rt.len > 0: rt else: "/tmp") / "zde-comp.pid"

proc logout*() {.gcsafe, locks: 0.} =
  ## Best-effort: powiadom zde-comp (jeśli działa) i zakończ zde-shell.
  let p = pidFilePath()
  if fileExists(p):
    try:
      let pid = Pid(parseInt(readFile(p).strip()))
      discard kill(pid, SIGTERM)
    except ValueError, IOError:
      discard
  quit(0)

proc drawLockOverlay*(ls: LockState, clockText: string) =
  if not ls.locked:
    ls.wasLocked = false
    return
  if not ls.wasLocked:
    ## Pierwsza klatka blokady -- zwolnij fokus, żeby żadne pole (np.
    ## edytowalny pasek ścieżki w otwartym oknie edytora pod spodem) nie
    ## łapało wpisywanego hasła. Patrz duży komentarz w `lockScreen`
    ## wyżej o tym, dlaczego to tutaj, nie w `lockScreen` samym.
    keyboard.focusNode = nil
    ls.wasLocked = true
  let w = windowSize.x
  let h = windowSize.y

  frame "lock-overlay":
    box 0, 0, w, h
    fill "#0a0c10"

    group "lock-card":
      box w / 2 - 160, h / 2 - 110, 320, 220
      cornerRadius 10
      fill "#161b22"
      stroke "#2a323f"
      strokeWeight 1

      text "lock-icon":
        box 0, 24, 320, 40
        font "sans-serif", 28, 400, 40, hCenter, vCenter
        fill "#8a94a3"
        characters "🔒"

      text "lock-user":
        box 0, 66, 320, 24
        font "sans-serif", 13, 600, 24, hCenter, vCenter
        fill "#e8ecf0"
        characters currentUsername()

      group "lock-pw-field":
        box 30, 100, 260, 34
        cornerRadius 6
        fill "#0d1117"
        stroke "#333b45"
        strokeWeight 1

        text "lock-pw-dots":
          box 12, 0, 236, 34
          font "monospace", 16, 400, 34, hLeft, vCenter
          fill "#e8ecf0"
          characters "•".repeat(ls.password.len)

        ## Niewidoczne pole edytowalne nałożone na wyświetlacz kropek --
        ## łapie fokus klawiatury i realny tekst (`keyboard.input`), ale
        ## nigdy nie pokazuje go wprost (fill alpha 0) -- kropki wyżej są
        ## jedynym widocznym efektem, tak jak w każdym normalnym polu
        ## hasła.
        text "lock-pw-input":
          box 12, 0, 236, 34
          font "monospace", 16, 400, 34, hLeft, vCenter
          fill "#e8ecf0", 0.0
          editableText true
          if not current.hasKeyboardFocus():
            characters ls.password
          onClick:
            keyboard.focus(current)
          onInput:
            if buttonPress[ENTER]:
              ls.password = keyboard.input
              attemptUnlock(ls)
              keyboard.input = ls.password
            else:
              ls.password = keyboard.input

      if ls.errorMsg.len > 0:
        text "lock-error":
          box 20, 144, 280, 32
          font "sans-serif", 10, 400, 14, hCenter, vTop
          fill "#e5666b"
          characters ls.errorMsg
      else:
        text "lock-hint":
          box 20, 148, 280, 20
          font "sans-serif", 10, 400, 14, hCenter, vTop
          fill "#6d7684"
          characters "Wpisz hasło i naciśnij Enter"

    text "lock-clock":
      box 0, h / 2 - 200, w, 60
      font "sans-serif", 42, 300, 60, hCenter, vCenter
      fill "#e8ecf0"
      characters clockText
