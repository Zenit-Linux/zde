import std/[strutils, tables]

type
  TokenKind* = enum
    tkPlain, tkKeyword, tkString, tkComment, tkNumber, tkType

  Token* = object
    text*: string
    kind*: TokenKind

  Language* = enum
    langNim, langPython, langC, langJs, langShell, langGeneric

  LineState* = object
    ## Stan przenoszony między liniami -- komentarz blokowy albo potrójny
    ## łańcuch mogą rozciągać się na wiele linii.
    inBlockComment*: bool
    inTripleString*: bool

proc wordSet(items: openArray[string]): Table[string, bool] =
  ## Mała lokalna zamiana za `std/sets` -- unikamy dodatkowej zależności dla
  ## czegoś tak prostego jak "czy string jest w zbiorze słów kluczowych".
  result = initTable[string, bool]()
  for it in items: result[it] = true

const
  KeywordsNim = wordSet([
    "proc", "func", "template", "macro", "iterator", "converter", "method",
    "type", "object", "ref", "ptr", "var", "let", "const", "import", "export",
    "from", "include", "when", "if", "elif", "else", "case", "of", "while",
    "for", "in", "block", "break", "continue", "return", "yield", "discard",
    "try", "except", "finally", "raise", "defer", "and", "or", "not", "xor",
    "div", "mod", "shl", "shr", "true", "false", "nil", "result", "new",
    "asm", "bind", "concept", "do", "mixin", "static", "tuple", "enum",
    "distinct", "addr", "cast", "as", "is", "isnot", "out",
  ])
  KeywordsPython = wordSet([
    "def", "class", "import", "from", "as", "if", "elif", "else", "while",
    "for", "in", "not", "and", "or", "is", "return", "yield", "break",
    "continue", "pass", "try", "except", "finally", "raise", "with", "lambda",
    "global", "nonlocal", "assert", "del", "True", "False", "None", "self",
    "async", "await",
  ])
  KeywordsC = wordSet([
    "int", "char", "float", "double", "void", "long", "short", "unsigned",
    "signed", "struct", "union", "enum", "typedef", "static", "const",
    "extern", "sizeof", "if", "else", "while", "for", "do", "switch", "case",
    "default", "break", "continue", "return", "goto", "auto", "register",
    "volatile", "inline", "NULL", "true", "false",
  ])
  KeywordsJs = wordSet([
    "function", "var", "let", "const", "if", "else", "while", "for", "of",
    "in", "return", "break", "continue", "switch", "case", "default", "try",
    "catch", "finally", "throw", "new", "delete", "typeof", "instanceof",
    "class", "extends", "super", "this", "import", "export", "from", "as",
    "async", "await", "yield", "true", "false", "null", "undefined",
  ])
  KeywordsShell = wordSet([
    "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case",
    "esac", "function", "return", "local", "export", "in", "break",
    "continue", "echo", "exit",
  ])

proc languageFor*(path: string): Language =
  let ext = path.toLowerAscii().rsplit('.', maxsplit = 1)
  if ext.len < 2: return langGeneric
  case ext[1]
  of "nim", "nims", "nimble": langNim
  of "py", "pyw": langPython
  of "c", "h", "cpp", "cc", "cxx", "hpp": langC
  of "js", "ts", "jsx", "tsx", "mjs": langJs
  of "sh", "bash", "zsh": langShell
  else: langGeneric

proc keywordsFor(lang: Language): Table[string, bool] =
  case lang
  of langNim: KeywordsNim
  of langPython: KeywordsPython
  of langC: KeywordsC
  of langJs: KeywordsJs
  of langShell: KeywordsShell
  of langGeneric: initTable[string, bool]()

proc lineCommentFor(lang: Language): string =
  case lang
  of langNim, langPython, langShell, langGeneric: "#"
  of langC, langJs: "//"

proc supportsBlockComment(lang: Language): bool =
  lang in {langC, langJs}

proc supportsTripleString(lang: Language): bool =
  lang == langNim or lang == langPython

proc isIdentStart(c: char): bool = c.isAlphaAscii() or c == '_'
proc isIdentChar(c: char): bool = c.isAlphaNumeric() or c == '_'

