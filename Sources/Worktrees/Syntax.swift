import Foundation

/// Syntax colouring for the diff panel. A small hand-written tokenizer: it only splits lines
/// into coloured runs (comments, strings, numbers, keywords, types, function calls) and never
/// runs or interprets what it reads. Everything else stays plain text.

/// What a run of text is, mapped to a colour token by the view.
enum TokenKind: UInt8, Sendable {
    case keyword, string, comment, number, type, function
}

/// A coloured run inside one line, in UTF-8 offsets. Runs start and end on ASCII characters
/// or the line's ends, so they never cut a character in half.
struct TokenSpan: Sendable, Equatable {
    let start: Int32
    let end: Int32
    let kind: TokenKind
}

/// Where a line ends: inside a block comment, a string that runs on, a Markdown code fence or
/// an HTML tag, so the next line in the hunk starts there.
enum LexState: Equatable, Sendable {
    case normal
    case comment(close: [UInt8])
    case string(close: [UInt8], escapes: Bool)
    case fence
    case tag
    /// Inside an HTML script or style element: plain until the closing tag.
    case raw(close: [UInt8])
}

enum CodeLanguage: Sendable, Equatable {
    case swift, javascript, typescript, c, python, go, rust, kotlin, java, ruby, shell, json, yaml, css, scss, html, markdown, plain

    init(path: String) {
        let name = (path.hasSuffix("/") ? String(path.dropLast()) : path).split(separator: "/").last.map(String.init) ?? path
        let lower = name.lowercased()
        switch lower {
        case "gemfile", "rakefile", "podfile", "fastfile", "brewfile": self = .ruby; return
        case ".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile", ".envrc": self = .shell; return
        default: break
        }
        let ext = lower.contains(".") ? String(lower.split(separator: ".").last ?? "") : ""
        switch ext {
        case "swift": self = .swift
        case "tsx", "js", "jsx", "mjs", "cjs": self = .javascript
        // Plain TypeScript has no JSX, and `<T>(x) =>` or `<number>value` must not read as tags.
        case "ts", "mts", "cts": self = .typescript
        case "c", "h", "cpp", "hpp", "cc", "cxx", "hh", "hxx", "m", "mm": self = .c
        case "py", "pyi": self = .python
        case "go": self = .go
        case "rs": self = .rust
        case "kt", "kts": self = .kotlin
        case "java": self = .java
        case "rb", "rake", "gemspec": self = .ruby
        case "sh", "bash", "zsh", "command": self = .shell
        case "json", "jsonc", "json5": self = .json
        case "yml", "yaml": self = .yaml
        case "css": self = .css
        case "scss", "less": self = .scss
        case "html", "htm", "xml", "svg", "plist", "xib", "storyboard", "vue", "xhtml": self = .html
        case "md", "markdown", "mdx": self = .markdown
        default: self = .plain
        }
    }
}

enum Syntax {
    /// Hunks longer than this stay plain.
    static let maxHunkLines = 2000
    /// Lines longer than this (minified code, data) stay plain.
    static let maxLineBytes = 4000

    /// Colours one line and returns the state the next line starts in.
    static func tokenize(_ line: String, _ language: CodeLanguage, _ state: inout LexState) -> [TokenSpan] {
        let bytes = Array(line.utf8)
        var lexer = Lexer(b: bytes, state: state)
        guard bytes.count <= maxLineBytes else {
            // Left plain, but a comment or string it closes must not run on past it.
            if case .comment = state { _ = lexer.resume(); state = lexer.state }
            if case .string = state { _ = lexer.resume(); state = lexer.state }
            return []
        }
        switch language {
        case .plain: return []
        case .markdown: lexer.markdown()
        case .html: lexer.html()
        case .css: lexer.css(scss: false)
        case .scss: lexer.css(scss: true)
        case .yaml: lexer.yaml()
        default: lexer.code(Grammar.for(language))
        }
        state = lexer.state
        return lexer.out
    }
}

// MARK: - Grammars

struct Grammar: Sendable {
    var lineComments: [[UInt8]] = []
    /// `#` comments only count at the start of a line or after a space (shell, Ruby, Python).
    var commentAfterSpace = false
    var blockComments: [([UInt8], [UInt8])] = []
    /// Strings that may run over several lines: opener, closer, whether backslash escapes.
    /// Checked before `quotes`, so `"""` wins over `"`.
    var longStrings: [([UInt8], [UInt8], Bool)] = []
    /// Strings that end with the line.
    var quotes: [UInt8] = [Ch.dq, Ch.sq]
    var keywords: Set<String> = []
    var types: Set<String> = []
    var capitalTypes = true
    /// Extra identifier characters, such as `$` in JavaScript.
    var identExtra: [UInt8] = []
    /// `@name`: decorators, annotations, attributes.
    var annotation: TokenKind?
    /// `#name` directives: C preprocessor, Swift `#if`.
    var hashDirective = false
    var jsxTags = false
    var rustLifetimes = false
    var macroBang = false
    var shellVariables = false
    var rubySymbols = false
    /// JSON: a string followed by `:` is a key.
    var keyStrings = false
    /// JavaScript: `/.../` where a value can start is a regular expression.
    var regexLiterals = false
    /// Shell: single quotes take no escapes.
    var rawSingleQuotes = false

