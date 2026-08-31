import std/os
import fidget
import ../../comp/comp

type
  EditorState* = ref object of RootObj
    path*: string          ## ścieżka do pliku (edytowalna w pasku na górze)
    content*: string        ## treść dokumentu w edytorze
    statusMsg*: string       ## komunikat po Otwórz/Zapisz (sukces/błąd)
    dirty*: bool             ## czy są niezapisane zmiany

proc newEditorState*(startPath = ""): EditorState =
  result = EditorState(path: startPath, content: "", statusMsg: "", dirty: false)
  if startPath.len > 0 and fileExists(startPath):
    try:
      result.content = readFile(startPath)
      result.statusMsg = "Wczytano " & startPath
    except IOError as e:
      result.statusMsg = "Błąd wczytywania: " & e.msg

proc doOpen(es: EditorState) =
  if es.path.len == 0:
    es.statusMsg = "Podaj ścieżkę pliku do otwarcia."
    return
  try:
    es.content = readFile(es.path)
    es.statusMsg = "Wczytano " & es.path
    es.dirty = false
  except IOError as e:
    es.statusMsg = "Błąd wczytywania: " & e.msg

proc doSave(es: EditorState) =
  if es.path.len == 0:
    es.statusMsg = "Podaj ścieżkę pliku do zapisu."
    return
  try:
    writeFile(es.path, es.content)
    es.statusMsg = "Zapisano " & es.path
    es.dirty = false
  except IOError as e:
    es.statusMsg = "Błąd zapisu: " & e.msg

proc drawEditor*(es: EditorState, win: ZdeWindow) =
  let toolbarH = 34.0'f32
  let statusH = 22.0'f32
  let pad = 6.0'f32

  frame "editor-root":
    box 0, 0, win.size.x, win.size.y
    fill "#14171c"

    # -- pasek ścieżki + przyciski --------------------------------------------
    group "toolbar":
      box 0, 0, win.size.x, toolbarH
      fill "#1b2027"

      text "path-field":
        box pad, 4, win.size.x - 170, toolbarH - 8
        font "monospace", 12, 400, toolbarH - 8, hLeft, vCenter
        fill "#e8ecf0"
        editableText true
        selectable true
        if not current.hasKeyboardFocus():
          characters (if es.path.len > 0: es.path else: "/ścieżka/do/pliku.txt")
        onClick:
          keyboard.focus(current)
        onInput:
          es.path = keyboard.input

      group "btn-open":
        box win.size.x - 160, 4, 74, toolbarH - 8
        cornerRadius 4
        fill "#2a2f36"
        onHover: fill "#3a424d"
        onClick: doOpen(es)
        text "btn-open-label":
          box 0, 0, 74, toolbarH - 8
          font "sans-serif", 12, 600, toolbarH - 8, hCenter, vCenter
          fill "#e8ecf0"
          characters "Otwórz"

      group "btn-save":
        box win.size.x - 80, 4, 74, toolbarH - 8
        cornerRadius 4
        fill "#2d5f8a"
        onHover: fill "#3a72a3"
        onClick: doSave(es)
        text "btn-save-label":
          box 0, 0, 74, toolbarH - 8
          font "sans-serif", 12, 600, toolbarH - 8, hCenter, vCenter
          fill "#ffffff"
          characters "Zapisz"

    # -- obszar edycji ---------------------------------------------------------
    group "editor-area":
      box 0, toolbarH, win.size.x, win.size.y - toolbarH - statusH
      fill "#101318"
      clipContent true

      text "content":
        box pad, pad, win.size.x - pad * 2, win.size.y - toolbarH - statusH - pad * 2
        font "monospace", 13, 400, 19, hLeft, vTop
        fill "#dbe1e8"
        multiline true
        selectable true
        editableText true
        if not current.hasKeyboardFocus():
          characters es.content
        onClick:
          keyboard.focus(current)
        onInput:
          if es.content != keyboard.input:
            es.content = keyboard.input
            es.dirty = true

    # -- pasek statusu ------------------------------------------------------
    group "status-bar":
      box 0, win.size.y - statusH, win.size.x, statusH
      fill "#1b2027"
      text "status-label":
        box pad, 0, win.size.x - pad * 2, statusH
        font "sans-serif", 11, 400, statusH, hLeft, vCenter
        fill (if es.dirty: "#e0a850" else: "#8a94a3")
        characters (if es.dirty: "● niezapisane zmiany -- " & es.statusMsg else: es.statusMsg)