proc tokenizeLine*(line: string, lang: Language, state: var LineState): seq[Token] =
  ## Tokenizuje POJEDYNCZĄ linię, uwzględniając i aktualizując stan
  ## przenoszony z poprzedniej linii (komentarz blokowy / potrójny string).
  result = @[]
  let kw = keywordsFor(lang)
  let lineComment = lineCommentFor(lang)
  var i = 0
  let n = line.len

  template emit(txt: string, k: TokenKind) =
    if txt.len > 0:
      result.add(Token(text: txt, kind: k))

  # -- kontynuacja komentarza blokowego z poprzedniej linii ------------------
  if state.inBlockComment:
    let endIdx = line.find("*/")
    if endIdx == -1:
      emit(line, tkComment)
      return
    else:
      emit(line[0 .. endIdx + 1], tkComment)
      i = endIdx + 2
      state.inBlockComment = false

  # -- kontynuacja potrójnego stringa z poprzedniej linii --------------------
  if state.inTripleString:
    let endIdx = line.find("\"\"\"")
    if endIdx == -1:
      emit(line[i .. ^1], tkString)
      return
    else:
      emit(line[i .. endIdx + 2], tkString)
      i = endIdx + 3
      state.inTripleString = false

  while i < n:
    let c = line[i]

    # komentarz liniowy -- reszta linii
    if lineComment.len > 0 and i + lineComment.len <= n and
       line[i ..< i + lineComment.len] == lineComment:
      emit(line[i .. ^1], tkComment)
      break

    # komentarz blokowy /* ... */
    if supportsBlockComment(lang) and c == '/' and i + 1 < n and line[i+1] == '*':
      let endIdx = line.find("*/", i + 2)
      if endIdx == -1:
        emit(line[i .. ^1], tkComment)
        state.inBlockComment = true
        break
      else:
        emit(line[i .. endIdx + 1], tkComment)
        i = endIdx + 2
        continue

    # potrójny string """..."""
    if supportsTripleString(lang) and c == '"' and i + 2 < n and
       line[i+1] == '"' and line[i+2] == '"':
      let endIdx = line.find("\"\"\"", i + 3)
      if endIdx == -1:
        emit(line[i .. ^1], tkString)
        state.inTripleString = true
        break
      else:
        emit(line[i .. endIdx + 2], tkString)
        i = endIdx + 3
        continue

    # zwykły string "..." albo '...' (z obsługą \" wewnątrz)
    if c == '"' or c == '\'':
      let quote = c
      var j = i + 1
      while j < n:
        if line[j] == '\\' and j + 1 < n:
          j += 2
          continue
        if line[j] == quote:
          j += 1
          break
        j += 1
      emit(line[i ..< min(j, n)], tkString)
      i = j
      continue

    # liczba
    if c.isDigit():
      var j = i + 1
      while j < n and (line[j].isAlphaNumeric() or line[j] == '.' or line[j] == '_'):
        inc j
      emit(line[i ..< j], tkNumber)
      i = j
      continue

    # identyfikator / słowo kluczowe
    if isIdentStart(c):
      var j = i + 1
      while j < n and isIdentChar(line[j]): inc j
      let word = line[i ..< j]
      if kw.hasKey(word):
        emit(word, tkKeyword)
      elif word.len > 0 and word[0].isUpperAscii() and lang in {langNim, langC}:
        emit(word, tkType)  # przybliżenie: PascalCase = prawdopodobnie typ
      else:
        emit(word, tkPlain)
      i = j
      continue

    # cokolwiek innego (białe znaki, operatory, nawiasy...) -- zbierz w
    # jeden fragment "plain" aż do następnego znaku specjalnego, żeby nie
    # tworzyć jednego tokenu na spację (dużo mniej węzłów Fidget do
    # narysowania).
    var j = i + 1
    while j < n and not isIdentStart(line[j]) and not line[j].isDigit() and
          line[j] != '"' and line[j] != '\'' and
          not (lineComment.len > 0 and j + lineComment.len <= n and
               line[j ..< j + lineComment.len] == lineComment) and
          not (supportsBlockComment(lang) and line[j] == '/' and j+1<n and line[j+1]=='*'):
      inc j
    emit(line[i ..< j], tkPlain)
    i = j

proc colorFor*(kind: TokenKind): string =
  case kind
  of tkPlain: "#dbe1e8"
  of tkKeyword: "#c586c0"
  of tkString: "#98c379"
  of tkComment: "#6a737d"
  of tkNumber: "#d19a66"
  of tkType: "#e0c46c"