    static func `for`(_ language: CodeLanguage) -> Grammar {
        switch language {
        case .swift: swift
        case .javascript: javascript
        case .typescript: typescript
        case .c: c
        case .python: python
        case .go: go
        case .rust: rust
        case .kotlin: kotlin
        case .java: java
        case .ruby: ruby
        case .shell: shell
        case .json: json
        default: Grammar()
        }
    }

    private static let slash: [[UInt8]] = [Array("//".utf8)]
    private static let cBlock: [([UInt8], [UInt8])] = [(Array("/*".utf8), Array("*/".utf8))]
    private static let tripleQuote: ([UInt8], [UInt8], Bool) = (Array("\"\"\"".utf8), Array("\"\"\"".utf8), true)

    private static func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    static let swift = Grammar(
        lineComments: slash, blockComments: cBlock, longStrings: [tripleQuote], quotes: [Ch.dq],
        keywords: words("""
        associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private \
        precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer \
        do else fallthrough for guard if in repeat return throw switch where while as false is nil self super throws true try \
        await async actor some any get set willSet didSet lazy weak unowned mutating nonmutating override final required \
        convenience dynamic indirect optional consume borrowing consuming nonisolated isolated package macro
        """),
        annotation: .keyword, hashDirective: true
    )

    static let javascript = Grammar(
        lineComments: slash, blockComments: cBlock, longStrings: [(Array("`".utf8), Array("`".utf8), true)],
        keywords: words("""
        abstract as async await break case catch class const continue debugger declare default delete do else enum export \
        extends false finally for from function get if implements import in instanceof interface is keyof let namespace new \
        null of private protected public readonly return satisfies set static super switch this throw true try type typeof \
        undefined var void while with yield
        """),
        types: words("string number boolean any unknown never object bigint symbol"),
        identExtra: [Ch.dollar], annotation: .function, jsxTags: true, regexLiterals: true
    )

    static let typescript: Grammar = {
        var g = javascript
        g.jsxTags = false
        return g
    }()

    static let c = Grammar(
        lineComments: slash, blockComments: cBlock,
        keywords: words("""
        auto break case char const continue default do double else enum extern float for goto if inline int long register \
        restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool true false \
        class namespace template typename public private protected virtual override final new delete this nullptr using \
        operator friend explicit constexpr noexcept static_cast dynamic_cast reinterpret_cast const_cast try catch throw \
        self super nil YES NO id instancetype nonatomic strong weak assign copy readonly readwrite nullable nonnull
        """),
        annotation: .keyword, hashDirective: true
    )

    static let python = Grammar(
        lineComments: [Array("#".utf8)],
        longStrings: [tripleQuote, (Array("'''".utf8), Array("'''".utf8), true)],
        keywords: words("""
        and as assert async await break class continue def del elif else except finally for from global if import in is \
        lambda nonlocal not or pass raise return try while with yield match case True False None self cls
        """),
        annotation: .function
    )

    static let go = Grammar(
        lineComments: slash, blockComments: cBlock, longStrings: [(Array("`".utf8), Array("`".utf8), false)],
        keywords: words("""
        break case chan const continue default defer else fallthrough for func go goto if import interface map package \
        range return select struct switch type var true false nil iota
        """),
        types: words("""
        bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 \
        uint32 uint64 uintptr any
        """)
    )

    static let rust = Grammar(
        lineComments: slash, blockComments: cBlock, longStrings: [(Array("\"".utf8), Array("\"".utf8), true)], quotes: [Ch.sq],
        keywords: words("""
        as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut \
        pub ref return self static struct super trait true type unsafe use where while
        """),
        types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
        hashDirective: true, rustLifetimes: true, macroBang: true
    )

    static let kotlin = Grammar(
        lineComments: slash, blockComments: cBlock, longStrings: [tripleQuote],
        keywords: words("""
        as break class continue do else false for fun if in interface is null object package return super this throw true \
        try typealias typeof val var when while by catch constructor finally get import init set where abstract annotation \
        companion const data enum external final inline inner internal lateinit open operator out override private \
        protected public sealed suspend vararg
        """),
        annotation: .keyword
    )

    static let java = Grammar(
        lineComments: slash, blockComments: cBlock, longStrings: [tripleQuote],
        keywords: words("""
        abstract assert boolean break byte case catch char class const continue default do double else enum extends final \
        finally float for goto if implements import instanceof int interface long native new package private protected \
        public return short static strictfp super switch synchronized this throw throws transient try void volatile while \
        var record sealed permits yield true false null
        """),
        annotation: .keyword
    )

    static let ruby = Grammar(
        lineComments: [Array("#".utf8)], commentAfterSpace: true,
        keywords: words("""
        alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo \
        rescue retry return self super then true undef unless until when while yield require require_relative attr_reader \
        attr_writer attr_accessor private protected public lambda proc
        """),
        identExtra: [Ch.question], annotation: .type, rubySymbols: true
    )

    static let shell = Grammar(
        lineComments: [Array("#".utf8)], commentAfterSpace: true,
        keywords: words("""
        if then else elif fi for while until do done case esac in function return local export readonly declare unset \
        shift exit set source alias break continue select time
        """),
        capitalTypes: false, shellVariables: true, rawSingleQuotes: true
    )

    static let json = Grammar(
        lineComments: slash, blockComments: cBlock, quotes: [Ch.dq],
        keywords: words("true false null"), capitalTypes: false, keyStrings: true
    )
}

