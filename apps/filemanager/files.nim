import std/[os, algorithm, strutils, strformat, times]
import fidget
import ../../comp/comp

type
  EntryKind = enum ekDir, ekFile

  Entry = object
    name: string
    kind: EntryKind
    size: BiggestInt
    modified: Time

  FilesState* = ref object of RootObj
    cwd*: string
    entries: seq[Entry]
    selected: string
    lastClickTime: float
    lastClickName: string
    errorMsg: string

proc humanSize(bytes: BiggestInt): string =
  const units = ["B", "KB", "MB", "GB", "TB"]
  var size = bytes.float
  var unit = 0
  while size >= 1024.0 and unit < units.high:
    size /= 1024.0
    inc unit
  if unit == 0:
    result = &"{bytes} {units[unit]}"
  else:
    result = &"{size:.1f} {units[unit]}"

proc refresh(fs: FilesState) =
  fs.entries.setLen(0)
  fs.errorMsg = ""
  try:
    for kind, path in walkDir(fs.cwd):
      let name = extractFilename(path)
      if name.len == 0: continue
      case kind
      of pcDir, pcLinkToDir:
        fs.entries.add(Entry(name: name, kind: ekDir, size: 0))
      of pcFile, pcLinkToFile:
        var sz: BiggestInt = 0
        var mt: Time
        try:
          sz = getFileSize(path)
          mt = getLastModificationTime(path)
        except OSError:
          discard
        fs.entries.add(Entry(name: name, kind: ekFile, size: sz, modified: mt))
    fs.entries.sort(proc(a, b: Entry): int =
      if a.kind != b.kind:
        return (if a.kind == ekDir: -1 else: 1)
      cmp(a.name.toLowerAscii, b.name.toLowerAscii)
    )
  except OSError as e:
    fs.errorMsg = "Nie można odczytać katalogu: " & e.msg

proc newFileManager*(startDir = getHomeDir()): FilesState =
  result = FilesState(
    cwd: startDir.absolutePath().normalizedPath(),
    entries: @[],
    selected: "",
    lastClickTime: 0.0,
    lastClickName: "",
  )
  refresh(result)

proc navigateTo(fs: FilesState, path: string) =
  let normalized = path.absolutePath().normalizedPath()
  if dirExists(normalized):
    fs.cwd = normalized
    fs.selected = ""
    refresh(fs)

proc navigateUp(fs: FilesState) =
  let parent = parentDir(fs.cwd)
  if parent.len > 0:
    navigateTo(fs, parent)

proc breadcrumbParts(fs: FilesState): seq[tuple[label, path: string]] =
  ## Rozbija bieżącą ścieżkę na klikalne segmenty: / , home , user , docs...
  result = @[("/", "/")]
  var acc = ""
  for part in fs.cwd.split(DirSep):
    if part.len == 0: continue
    acc.add(DirSep & part)
    result.add((part, acc))

# --- Rysowanie ------------------------------------------------------------

proc drawFileManager*(fs: FilesState, win: ZdeWindow) =
  let toolbarH = 32.0'f32
  let breadcrumbH = 26.0'f32
  let rowH = 24.0'f32
  let pad = 6.0'f32

  frame "files-root":
    box 0, 0, win.size.x, win.size.y
    fill "#15181c"

    # Pasek narzędzi: "w górę" + odśwież
    group "toolbar":
      box 0, 0, win.size.x, toolbarH
      fill "#1d2126"

      group "up-btn":
        box pad, 4, 64, toolbarH - 8
        fill "#2a2f36"
        cornerRadius 4
        onHover: fill "#3a4048"
        onClick: navigateUp(fs)
        text "up-label":
          box 0, 0, 64, toolbarH - 8
          font "sans-serif", 12, 600, toolbarH - 8, hCenter, vCenter
          fill "#e6e6e6"
          characters "⬆ Wyżej"

      group "refresh-btn":
        box pad * 2 + 64, 4, 90, toolbarH - 8
        fill "#2a2f36"
        cornerRadius 4
        onHover: fill "#3a4048"
        onClick: refresh(fs)
        text "refresh-label":
          box 0, 0, 90, toolbarH - 8
          font "sans-serif", 12, 600, toolbarH - 8, hCenter, vCenter
          fill "#e6e6e6"
          characters "⟳ Odśwież"

    # Breadcrumb ze ścieżką
    group "breadcrumb":
      box 0, toolbarH, win.size.x, breadcrumbH
      fill "#181b1f"
      clipContent true
      var x = pad
      for part in breadcrumbParts(fs):
        let w = float32(part.label.len * 8 + 14)
        group "crumb-" & part.path:
          box x, 2, w, breadcrumbH - 4
          onHover: fill "#232830"
          onClick: navigateTo(fs, part.path)
          text "crumb-label-" & part.path:
            box 0, 0, w, breadcrumbH - 4
            font "sans-serif", 12, 500, breadcrumbH - 4, hCenter, vCenter
            fill "#8fb8ff"
            characters part.label
        x += w + 2

    # Lista plików
    group "listing":
      box 0, toolbarH + breadcrumbH, win.size.x, win.size.y - toolbarH - breadcrumbH
      clipContent true

      if fs.errorMsg.len > 0:
        text "err":
          box pad, pad, win.size.x - pad * 2, 40
          font "sans-serif", 12, 400, 18, hLeft, vTop
          fill "#ff8080"
          characters fs.errorMsg
      elif fs.entries.len == 0:
        text "empty":
          box pad, pad, win.size.x - pad * 2, 20
          font "sans-serif", 12, 400, 18, hLeft, vTop
          fill "#8a8f96"
          characters "(pusty katalog)"
      else:
        var y = 0.0'f32
        for entry in fs.entries:
          let isSelected = entry.name == fs.selected
          group "row-" & entry.name:
            box 0, y, win.size.x, rowH
            fill (if isSelected: "#2d5f8a" else: "#000000")
            onHover:
              if not isSelected:
                fill "#20262d"
            onClick:
              fs.selected = entry.name
              if entry.kind == ekDir:
                navigateTo(fs, fs.cwd / entry.name)

            text "icon-" & entry.name:
              box pad, 0, 20, rowH
              font "sans-serif", 13, 400, rowH, hLeft, vCenter
              fill (if entry.kind == ekDir: "#ffcc66" else: "#9fb4c7")
              characters (if entry.kind == ekDir: "📁" else: "📄")

            text "name-" & entry.name:
              box pad + 24, 0, win.size.x - 160, rowH
              font "sans-serif", 13, 400, rowH, hLeft, vCenter
              fill "#e6e6e6"
              characters entry.name

            if entry.kind == ekFile:
              text "size-" & entry.name:
                box win.size.x - 120, 0, 110, rowH
                font "sans-serif", 12, 400, rowH, hRight, vCenter
                fill "#8a8f96"
                characters humanSize(entry.size)

          y += rowH
