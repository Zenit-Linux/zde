import std/[os, strutils]
import fidget
import ../../comp/comp
import ../../shell/clipboard
import highlight

type
  Tab = ref object
    path: string
    content: string
    statusMsg: string
    dirty: bool
    scrollOffset: int
    wasEditing: bool

  EditorState* = ref object of RootObj
    tabs: seq[Tab]
    activeTab: int

const
  ApproxCharW = 7.6'f32
  LineH = 19.0'f32
  TabBarH = 30.0'f32
  TabW = 150.0'f32

proc newTab(startPath = ""): Tab =
  result = Tab(path: startPath, content: "", statusMsg: "", dirty: false)
  if startPath.len > 0 and fileExists(startPath):
    try:
      result.content = readFile(startPath)
      result.statusMsg = "Wczytano " & startPath
    except IOError as e:
      result.statusMsg = "Błąd wczytywania: " & e.msg

proc newEditorState*(startPath = ""): EditorState =
  EditorState(tabs: @[newTab(startPath)], activeTab: 0)

proc active(es: EditorState): Tab = es.tabs[es.activeTab]

proc switchTab(es: EditorState, i: int) =
  if i >= 0 and i < es.tabs.len:
    es.activeTab = i
    keyboard.focusNode = nil  # patrz uwaga na górze pliku

proc addTab(es: EditorState) =
  es.tabs.add(newTab())
  switchTab(es, es.tabs.len - 1)

proc closeTab(es: EditorState, i: int) =
  if i < 0 or i >= es.tabs.len: return
  es.tabs.delete(i)
  if es.tabs.len == 0:
    es.tabs.add(newTab())
  if es.activeTab >= es.tabs.len:
    es.activeTab = es.tabs.len - 1
  keyboard.focusNode = nil

proc doOpen(t: Tab) =
  if t.path.len == 0:
    t.statusMsg = "Podaj ścieżkę pliku do otwarcia."
    return
  try:
    t.content = readFile(t.path)
    t.statusMsg = "Wczytano " & t.path
    t.dirty = false
    t.scrollOffset = 0
    keyboard.focusNode = nil
  except IOError as e:
    t.statusMsg = "Błąd wczytywania: " & e.msg

proc doSave(t: Tab) =
  if t.path.len == 0:
    t.statusMsg = "Podaj ścieżkę pliku do zapisu."
    return
  try:
    writeFile(t.path, t.content)
    t.statusMsg = "Zapisano " & t.path
    t.dirty = false
  except IOError as e:
    t.statusMsg = "Błąd zapisu: " & e.msg

proc tabLabel(t: Tab): string =
  if t.path.len == 0: "bez nazwy"
  else: t.path.extractFilename()

proc drawHighlighted(t: Tab, x, y, w, h: float32) =
  let lang = languageFor(t.path)
  let lines = t.content.splitLines()
  let visibleLines = max(1, int(h / LineH))
  t.scrollOffset = clamp(t.scrollOffset, 0, max(0, lines.len - visibleLines))
  let first = t.scrollOffset
  let last = min(lines.len, first + visibleLines)

  var state = LineState()
  for i in 0 ..< first:
    if i < lines.len:
      discard tokenizeLine(lines[i], lang, state)

  var ly = y
  for i in first ..< last:
    let tokens = tokenizeLine(lines[i], lang, state)
    var lx = x
    for j, tok in tokens:
      text "hl-" & $i & "-" & $j:
        box lx, ly, w - (lx - x), LineH
        font "monospace", 13, 400, LineH, hLeft, vTop
        fill colorFor(tok.kind)
        characters tok.text
      lx += float32(tok.text.len) * ApproxCharW
    ly += LineH

proc drawTabBar(es: EditorState, w: float32) =
  group "tab-bar":
    box 0, 0, w, TabBarH
    fill "#12151a"

    var tx = 0.0'f32
    for i, t in es.tabs:
      let isActive = i == es.activeTab
      group "tab-" & $i:
        box tx, 0, TabW, TabBarH
        fill (if isActive: "#1b2027" else: "#12151a")
        onHover:
          if not isActive: fill "#181c22"
        onClick:
          switchTab(es, i)

        text "tab-label-" & $i:
          box 10, 0, TabW - 30, TabBarH
          font "sans-serif", 11, (if isActive: 600 else: 400), TabBarH, hLeft, vCenter
          fill (if t.dirty: "#e0a850" elif isActive: "#e8ecf0" else: "#8a94a3")
          characters (if t.dirty: "● " & tabLabel(t) else: tabLabel(t))

        if es.tabs.len > 1:
          group "tab-close-" & $i:
            box TabW - 22, 6, 18, 18
            cornerRadius 3
            fill "#000000", 0.0
            onHover: fill "#3a1f24", 1.0
            onClick:
              closeTab(es, i)
            text "tab-close-x-" & $i:
              box 0, 0, 18, 18
              font "sans-serif", 12, 400, 18, hCenter, vCenter
              fill "#aeb6c2"
              characters "×"
      tx += TabW

    group "tab-add":
      box tx, 4, 22, 22
      cornerRadius 4
      fill "#2a2f36"
      onHover: fill "#3a424d"
      onClick:
        addTab(es)
      text "tab-add-label":
        box 0, 0, 22, 22
        font "sans-serif", 14, 600, 22, hCenter, vCenter
        fill "#e8ecf0"
        characters "+"