enum Ch {
    static let tab = UInt8(ascii: "\t"), space = UInt8(ascii: " "), dq = UInt8(ascii: "\""), sq = UInt8(ascii: "'")
    static let backslash = UInt8(ascii: "\\"), slash = UInt8(ascii: "/"), dot = UInt8(ascii: "."), colon = UInt8(ascii: ":")
    static let lparen = UInt8(ascii: "("), lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), at = UInt8(ascii: "@")
    static let hash = UInt8(ascii: "#"), dollar = UInt8(ascii: "$"), underscore = UInt8(ascii: "_"), dash = UInt8(ascii: "-")
    static let question = UInt8(ascii: "?"), bang = UInt8(ascii: "!"), lbrace = UInt8(ascii: "{"), rbrace = UInt8(ascii: "}")
    static let lbracket = UInt8(ascii: "["), rbracket = UInt8(ascii: "]"), rparen = UInt8(ascii: ")"), star = UInt8(ascii: "*")
    static let backtick = UInt8(ascii: "`"), amp = UInt8(ascii: "&"), semicolon = UInt8(ascii: ";"), plus = UInt8(ascii: "+")
    static let percent = UInt8(ascii: "%"), equals = UInt8(ascii: "="), pipe = UInt8(ascii: "|"), tilde = UInt8(ascii: "~")

    static func isSpace(_ c: UInt8) -> Bool { c == space || c == tab }
    static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    static func isUpper(_ c: UInt8) -> Bool { c >= 65 && c <= 90 }
    static func isLower(_ c: UInt8) -> Bool { c >= 97 && c <= 122 }
    static func isLetter(_ c: UInt8) -> Bool { isUpper(c) || isLower(c) }
    /// Letters, `_`, and any non-ASCII byte, so a word never splits a multi-byte character.
    static func isIdentStart(_ c: UInt8) -> Bool { isLetter(c) || c == underscore || c >= 0x80 }
    static func isIdent(_ c: UInt8) -> Bool { isIdentStart(c) || isDigit(c) }
}

// MARK: - Lexer

private struct Lexer {
    let b: [UInt8]
    var state: LexState
    var out: [TokenSpan] = []
    var i = 0
    var n: Int { b.count }

    init(b: [UInt8], state: LexState) { self.b = b; self.state = state }

    mutating func emit(_ start: Int, _ end: Int, _ kind: TokenKind) {
        if end > start { out.append(TokenSpan(start: Int32(start), end: Int32(end), kind: kind)) }
    }

    func at(_ j: Int, _ pattern: [UInt8]) -> Bool {
        guard j + pattern.count <= n else { return false }
        for k in 0..<pattern.count where b[j + k] != pattern[k] { return false }
        return true
    }

    func find(_ pattern: [UInt8], from j: Int) -> Int? {
        var k = j
        while k + pattern.count <= n {
            if at(k, pattern) { return k }
            k += 1
        }
        return nil
    }

    /// Scans a string body from `j` to its closer. Returns the end (past the closer) and
    /// whether the closer was found on this line.
    func scanString(from j: Int, close: [UInt8], escapes: Bool) -> (Int, Bool) {
        var k = j
        while k < n {
            if escapes && b[k] == Ch.backslash { k += 2; continue }
            if at(k, close) { return (k + close.count, true) }
            k += 1
        }
        return (n, false)
    }

    func nextNonSpace(_ j: Int) -> Int {
        var k = j
        while k < n, Ch.isSpace(b[k]) { k += 1 }
        return k
    }

    func previousNonSpace(_ j: Int) -> UInt8? {
        var k = j - 1
        while k >= 0, Ch.isSpace(b[k]) { k -= 1 }
        return k >= 0 ? b[k] : nil
    }

    /// Picks up a comment or string carried over from the line before. False if it fills the line.
    mutating func resume() -> Bool {
        switch state {
        case .comment(let close):
            if let end = find(close, from: 0) {
                emit(0, end + close.count, .comment)
                i = end + close.count
                state = .normal
            } else {
                emit(0, n, .comment)
                return false
            }
        case .string(let close, let escapes):
            let (end, closed) = scanString(from: 0, close: close, escapes: escapes)
            emit(0, end, .string)
            i = end
            if closed { state = .normal } else { return false }
        default:
            break
        }
        return true
    }

    // MARK: Code

