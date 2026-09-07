import std/[osproc, streams, strutils, os]

proc findClipboardTool(forCopy: bool): tuple[exe: string, args: seq[string]] =
  ## Zwraca (ścieżka do narzędzia, argumenty) dla kopiowania/wklejania,
  ## albo ("", @[]) jeśli nic odpowiedniego nie znaleziono.
  let wlCopy = findExe("wl-copy")
  let wlPaste = findExe("wl-paste")
  let xclip = findExe("xclip")
  if forCopy:
    if wlCopy.len > 0: return (wlCopy, @[])
    if xclip.len > 0: return (xclip, @["-selection", "clipboard"])
  else:
    if wlPaste.len > 0: return (wlPaste, @["-n"])  # -n: bez końcowego \n
    if xclip.len > 0: return (xclip, @["-selection", "clipboard", "-o"])
  ("", @[])

proc copyToClipboard*(text: string): bool =
  ## Kopiuje `text` do systemowego schowka. Zwraca `false`, jeśli żadne
  ## znane narzędzie (`wl-copy`/`xclip`) nie jest zainstalowane -- w takim
  ## wypadku wywołujący powinien pokazać użytkownikowi komunikat, a nie
  ## ciche niepowodzenie.
  let (exe, args) = findClipboardTool(forCopy = true)
  if exe.len == 0: return false
  try:
    var p = startProcess(exe, args = args, options = {poUsePath})
    p.inputStream.write(text)
    p.inputStream.close()
    discard p.waitForExit()
    p.close()
    result = true
  except OSError, IOError:
    result = false

proc pasteFromClipboard*(): tuple[text: string, ok: bool] =
  ## Czyta bieżącą zawartość schowka systemowego. `ok = false`, jeśli
  ## żadne znane narzędzie nie jest zainstalowane.
  let (exe, args) = findClipboardTool(forCopy = false)
  if exe.len == 0: return ("", false)
  try:
    let (output, code) = execCmdEx(exe & " " & args.join(" "))
    if code == 0:
      return (output, true)
    return ("", false)
  except OSError:
    return ("", false)
