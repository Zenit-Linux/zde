import std/[strutils, tables]

type
  TokenKind* = enum
    tkPlain, tkKeyword, tkString, tkComment, tkNumber, tkType

  Token* = object
    text*: string
    kind*: TokenKind

  Language* = enum
    langNim, langPython, langC, langJs, langShell, langGeneric,
    ## Rozbudowa (runda 20): trzy kolejne popularne formaty -- domyka
    ## realny brak (ten moduł, w odróżnieniu od reszty edytora, w ogóle
    ## nie zależy od `fidget`, więc dało się go w pełni skompilować i
    ## przetestować, patrz metoda weryfikacji przy `test_highlight.nim`).
    langGo, langRust, langJson

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
  ## Rozbudowa (runda 20): lista słów kluczowych Go -- ograniczona do 25
  ## faktycznych słów zarezerwowanych języka (Go ma ich celowo mało) plus
  ## garść najczęściej używanych identyfikatorów wbudowanych (`nil`,
  ## `true`/`false`, `error`) -- te ostatnie technicznie NIE są słowami
  ## kluczowymi w Go (dałoby się ich użyć jako nazw zmiennych), ale w
  ## praktyce prawie nikt tego nie robi, a podświetlenie ich tak samo jak
  ## `nil`/`true`/`false` w innych językach tego pliku jest spójne z resztą.
  KeywordsGo = wordSet([
    "break", "case", "chan", "const", "continue", "default", "defer",
    "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
    "interface", "map", "package", "range", "return", "select", "struct",
    "switch", "type", "var", "nil", "true", "false", "error", "iota",
  ])
  ## Rozbudowa (runda 20): słowa kluczowe Rust -- ŚWIADOMIE nie
  ## obejmuje wszystkich 2018+ "reserved for future use" słów Rusta
  ## (np. `try`, `union` w niektórych kontekstach), tylko te faktycznie
  ## używane w praktyce -- pełna, formalna lista jest znacznie dłuższa i
  ## nie wnosi realnej wartości dla podświetlania składni w prostym
  ## edytorze tekstu.
  KeywordsRust = wordSet([
    "as", "break", "const", "continue", "crate", "else", "enum", "extern",
    "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move",
    "mut", "pub", "ref", "return", "self", "Self", "static", "struct",
    "super", "trait", "true", "false", "type", "unsafe", "use", "where",
    "while", "async", "await", "dyn", "None", "Some", "Ok", "Err",
  ])
  ## Rozbudowa (runda 20): JSON formalnie NIE MA "słów kluczowych" w
  ## sensie języka programowania -- to tylko notacja danych. Te trzy to
  ## jedyne dopuszczalne w specyfikacji JSON literały spoza
  ## stringów/liczb, więc podświetlenie ich tak jak `true`/`false`/`nil`
  ## gdzie indziej w tym pliku jest naturalnym, spójnym wyborem.
  KeywordsJson = wordSet(["true", "false", "null"])

proc languageFor*(path: string): Language =
  let ext = path.toLowerAscii().rsplit('.', maxsplit = 1)
  if ext.len < 2: return langGeneric
  case ext[1]
  of "nim", "nims", "nimble": langNim
  of "py", "pyw": langPython
  of "c", "h", "cpp", "cc", "cxx", "hpp": langC
  of "js", "ts", "jsx", "tsx", "mjs": langJs
  of "sh", "bash", "zsh": langShell
  of "go": langGo
  of "rs": langRust
  of "json": langJson
  else: langGeneric

proc keywordsFor(lang: Language): Table[string, bool] =
  case lang
  of langNim: KeywordsNim
  of langPython: KeywordsPython
  of langC: KeywordsC
  of langJs: KeywordsJs
  of langShell: KeywordsShell
  of langGo: KeywordsGo
  of langRust: KeywordsRust
  of langJson: KeywordsJson
  of langGeneric: initTable[string, bool]()

proc lineCommentFor(lang: Language): string =
  ## Rozbudowa (runda 20): prawdziwy JSON (specyfikacja RFC 8259) W
  ## OGÓLE nie dopuszcza komentarzy -- `langJson` niżej zwraca pusty
  ## string, co wyłącza wykrywanie komentarza liniowego (reszta
  ## `tokenizeLine` już wcześniej sprawdzała `lineComment.len > 0` przed
  ## użyciem, więc puste działa poprawnie bez dodatkowych zmian gdzie
  ## indziej -- patrz test na to w `test_real_highlight.nim`, nie tylko
  ## założenie).
  case lang
  of langNim, langPython, langShell, langGeneric: "#"
  of langC, langJs, langGo, langRust: "//"
  of langJson: ""