    mutating func code(_ g: Grammar) {
        if case .fence = state { state = .normal }
        if case .tag = state { state = .normal }
        guard resume() else { return }
        // JSX: inside a tag after its name, and the text between tags, which stays plain.
        var inJSXTag = false
        var inJSXText = false
        /// A `<` right after JSX text opens a tag whatever came before it.
        var tagAfterText = false
        /// Braces open in a `{expression}` inside JSX text; text resumes when it closes.
        var jsxBraces = 0
        scan: while i < n {
            let c = b[i]
            if Ch.isSpace(c) { i += 1; continue }
            if inJSXText {
                if c == Ch.lt || c == Ch.lbrace {
                    inJSXText = false
                    tagAfterText = c == Ch.lt
                    if c == Ch.lbrace { jsxBraces = 1; i += 1; continue }
                } else {
                    i += 1
                    continue
                }
            }
            if jsxBraces > 0 {
                if c == Ch.lbrace { jsxBraces += 1 }
                if c == Ch.rbrace {
                    jsxBraces -= 1
                    if jsxBraces == 0 { inJSXText = true; i += 1; continue }
                }
            }
            if inJSXTag, c == Ch.gt, i == 0 || b[i - 1] != Ch.equals {
                inJSXTag = false
                inJSXText = true
                i += 1
                continue
            }
            if g.regexLiterals, c == Ch.slash, i + 1 < n, b[i + 1] != Ch.slash, b[i + 1] != Ch.star, regexCanStart(at: i),
               let end = regexEnd(from: i + 1) {
                emit(i, end, .string)
                i = end
                continue
            }
            if g.rustLifetimes, let (open, hashes) = rustRawString(at: i) {
                let close = [Ch.dq] + Array(repeating: Ch.hash, count: hashes)
                let (end, closed) = scanString(from: i + open, close: close, escapes: false)
                emit(i, end, .string)
                i = end
                if !closed { state = .string(close: close, escapes: false); return }
                continue
            }
            for prefix in g.lineComments where at(i, prefix) && (!g.commentAfterSpace || i == 0 || Ch.isSpace(b[i - 1])) {
                if prefix == [Ch.hash] && g.shellVariables && i + 1 < n && b[i + 1] == Ch.bang && i == 0 {
                    emit(i, n, .comment)  // shebang
                    return
                }
                emit(i, n, .comment)
                return
            }
            for (open, close) in g.blockComments where at(i, open) {
                if let end = find(close, from: i + open.count) {
                    emit(i, end + close.count, .comment)
                    i = end + close.count
                    continue scan
                }
                emit(i, n, .comment)
                state = .comment(close: close)
                return
            }
            for (open, close, escapes) in g.longStrings where at(i, open) {
                let (end, closed) = scanString(from: i + open.count, close: close, escapes: escapes)
                emit(i, end, .string)
                i = end
                if !closed { state = .string(close: close, escapes: escapes); return }
                continue scan
            }
            if g.quotes.contains(c) {
                if g.rustLifetimes && c == Ch.sq && !isCharLiteral(i) {
                    var j = i + 1
                    while j < n, Ch.isIdent(b[j]) { j += 1 }
                    emit(i, j, .type)
                    i = max(j, i + 1)
                    continue
                }
                let (end, _) = scanString(from: i + 1, close: [c], escapes: !(g.rawSingleQuotes && c == Ch.sq))
                var kind = TokenKind.string
                if g.keyStrings, end < n, b[nextNonSpace(end)...].first == Ch.colon { kind = .type }
                emit(i, end, kind)
                i = end
                continue
            }
            if Ch.isDigit(c) || (c == Ch.dot && i + 1 < n && Ch.isDigit(b[i + 1]) && (i == 0 || !Ch.isIdent(b[i - 1]))) {
                number()
                continue
            }
            if Ch.isIdentStart(c) || g.identExtra.contains(c) {
                var j = i + 1
                while j < n, Ch.isIdent(b[j]) || g.identExtra.contains(b[j]) { j += 1 }
                let word = String(decoding: b[i..<j], as: UTF8.self)
                let afterDot = i > 0 && b[i - 1] == Ch.dot
                var kind: TokenKind?
                var end = j
                if !afterDot && g.keywords.contains(word) {
                    kind = .keyword
                } else if g.types.contains(word) || (g.capitalTypes && Ch.isUpper(c)) {
                    kind = .type
                } else if j < n && b[j] == Ch.lparen {
                    kind = .function
                } else if g.macroBang && j + 1 < n && b[j] == Ch.bang && [Ch.lparen, Ch.lbracket, Ch.lbrace].contains(b[j + 1]) {
                    kind = .function
                    end = j + 1
                }
                if let kind { emit(i, end, kind) }
                i = end
                continue
            }
            if c == Ch.at, let kind = g.annotation, i + 1 < n, Ch.isIdentStart(b[i + 1]) {
                var j = i + 2
                while j < n, Ch.isIdent(b[j]) || b[j] == Ch.dot { j += 1 }
                emit(i, j, kind)
                i = j
                continue
            }
            if c == Ch.hash, g.hashDirective, i + 1 < n {
                // Rust attributes: #[derive(...)] and #![...]
                if b[i + 1] == Ch.lbracket || (b[i + 1] == Ch.bang && i + 2 < n && b[i + 2] == Ch.lbracket) {
                    let close = find([Ch.rbracket], from: i) ?? (n - 1)
                    emit(i, close + 1, .keyword)
                    i = close + 1
                    continue
                }
                var j = i + 1
                while j < n, Ch.isSpace(b[j]) { j += 1 }
                if j < n, Ch.isIdentStart(b[j]) {
                    var k = j
                    while k < n, Ch.isIdent(b[k]) { k += 1 }
                    emit(i, k, .keyword)
                    i = k
                    let word = String(decoding: b[j..<k], as: UTF8.self)
                    if word == "include" || word == "import" {
                        let s = nextNonSpace(k)
                        if s < n, b[s] == Ch.lt {
                            let close = find([Ch.gt], from: s) ?? (n - 1)
                            emit(s, close + 1, .string)
                            i = close + 1
                        }
                    }
                    continue
                }
            }
            if c == Ch.dollar, g.shellVariables, i + 1 < n {
                if b[i + 1] == Ch.lbrace {
                    let close = find([Ch.rbrace], from: i) ?? (n - 1)
                    emit(i, close + 1, .type)
                    i = close + 1
                    continue
                }
                var j = i + 1
                if Ch.isIdentStart(b[j]) {
                    while j < n, Ch.isIdent(b[j]) { j += 1 }
                } else if Ch.isDigit(b[j]) || [Ch.at, Ch.star, Ch.hash, Ch.question, Ch.bang, Ch.dollar].contains(b[j]) {
                    j += 1
                }
                if j > i + 1 { emit(i, j, .type); i = j; continue }
            }
            if c == Ch.colon, g.rubySymbols, i + 1 < n, Ch.isIdentStart(b[i + 1]), i == 0 || (b[i - 1] != Ch.colon && !Ch.isIdent(b[i - 1])) {
                var j = i + 1
                while j < n, Ch.isIdent(b[j]) || b[j] == Ch.question { j += 1 }
                emit(i, j, .number)
                i = j
                continue
            }
            if c == Ch.lt, g.jsxTags, i + 1 < n {
                let nameStart = b[i + 1] == Ch.slash ? i + 2 : i + 1
                let prev = previousNonSpace(i)
                let prevIsValue = prev.map { Ch.isIdent($0) || $0 == Ch.rparen || $0 == Ch.rbracket || $0 == Ch.dollar } ?? false
                defer { tagAfterText = false }
                if nameStart < n, Ch.isLetter(b[nameStart]), !prevIsValue || tagAfterText {
                    var j = nameStart
                    while j < n, Ch.isIdent(b[j]) || b[j] == Ch.dot || b[j] == Ch.dash { j += 1 }
                    emit(nameStart, j, Ch.isUpper(b[nameStart]) ? .type : .keyword)
                    inJSXTag = true
                    i = j
                    continue
                }
            }
            i += 1
        }
    }