proc drawEditor*(es: EditorState, win: ZdeWindow) =
  let toolbarH = 34.0'f32
  let statusH = 22.0'f32
  let pad = 6.0'f32
  let t = es.active()

  frame "editor-root":
    box 0, 0, win.size.x, win.size.y
    fill "#14171c"

    drawTabBar(es, win.size.x)

    # -- pasek ścieżki + przyciski --------------------------------------------
    group "toolbar":
      box 0, TabBarH, win.size.x, toolbarH
      fill "#1b2027"

      text "path-field":
        box pad, 4, win.size.x - 300, toolbarH - 8
        font "monospace", 12, 400, toolbarH - 8, hLeft, vCenter
        fill "#e8ecf0"
        editableText true
        selectable true
        if not current.hasKeyboardFocus():
          characters (if t.path.len > 0: t.path else: "/ścieżka/do/pliku.txt")
        onClick:
          keyboard.focus(current)
        onInput:
          t.path = keyboard.input

      group "btn-open":
        box win.size.x - 290, 4, 64, toolbarH - 8
        cornerRadius 4
        fill "#2a2f36"
        onHover: fill "#3a424d"
        onClick:
          doOpen(t)
        text "btn-open-label":
          box 0, 0, 64, toolbarH - 8
          font "sans-serif", 11, 600, toolbarH - 8, hCenter, vCenter
          fill "#e8ecf0"
          characters "Otwórz"

      group "btn-save":
        box win.size.x - 220, 4, 64, toolbarH - 8
        cornerRadius 4
        fill "#2d5f8a"
        onHover: fill "#3a72a3"
        onClick:
          doSave(t)
          keyboard.focusNode = nil  # patrz komentarz przy "editor-area" niżej
        text "btn-save-label":
          box 0, 0, 64, toolbarH - 8
          font "sans-serif", 11, 600, toolbarH - 8, hCenter, vCenter
          fill "#ffffff"
          characters "Zapisz"

      group "btn-copy":
        box win.size.x - 150, 4, 64, toolbarH - 8
        cornerRadius 4
        fill "#1f2530"
        onHover: fill "#2a323f"
        onClick:
          ## NAPRAWIONY BRAK: kopiowanie/wklejanie POJEDYNCZYCH znaków w
          ## polu edycji już działało (Ctrl+C/Ctrl+V, wbudowane w Fidget --
          ## patrz `fidget/opengl/base.nim`), ale nie było jednoklikowego
          ## sposobu na skopiowanie CAŁEJ zawartości pliku do schowka
          ## systemowego. Patrz `shell/clipboard.nim`.
          if copyToClipboard(t.content):
            t.statusMsg = "Skopiowano całą zawartość do schowka"
          else:
            t.statusMsg = "Brak wl-copy/xclip -- nie można skopiować do schowka systemowego"
          keyboard.focusNode = nil
        text "btn-copy-label":
          box 0, 0, 64, toolbarH - 8
          font "sans-serif", 11, 600, toolbarH - 8, hCenter, vCenter
          fill "#dbe1e8"
          characters "Kopiuj"

      group "btn-paste":
        box win.size.x - 80, 4, 64, toolbarH - 8
        cornerRadius 4
        fill "#1f2530"
        onHover: fill "#2a323f"
        onClick:
          let (text, ok) = pasteFromClipboard()
          if ok:
            t.content.add(text)
            t.dirty = true
            t.statusMsg = "Wklejono ze schowka na koniec dokumentu"
          else:
            t.statusMsg = "Brak wl-paste/xclip -- nie można wkleić ze schowka systemowego"
          keyboard.focusNode = nil
        text "btn-paste-label":
          box 0, 0, 64, toolbarH - 8
          font "sans-serif", 11, 600, toolbarH - 8, hCenter, vCenter
          fill "#dbe1e8"
          characters "Wklej"

    # -- obszar edycji ---------------------------------------------------------
    let areaY = TabBarH + toolbarH
    let areaH = win.size.y - areaY - statusH
    group "editor-area":
      box 0, areaY, win.size.x, areaH
      fill "#101318"
      clipContent true

      ## NAPRAWIONY BRAK (scroll): `mouse.wheelDelta`, którego używamy
      ## niżej, jest ustawiane przez Fidget TYLKO gdy żadne pole tekstowe
      ## nie ma fokusu klawiatury -- patrz `onScroll` w
      ## `fidget/opengl/base.nim`. Klikanie w tło obszaru edycji (poza
      ## samym polem `content-edit`) zwalnia fokus, żeby scroll znów
      ## trafiał tam, gdzie użytkownik faktycznie najechał myszą.
      onClick:
        keyboard.focusNode = nil

      onHover:
        if mouse.wheelDelta != 0 and not t.wasEditing:
          t.scrollOffset = max(0, t.scrollOffset - int(mouse.wheelDelta))

      var isEditingNow = false
      text "content-edit":
        box pad, pad, win.size.x - pad * 2, areaH - pad * 2
        font "monospace", 13, 400, LineH, hLeft, vTop
        multiline true
        selectable true
        editableText true
        isEditingNow = current.hasKeyboardFocus()
        fill "#dbe1e8", (if isEditingNow: 1.0 else: 0.0)
        if not isEditingNow:
          characters t.content
        onClick:
          keyboard.focus(current)
        onInput:
          if t.content != keyboard.input:
            t.content = keyboard.input
            t.dirty = true
      t.wasEditing = isEditingNow

      if not isEditingNow:
        drawHighlighted(t, pad, pad, win.size.x - pad * 2, areaH - pad * 2)

    # -- pasek statusu ------------------------------------------------------
    group "status-bar":
      box 0, win.size.y - statusH, win.size.x, statusH
      fill "#1b2027"
      text "status-label":
        box pad, 0, win.size.x - pad * 2, statusH
        font "sans-serif", 11, 400, statusH, hLeft, vCenter
        fill (if t.dirty: "#e0a850" else: "#8a94a3")
        characters (if t.dirty: "● niezapisane zmiany -- " & t.statusMsg else: t.statusMsg)
