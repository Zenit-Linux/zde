import std/[osproc, streams, strutils, os, strtabs]
import fidget
import ../../comp/comp

type
  TerminalState* = ref object of RootObj
    process: Process
    buffer*: seq[string]      ## scrollback, jedna linia = jeden element
    input*: string            ## bieżąco wpisywana linia
    scrollOffset*: int        ## 0 = na dole (najnowsze), rośnie w górę
    cwd*: string
    alive*: bool

const
  MaxScrollback = 4000
  PromptLabel = "zde$ "

proc appendLine(t: TerminalState, line: string) =
  t.buffer.add(line)
  if t.buffer.len > MaxScrollback:
    let overflow = t.buffer.len - MaxScrollback
    t.buffer = t.buffer[overflow ..^ 1]
  t.scrollOffset = 0  # nowa treść zawsze przewija na sam dół

proc newTerminal*(): TerminalState =
  result = TerminalState(
    buffer: @[],
    input: "",
    scrollOffset: 0,
    cwd: getHomeDir(),
    alive: false,
  )
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["TERM"] = "dumb"      # wyłącza kody ANSI w wielu narzędziach
  env["PS1"] = ""           # i tak nie mamy tty, więc bashowy prompt jest zbędny

  try:
    result.process = startProcess(
      command = "/bin/bash",
      args = @["--norc", "--noprofile", "-i"],
      workingDir = result.cwd,
      env = env,
      options = {poUsePath, poStdErrToStdOut},
    )
    result.alive = true
    result.buffer.add("Zenit Desktop Environment -- wbudowany terminal (bash, bez pty)")
    result.buffer.add("Katalog startowy: " & result.cwd)
    result.buffer.add("")
  except OSError as e:
    result.alive = false
    result.buffer.add("Nie udało się uruchomić /bin/bash: " & e.msg)

proc pollOutput*(t: TerminalState) =
  ## Wołane co klatkę z pętli `tick` shellu -- nie blokuje, jeśli proces
  ## nie ma nic do powiedzenia.
  if not t.alive or t.process.isNil: return
  if not t.process.running:
    if t.alive:
      t.alive = false
      appendLine(t, "")
      appendLine(t, "[proces zakończony, kod: " & $t.process.peekExitCode & "]")
    return

  let outp = t.process.outputStream
  var readAny = false
  while t.process.hasData:
    var line = ""
    if outp.readLine(line):
      appendLine(t, line)
      readAny = true
    else:
      break
  if not readAny:
    discard  # nic nowego w tej klatce, nie ma sprawy

proc sendLine*(t: TerminalState, line: string) =
  appendLine(t, PromptLabel & line)
  if not t.alive or t.process.isNil:
    appendLine(t, "(powłoka nie działa -- nie ma do kogo wysłać polecenia)")
    return
  try:
    let inp = t.process.inputStream
    inp.writeLine(line)
    inp.flush()
  except IOError as e:
    appendLine(t, "Błąd zapisu do powłoki: " & e.msg)

proc close*(t: TerminalState) =
  if not t.process.isNil:
    try:
      if t.process.running:
        t.process.terminate()
      t.process.close()
    except OSError:
      discard

# --- Rysowanie ------------------------------------------------------------

proc drawTerminal*(t: TerminalState, win: ZdeWindow) =
  let lineH = 18.0'f32
  let inputH = 28.0'f32
  let pad = 8.0'f32
  let bodyH = win.size.y - inputH - pad * 3
  let visibleLines = max(1, int(bodyH / lineH))

  frame "term-root":
    box 0, 0, win.size.x, win.size.y
    fill "#101418"

    group "scrollback":
      box pad, pad, win.size.x - pad * 2, bodyH
      clipContent true

      onHover:
        if mouse.wheelDelta != 0:
          t.scrollOffset = clamp(
            t.scrollOffset - int(mouse.wheelDelta),
            0,
            max(0, t.buffer.len - visibleLines),
          )

      let total = t.buffer.len
      let lastIdx = max(0, total - t.scrollOffset)
      let firstIdx = max(0, lastIdx - visibleLines)
      var y = 0.0'f32
      for i in firstIdx ..< lastIdx:
        text "line" & $i:
          box 0, y, win.size.x - pad * 2, lineH
          font "monospace", 13, 400, lineH, hLeft, vTop
          fill "#d6dbe0"
          characters t.buffer[i]
        y += lineH

    group "input-row":
      box pad, win.size.y - inputH - pad, win.size.x - pad * 2, inputH
      fill "#1a2027"
      cornerRadius 4

      text "prompt":
        box 8, 0, 60, inputH
        font "monospace", 13, 700, inputH, hLeft, vCenter
        fill "#5fd7a7"
        characters PromptLabel

      text "input-field":
        box 60, 0, win.size.x - pad * 2 - 68, inputH
        font "monospace", 13, 400, inputH, hLeft, vCenter
        fill "#ffffff"
        editableText true
        selectable true
        if not current.hasKeyboardFocus():
          characters t.input
        onClick:
          keyboard.focus(current)
        onInput:
          if buttonPress[ENTER]:
            let cmd = t.input
            t.input = ""
            keyboard.input = ""
            if cmd.strip().len > 0:
              sendLine(t, cmd)
          else:
            t.input = keyboard.input