    /// A `/` starts a regular expression where a value is expected: at the start, after an
    /// operator or opening bracket, or after a keyword like `return`.
    func regexCanStart(at j: Int) -> Bool {
        var k = j - 1
        while k >= 0, Ch.isSpace(b[k]) { k -= 1 }
        guard k >= 0 else { return true }
        let p = b[k]
        if Ch.isIdent(p) || p == Ch.dollar {
            var s = k
            while s > 0, Ch.isIdent(b[s - 1]) { s -= 1 }
            let word = String(decoding: b[s...k], as: UTF8.self)
            return ["return", "typeof", "case", "in", "of", "delete", "void", "throw", "yield", "await", "new", "else", "do"].contains(word)
        }
        return !(p == Ch.rparen || p == Ch.rbracket || p == Ch.rbrace || p == Ch.dq || p == Ch.sq || p == Ch.backtick || Ch.isDigit(p) || p == Ch.dot)
    }

    /// The end of a regular expression body starting at `j` (past its flags), or nil when it
    /// doesn't close on this line, in which case the `/` was division after all.
    func regexEnd(from j: Int) -> Int? {
        var k = j
        var inClass = false
        while k < n {
            let c = b[k]
            if c == Ch.backslash { k += 2; continue }
            if c == Ch.lbracket { inClass = true } else if c == Ch.rbracket { inClass = false } else if c == Ch.slash && !inClass {
                k += 1
                while k < n, Ch.isLetter(b[k]) { k += 1 }
                return k
            }
            k += 1
        }
        return nil
    }

    /// Rust raw strings: `r"..."`, `r#"..."#`, `br##"..."##`. The length of the opener and
    /// the number of hashes, or nil.
    func rustRawString(at j: Int) -> (Int, Int)? {
        var k = j
        if k < n, b[k] == UInt8(ascii: "b") { k += 1 }
        guard k < n, b[k] == UInt8(ascii: "r"), j == 0 || !Ch.isIdent(b[j - 1]) else { return nil }
        k += 1
        var hashes = 0
        while k < n, b[k] == Ch.hash { hashes += 1; k += 1 }
        guard k < n, b[k] == Ch.dq else { return nil }
        return (k + 1 - j, hashes)
    }

    /// Rust: `'a'` or `'\n'` is a character, `'a` on its own a lifetime.
    func isCharLiteral(_ j: Int) -> Bool {
        guard j + 1 < n else { return true }
        if b[j + 1] == Ch.backslash { return true }
        // One character (possibly multi-byte) then a closing quote.
        var k = j + 1
        k += 1
        while k < n, b[k] & 0xC0 == 0x80 { k += 1 }
        return k < n && b[k] == Ch.sq
    }

    mutating func number() {
        let hex = b[i] == UInt8(ascii: "0") && i + 1 < n && (b[i + 1] | 0x20) == UInt8(ascii: "x")
        var j = i + 1
        while j < n {
            let d = b[j]
            if Ch.isIdent(d) && d < 0x80 {
                j += 1
            } else if d == Ch.dot && j + 1 < n && Ch.isDigit(b[j + 1]) {
                j += 1
            } else if !hex && (d == Ch.plus || d == Ch.dash) && (b[j - 1] | 0x20) == UInt8(ascii: "e") && j + 1 < n && Ch.isDigit(b[j + 1]) {
                j += 1
            } else {
                break
            }
        }
        emit(i, j, .number)
        i = j
    }

    // MARK: Markdown