proc supportsBlockComment(lang: Language): bool =
  ## Rozbudowa (runda 20): Go i Rust OBA wspierają `/* ... */` (tak samo
  ## jak C/JS) -- JSON nie wspiera żadnych komentarzy w ogóle, więc
  ## `langJson` świadomie NIE jest tu dodany (pozostaje poza zbiorem, tak
  ## jak `langNim`/`langPython`/`langShell` już wcześniej).
  lang in {langC, langJs, langGo, langRust}

proc supportsTripleString(lang: Language): bool =
  ## Rozbudowa (runda 20): ani Go, ani Rust, ani JSON nie mają
  ## odpowiednika potrójnego stringa Pythona/Nima (`"""`) -- Go ma
  ## surowe stringi w BACKTICKACH (`` `...` ``, inna składnia, patrz
  ## rozszerzenie obsługi cudzysłowu w `tokenizeLine` niżej), Rust ma
  ## `r"..."`/`r#"..."#` (świadomie NIE obsługiwane w tej rundzie -- rzadziej
  ## spotykana składnia, dodanie jej porządnie wymagałoby osobnej ścieżki
  ## parsowania z liczeniem `#`, nie tylko flagi bool jak tutaj).
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

    # zwykły string "..." albo '...' (z obsługą \" wewnątrz) -- oraz, dla
    # Go, string w BACKTICKACH (`` `...` ``, "raw string literal").
    # Rozbudowa (runda 20): backtick TRAKTOWANY JAKO JEDNOLINIJKOWY (tak
    # samo jak "..."/'...' obok, świadomie bez stanu przenoszonego między
    # liniami jak przy `"""` -- prawdziwe wieloliniowe surowe stringi Go
    # nie są tu w pełni obsługiwane, ten sam poziom uproszczenia co
    # reszta tego prostego tokenizera) i BEZ obsługi ucieczki `\` (w Go
    # wewnątrz backticków `\` to zwykły, dosłowny znak, nie początek
    # sekwencji ucieczki jak w "..." -- stąd osobna, prostsza pętla
    # niżej zamiast reużycia tej dla "/').
    if c == '"' or c == '\'' or (lang == langGo and c == '`'):
      let quote = c
      var j = i + 1
      if quote == '`':
        while j < n and line[j] != quote: inc j
        if j < n: inc j
      else:
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
      elif word.len > 0 and word[0].isUpperAscii() and lang in {langNim, langC, langGo, langRust}:
        ## Rozbudowa (runda 20): heurystyka PascalCase=typ rozszerzona o
        ## Go i Rust -- w OBU językach (w odróżnieniu od C, gdzie to
        ## tylko konwencja stylistyczna) PascalCase ma REALNE znaczenie
        ## językowe: w Go decyduje o eksporcie identyfikatora poza
        ## pakiet, w Rust to formalna konwencja dla
        ## structs/enums/traits, więc trafność tej heurystyki jest tu
        ## WYŻSZA niż dla C, nie tylko "tak samo dobra".
        emit(word, tkType)  # przybliżenie: PascalCase = prawdopodobnie typ
      else:
        emit(word, tkPlain)
      i = j
      continue

    # cokolwiek innego (białe znaki, operatory, nawiasy...) -- zbierz w
    # jeden fragment "plain" aż do następnego znaku specjalnego, żeby nie
    # tworzyć jednego tokenu na spację (dużo mniej węzłów Fidget do
    # narysowania).
    #
    # NAPRAWIONY BŁĄD (runda 20, wychwycony testem, nie przez czytanie
    # kodu): pierwsza wersja tego warunku stopu NIE uwzględniała
    # backticka (`` ` ``) -- w praktyce oznaczało to, że backtick
    # napotkany W TRAKCIE zbierania fragmentu "plain" (np. operator tuż
    # przed stringiem w backtickach w kodzie Go) zostawał PO CICHU
    # POŁKNIĘTY do tego fragmentu, zamiast zatrzymać go i pozwolić
    # kolejnej iteracji pętli głównej trafić w nowo dodaną obsługę
    # stringów w backtickach wyżej -- string w backtickach nigdy by się
    # nie podświetlił, gdyby poprzedzał go choćby jeden znak "plain" (np.
    # spacja PO operatorze `=`, bardzo częsty przypadek: `x := \`raw\``).
    var j = i + 1
    while j < n and not isIdentStart(line[j]) and not line[j].isDigit() and
          line[j] != '"' and line[j] != '\'' and
          not (lang == langGo and line[j] == '`') and
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