    mutating func markdown() {
        let start = nextNonSpace(0)
        let fence = at(start, Array("```".utf8)) || at(start, Array("~~~".utf8))
        if case .fence = state {
            emit(0, n, .string)
            if fence { state = .normal }
            return
        }
        state = .normal
        if fence {
            emit(start, n, .string)
            state = .fence
            return
        }
        guard start < n else { return }
        // Headings: up to six #, then a space or the end.
        if start <= 3, b[start] == Ch.hash {
            var j = start
            while j < n, b[j] == Ch.hash { j += 1 }
            if j - start <= 6 && (j == n || Ch.isSpace(b[j])) { emit(start, n, .keyword); return }
        }
        if b[start] == Ch.gt { emit(start, n, .comment); return }
        i = start
        // List markers.
        if [Ch.dash, Ch.star, Ch.plus].contains(b[i]), i + 1 < n, Ch.isSpace(b[i + 1]) {
            emit(i, i + 1, .keyword)
            i += 2
        } else {
            var j = i
            while j < n, Ch.isDigit(b[j]) { j += 1 }
            if j > i, j + 1 < n, b[j] == Ch.dot || b[j] == Ch.rparen, Ch.isSpace(b[j + 1]) {
                emit(i, j + 1, .keyword)
                i = j + 2
            }
        }
        while i < n {
            let c = b[i]
            if c == Ch.backtick {
                if let close = find([Ch.backtick], from: i + 1) { emit(i, close + 1, .string); i = close + 1; continue }
            } else if at(i, Array("<!--".utf8)) {
                let close = find(Array("-->".utf8), from: i + 4).map { $0 + 3 } ?? n
                emit(i, close, .comment)
                i = close
                continue
            } else if c == Ch.star || c == Ch.underscore {
                // Emphasis: a run of one or two markers, text that doesn't start with a space, the same run again.
                let double = i + 1 < n && b[i + 1] == c
                let marker = double ? [c, c] : [c]
                let open = i + marker.count
                let wordInside = c == Ch.underscore && i > 0 && Ch.isIdent(b[i - 1])
                if !wordInside, open < n, !Ch.isSpace(b[open]), b[open] != c, let close = find(marker, from: open + 1),
                   !Ch.isSpace(b[close - 1]) {
                    emit(i, close + marker.count, .type)
                    i = close + marker.count
                    continue
                }
                i += marker.count
                continue
            } else if c == Ch.rbracket, i + 1 < n, b[i + 1] == Ch.lparen {
                let close = find([Ch.rparen], from: i + 2).map { $0 + 1 } ?? n
                emit(i + 1, close, .string)
                i = close
                continue
            }
            i += 1
        }
    }

    // MARK: HTML and XML

    mutating func html() {
        if case .fence = state { state = .normal }
        if case .raw(let close) = state {
            guard let end = findIgnoringCase(close, from: 0) else { return }
            i = end
            state = .normal
        }
        guard resume() else { return }
        var inTag = state == .tag
        state = .normal
        /// Set by an opening script or style tag; its text starts when the tag closes.
        var rawClose: [UInt8]?
        while i < n {
            let c = b[i]
            if inTag {
                if Ch.isSpace(c) { i += 1; continue }
                if c == Ch.gt {
                    inTag = false
                    i += 1
                    if let close = rawClose {
                        rawClose = nil
                        guard let end = findIgnoringCase(close, from: i) else { state = .raw(close: close); return }
                        i = end
                    }
                    continue
                }
                if c == Ch.dq || c == Ch.sq {
                    let (end, _) = scanString(from: i + 1, close: [c], escapes: false)
                    emit(i, end, .string)
                    i = end
                    continue
                }
                if Ch.isIdentStart(c) || c == Ch.at || c == Ch.colon {
                    var j = i + 1
                    while j < n, Ch.isIdent(b[j]) || [Ch.dash, Ch.colon, Ch.dot].contains(b[j]) { j += 1 }
                    emit(i, j, .function)
                    i = j
                    continue
                }
                i += 1
                continue
            }
            if at(i, Array("<!--".utf8)) {
                if let end = find(Array("-->".utf8), from: i + 4) {
                    emit(i, end + 3, .comment)
                    i = end + 3
                    continue
                }
                emit(i, n, .comment)
                state = .comment(close: Array("-->".utf8))
                return
            }
            if c == Ch.lt, i + 1 < n {
                var j = i + 1
                if [Ch.slash, Ch.bang, Ch.question].contains(b[j]) { j += 1 }
                if j < n, Ch.isLetter(b[j]) {
                    var k = j
                    while k < n, Ch.isIdent(b[k]) || [Ch.dash, Ch.colon, Ch.dot].contains(b[k]) { k += 1 }
                    emit(j, k, .keyword)
                    let name = String(decoding: b[j..<k], as: UTF8.self).lowercased()
                    if b[i + 1] != Ch.slash, name == "script" || name == "style" { rawClose = Array("</\(name)".utf8) }
                    i = k
                    inTag = true
                    continue
                }
            }
            if c == Ch.amp, let semi = b[(i + 1)..<min(n, i + 11)].firstIndex(of: Ch.semicolon),
               b[(i + 1)..<semi].allSatisfy({ Ch.isIdent($0) || $0 == Ch.hash }) {
                emit(i, semi + 1, .number)
                i = semi + 1
                continue
            }
            i += 1
        }
        if inTag { state = .tag }
    }

    /// `pattern` (lowercase ASCII) anywhere from `j`, ignoring case.
    func findIgnoringCase(_ pattern: [UInt8], from j: Int) -> Int? {
        var k = j
        while k + pattern.count <= n {
            var hit = true
            for m in 0..<pattern.count where (b[k + m] | (Ch.isUpper(b[k + m]) ? 0x20 : 0)) != pattern[m] { hit = false; break }
            if hit { return k }
            k += 1
        }
        return nil
    }

    // MARK: CSS and SCSS

    mutating func css(scss: Bool) {
        if case .fence = state { state = .normal }
        if case .tag = state { state = .normal }
        guard resume() else { return }
        // A line with a brace is a selector (or at-rule); otherwise declarations.
        let selector = b.contains(Ch.lbrace)
        var sawProperty = false
        while i < n {
            let c = b[i]
            if Ch.isSpace(c) { i += 1; continue }
            if at(i, Array("/*".utf8)) {
                if let end = find(Array("*/".utf8), from: i + 2) {
                    emit(i, end + 2, .comment)
                    i = end + 2
                    continue
                }
                emit(i, n, .comment)
                state = .comment(close: Array("*/".utf8))
                return
            }
            if scss && at(i, Array("//".utf8)) && (i == 0 || Ch.isSpace(b[i - 1])) { emit(i, n, .comment); return }
            if c == Ch.dq || c == Ch.sq {
                let (end, _) = scanString(from: i + 1, close: [c], escapes: true)
                emit(i, end, .string)
                i = end
                continue
            }
            if (c == Ch.at || c == Ch.bang || (scss && c == Ch.dollar)), i + 1 < n, Ch.isIdentStart(b[i + 1]) {
                var j = i + 1
                while j < n, Ch.isIdent(b[j]) || b[j] == Ch.dash { j += 1 }
                let isVariable = c == Ch.dollar
                emit(i, j, isVariable ? .type : .keyword)
                if isVariable && !selector && !sawProperty { sawProperty = true }
                i = j
                continue
            }
            if selector, c == Ch.dot || c == Ch.hash || c == Ch.colon || c == Ch.amp, i + 1 < n,
               Ch.isIdentStart(b[i + 1]) || b[i + 1] == Ch.dash || b[i + 1] == Ch.colon {
                var j = i + 1
                while j < n, Ch.isIdent(b[j]) || b[j] == Ch.dash || b[j] == Ch.colon { j += 1 }
                emit(i, j, .function)
                i = j
                continue
            }
            if !selector, c == Ch.hash, i + 1 < n, Ch.isIdent(b[i + 1]) {
                var j = i + 1
                while j < n, Ch.isIdent(b[j]) { j += 1 }
                emit(i, j, .number)
                i = j
                continue
            }
            if Ch.isDigit(c) || (c == Ch.dot && i + 1 < n && Ch.isDigit(b[i + 1])) || (c == Ch.dash && i + 1 < n && Ch.isDigit(b[i + 1]) && (i == 0 || !Ch.isIdent(b[i - 1]))) {
                var j = i + 1
                while j < n, Ch.isIdent(b[j]) || b[j] == Ch.dot || b[j] == Ch.percent { j += 1 }
                emit(i, j, .number)
                i = j
                continue
            }
            if Ch.isIdentStart(c) || c == Ch.dash {
                var j = i + 1
                while j < n, Ch.isIdent(b[j]) || b[j] == Ch.dash { j += 1 }
                let next = nextNonSpace(j)
                if selector {
                    emit(i, j, .function)
                } else if !sawProperty && next < n && b[next] == Ch.colon {
                    emit(i, j, .type)
                    sawProperty = true
                } else if j < n && b[j] == Ch.lparen {
                    emit(i, j, .function)
                }
                i = j
                continue
            }
            if c == Ch.semicolon { sawProperty = false }
            i += 1
        }
    }

    // MARK: YAML

    mutating func yaml() {
        if case .fence = state { state = .normal }
        guard resume() else { return }
        state = .normal
        i = nextNonSpace(0)
        guard i < n else { return }
        if at(i, Array("---".utf8)) || at(i, Array("...".utf8)) { emit(i, i + 3, .keyword); i += 3 }
        // List markers, possibly nested on one line.
        while i < n, b[i] == Ch.dash, i + 1 == n || Ch.isSpace(b[i + 1]) { i = nextNonSpace(i + 1) }
        guard i < n else { return }
        if b[i] == Ch.hash { emit(i, n, .comment); return }
        // A key: quoted, or plain up to ": ".
        var keyEnd: Int?
        if b[i] == Ch.dq || b[i] == Ch.sq {
            let (end, _) = scanString(from: i + 1, close: [b[i]], escapes: b[i] == Ch.dq)
            let after = nextNonSpace(end)
            if after < n, b[after] == Ch.colon { keyEnd = end }
        } else {
            var j = i
            while j < n {
                if b[j] == Ch.colon && (j + 1 == n || Ch.isSpace(b[j + 1])) { keyEnd = j; break }
                if b[j] == Ch.hash && j > i && Ch.isSpace(b[j - 1]) { break }
                if [Ch.lbrace, Ch.lbracket, Ch.dq, Ch.sq].contains(b[j]) && j == i { break }
                j += 1
            }
        }
        if let keyEnd {
            emit(i, keyEnd, .type)
            i = nextNonSpace(keyEnd + 1)
        }
        yamlValue()
    }

    mutating func yamlValue() {
        while i < n {
            let c = b[i]
            if Ch.isSpace(c) { i += 1; continue }
            if c == Ch.hash && (i == 0 || Ch.isSpace(b[i - 1])) { emit(i, n, .comment); return }
            if c == Ch.dq || c == Ch.sq {
                let (end, _) = scanString(from: i + 1, close: [c], escapes: c == Ch.dq)
                emit(i, end, .string)
                i = end
                continue
            }
            // A plain scalar: up to a comment or the end.
            var j = i
            while j < n, !(b[j] == Ch.hash && j > i && Ch.isSpace(b[j - 1])) { j += 1 }
            var end = j
            while end > i, Ch.isSpace(b[end - 1]) { end -= 1 }
            let word = String(decoding: b[i..<end], as: UTF8.self)
            if ["true", "false", "null", "yes", "no", "on", "off", "~", "True", "False", "Null", "|", ">", "|-", ">-"].contains(word)
                || c == Ch.amp || c == Ch.star || c == Ch.bang {
                emit(i, end, .keyword)
            } else if let first = word.utf8.first, Ch.isDigit(first) || first == Ch.dash || first == Ch.plus || first == Ch.dot,
                      Double(word) != nil || (word.hasPrefix("0x") && Int(word.dropFirst(2), radix: 16) != nil) {
                emit(i, end, .number)
            }
            i = j
        }
    }
}

/// Coloured runs for the lines a diff panel shows, per file version. Work happens off the
/// main thread, one page at a time: a page extends each hunk from where the last one stopped,
/// carrying the old side's state through context and removed lines and the new side's
/// through context and added ones.
final class SyntaxCache: @unchecked Sendable {
    static let shared = SyntaxCache()

    private struct Progress {
        var done = 0
        var old = LexState.normal
        var new = LexState.normal
    }

    private struct Entry {
        var spans: [Int: [TokenSpan]] = [:]
        var hunks: [Int: Progress] = [:]
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private static let capacity = 64

    /// Where a hunk starts. Hunks begin wherever git cut them, often inside a docstring or a
    /// block comment, which would read inside out from a plain start. The new side is lexed
    /// once from plain; if it ends inside a string or comment, starting there instead is tried,
    /// and kept when that run ends plain.
    static func startState(of hunk: FileDiff.Hunk, _ language: CodeLanguage) -> LexState {
        func end(from start: LexState) -> LexState {
            var state = start
            for line in hunk.lines where line.kind != .removed { _ = Syntax.tokenize(line.text, language, &state) }
            return state
        }
        let plain = end(from: .normal)
        switch plain {
        case .string, .comment:
            return end(from: plain) == .normal ? plain : .normal
        default:
            return .normal
        }
    }

    /// Runs worked out so far for this version, keyed by line id.
    func spans(for version: UUID) -> [Int: [TokenSpan]]? {
        lock.withLock { entries[version]?.spans }
    }

    /// Colours the given (already paged) hunks and returns every run known for the version.
    /// `fullHunks` are the hunks in full, so a long hunk stays plain even when only a page of
    /// it shows, and a hunk's start state is judged from all of it. Async and nonisolated, so it runs off the main thread and stops
    /// early (keeping what it finished) when the panel's task is cancelled.
    func highlight(version: UUID, language: CodeLanguage, hunks: [FileDiff.Hunk], fullHunks: [FileDiff.Hunk]) async -> [Int: [TokenSpan]] {
        var entry = lock.withLock { entries[version] } ?? Entry()
        guard language != .plain else { return [:] }
        let full = Dictionary(uniqueKeysWithValues: fullHunks.map { ($0.id, $0) })

        var changed = false
        hunkLoop: for hunk in hunks where (full[hunk.id]?.lines.count ?? hunk.lines.count) <= Syntax.maxHunkLines {
            var progress = entry.hunks[hunk.id] ?? Progress()
            guard progress.done < hunk.lines.count else { continue }
            if progress.done == 0, let whole = full[hunk.id] {
                let start = Self.startState(of: whole, language)
                progress.old = start
                progress.new = start
            }
            for line in hunk.lines[progress.done...] {
                if Task.isCancelled { entry.hunks[hunk.id] = progress; changed = true; break hunkLoop }
                switch line.kind {
                case .added:
                    entry.spans[line.id] = Syntax.tokenize(line.text, language, &progress.new)
                case .removed:
                    entry.spans[line.id] = Syntax.tokenize(line.text, language, &progress.old)
                case .context:
                    // Shown with the new side's colours; the old side only needs its own pass
                    // when the two have drifted apart (a comment opened on one side only).
                    let same = progress.old == progress.new
                    let spans = Syntax.tokenize(line.text, language, &progress.new)
                    if same {
                        progress.old = progress.new
                    } else {
                        _ = Syntax.tokenize(line.text, language, &progress.old)
                    }
                    entry.spans[line.id] = spans
                }
                progress.done += 1
            }
            entry.hunks[hunk.id] = progress
            changed = true
        }

        return lock.withLock { () -> [Int: [TokenSpan]] in
        if changed {
            // Another page may have landed meanwhile; keep whichever went further per hunk.
            if let current = entries[version] {
                for (id, p) in current.hunks where p.done > (entry.hunks[id]?.done ?? 0) {
                    entry.hunks[id] = p
                }
                entry.spans.merge(current.spans) { mine, _ in mine }
            } else {
                order.append(version)
                if order.count > Self.capacity { entries[order.removeFirst()] = nil }
            }
            entries[version] = entry
        }
        return entries[version]?.spans ?? entry.spans
        }
    }
}
