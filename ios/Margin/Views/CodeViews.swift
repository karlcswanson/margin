import SwiftUI
import UIKit

// MARK: - Highlighter

/// Syntax colouring. Languages with a tree-sitter grammar are parsed (see
/// `SyntaxTrees`); the rest get a small regex pass: comments, strings,
/// numbers, keywords, types, and tags for markup.
@MainActor
enum Highlighter {
    private struct Grammar {
        var lineComment: String?
        var blockComment: (String, String)?
        var strings = #""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'"#
        var keywords: Set<String> = []
        var markup = false
    }

    private static let cKeywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
        "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short",
        "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile",
        "while", "bool", "true", "false", "NULL", "nullptr", "class", "public", "private", "protected",
        "namespace", "template", "typename", "using", "virtual", "override", "new", "delete", "this",
        "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t", "size_t",
        "#include", "#define", "#if", "#ifdef", "#ifndef", "#endif", "#else", "#elif", "#pragma",
    ]
    private static let jsKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do",
        "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in",
        "instanceof", "interface", "let", "new", "null", "of", "return", "static", "super", "switch", "this",
        "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield", "enum",
        "implements", "private", "public", "readonly", "as",
    ]
    private static let swiftKeywords: Set<String> = [
        "actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer",
        "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func",
        "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "open", "private",
        "protocol", "public", "repeat", "return", "self", "Self", "some", "any", "static", "struct", "subscript",
        "super", "switch", "throw", "throws", "true", "try", "var", "where", "while", "@State", "@Binding",
        "@MainActor", "@Observable", "@Environment",
    ]
    private static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "else", "enum", "extern", "false", "fn",
        "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
        "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while", "dyn",
    ]
    private static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func",
        "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct",
        "switch", "type", "var", "nil", "true", "false",
    ]
    private static let pyKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
        "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None",
        "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield", "self",
        "match", "case",
    ]
    private static let shKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in", "function",
        "return", "export", "local", "set", "unset", "echo", "cd", "source", "exit", "sudo",
    ]

    private static func grammar(_ lang: String) -> Grammar? {
        switch lang {
        case "c", "h", "cpp", "cc", "hpp", "c++", "objc", "m", "java", "kotlin", "kt", "cs", "csharp", "ino":
            return Grammar(lineComment: "//", blockComment: ("/*", "*/"), keywords: cKeywords)
        case "js", "jsx", "ts", "tsx", "javascript", "typescript", "mjs", "cjs", "vue", "svelte":
            return Grammar(lineComment: "//", blockComment: ("/*", "*/"),
                           strings: #""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`"#,
                           keywords: jsKeywords)
        case "swift":
            return Grammar(lineComment: "//", blockComment: ("/*", "*/"), strings: #""(?:\\.|[^"\\\n])*""#,
                           keywords: swiftKeywords)
        case "rust", "rs":
            return Grammar(lineComment: "//", blockComment: ("/*", "*/"), strings: #""(?:\\.|[^"\\])*""#,
                           keywords: rustKeywords)
        case "go":
            return Grammar(lineComment: "//", blockComment: ("/*", "*/"),
                           strings: #""(?:\\.|[^"\\\n])*"|`[^`]*`"#, keywords: goKeywords)
        case "python", "py":
            return Grammar(lineComment: "#",
                           strings: #"(?:[rbfu]{0,2})(?:"""[\s\S]*?"""|'''[\s\S]*?'''|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')"#,
                           keywords: pyKeywords)
        case "sh", "bash", "zsh", "shell", "console", "fish":
            return Grammar(lineComment: "#", keywords: shKeywords)
        case "toml", "yaml", "yml", "ini", "cfg", "conf", "dockerfile", "make", "makefile", "cmake":
            return Grammar(lineComment: "#", keywords: ["true", "false", "null"])
        case "json", "jsonc":
            return Grammar(lineComment: "//", strings: #""(?:\\.|[^"\\\n])*""#, keywords: ["true", "false", "null"])
        case "css", "scss":
            return Grammar(blockComment: ("/*", "*/"), keywords: ["!important"])
        case "sql":
            return Grammar(lineComment: "--", blockComment: ("/*", "*/"),
                           keywords: ["select", "from", "where", "insert", "into", "values", "update", "set",
                                      "delete", "create", "table", "join", "left", "right", "on", "and", "or",
                                      "not", "null", "order", "by", "group", "limit", "as", "SELECT", "FROM",
                                      "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE",
                                      "TABLE", "JOIN", "ON", "AND", "OR", "NOT", "NULL", "ORDER", "BY", "GROUP",
                                      "LIMIT", "AS"])
        case "html", "xml", "svg", "plist", "xhtml":
            return Grammar(blockComment: ("<!--", "-->"), markup: true)
        case "ruby", "rb":
            return Grammar(lineComment: "#", keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless",
                "while", "do", "return", "yield", "nil", "true", "false", "self", "require", "begin", "rescue", "ensure"])
        case "lua":
            return Grammar(lineComment: "--", keywords: ["function", "end", "local", "if", "then", "elseif", "else",
                "for", "while", "do", "return", "nil", "true", "false", "and", "or", "not", "repeat", "until"])
        case "php":
            return Grammar(lineComment: "//", blockComment: ("/*", "*/"), keywords: jsKeywords.union(["echo", "function", "namespace", "use"]))
        case "kicad", "kicad_sch", "kicad_pcb", "lisp", "scheme", "sexp":
            return Grammar(lineComment: ";", strings: #""(?:\\.|[^"\\])*""#)
        default:
            return nil
        }
    }

    /// Language name for a file path, for picking a grammar.
    static func language(forPath path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "makefile" { return "make" }
        if name == "dockerfile" { return "dockerfile" }
        if name == "cmakelists.txt" { return "cmake" }
        return (name as NSString).pathExtension
    }

    static let keyword = Theme.Code.keyword
    static let string = Theme.Code.string
    static let comment = Theme.Code.comment
    static let number = Theme.Code.number
    static let type = Theme.Code.type
    static let attr = Theme.Code.attribute
    static let function = Theme.Code.function
    static let property = Theme.Code.property

    private static let cache = NSCache<NSString, Box>()
    private final class Box { let value: AttributedString; init(_ v: AttributedString) { value = v } }

    static func highlight(_ code: String, language: String?) -> AttributedString {
        let lang = (language ?? "").lowercased()
        let key = "\(lang)\u{0}\(code)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        var out = AttributedString(code)
        if ["diff", "patch"].contains(lang) {
            diff(&out, code: code)
        } else if code.utf16.count <= 300_000, SyntaxTrees.colour(&out, code: code, language: lang) {
            // parsed
        } else if let g = grammar(lang), code.utf16.count <= 150_000 {
            apply(g, to: &out, code: code)
        }
        cache.setObject(Box(out), forKey: key)
        return out
    }

    /// Lines that belong together (a diff hunk), coloured as one piece of
    /// code so a line inside a string or a function reads right. Removed and
    /// added lines are parsed separately, each with the unchanged lines, the
    /// way the old and the new file read.
    static func hunk(_ lines: [(kind: Character, text: String)], language: String) -> [AttributedString] {
        var out = lines.map { AttributedString($0.text.isEmpty ? " " : $0.text) }
        for side: Character in ["-", "+"] {
            let idx = lines.indices.filter { lines[$0].kind != (side == "-" ? "+" : "-") }
            let whole = highlight(idx.map { lines[$0].text }.joined(separator: "\n"), language: language)
            var start = whole.startIndex
            for i in idx {
                let end = whole.index(start, offsetByCharacters: lines[i].text.count)
                // Unchanged lines take the new file's colours; changed ones their own side's.
                if side == "+" || lines[i].kind == "-" {
                    out[i] = lines[i].text.isEmpty ? AttributedString(" ") : AttributedString(whole[start..<end])
                }
                start = end < whole.endIndex ? whole.index(afterCharacter: end) : end
            }
        }
        return out
    }

    private static func apply(_ g: Grammar, to out: inout AttributedString, code: String) {
        var alts: [String] = []
        if let (a, b) = g.blockComment {
            alts.append("(?<c1>" + NSRegularExpression.escapedPattern(for: a) + "[\\s\\S]*?"
                        + "(?:" + NSRegularExpression.escapedPattern(for: b) + "|$))")
        }
        if let lc = g.lineComment {
            // '#' only starts a comment at line start or after whitespace (not in "a#b" or colors)
            let p = lc == "#" ? "(?:^|(?<=\\s))#[^\\n]*" : NSRegularExpression.escapedPattern(for: lc) + "[^\\n]*"
            alts.append("(?<c2>" + p + ")")
        }
        if g.markup {
            alts.append("(?<tag></?[A-Za-z][\\w:.-]*|/?>)")
            alts.append("(?<attr>[\\w:-]+(?==))")
        }
        alts.append("(?<s>" + g.strings + ")")
        alts.append("(?<n>\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)[a-zA-Z]*\\b)")
        if !g.markup {
            alts.append("(?<w>#?@?[A-Za-z_][A-Za-z0-9_]*)")
        }
        guard let re = try? NSRegularExpression(pattern: alts.joined(separator: "|"),
                                                options: [.anchorsMatchLines]) else { return }
        let ns = code as NSString
        for m in re.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            let color: Color?
            if hit(m, "c1") || hit(m, "c2") { color = comment }
            else if hit(m, "s") { color = string }
            else if hit(m, "n") { color = number }
            else if hit(m, "tag") { color = keyword }
            else if hit(m, "attr") { color = attr }
            else if hit(m, "w") {
                let word = ns.substring(with: m.range)
                if g.keywords.contains(word) { color = keyword }
                else if let f = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(f),
                        word.count > 1, word.uppercased() != word { color = type }
                else { color = nil }
            } else { color = nil }
            if let color, let r = Range(m.range, in: out) {
                out[r].foregroundColor = color
            }
        }
    }

    /// Unified diffs: added lines green, removed red, hunk headers blue.
    private static func diff(_ out: inout AttributedString, code: String) {
        var start = out.startIndex
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let end = out.index(start, offsetByCharacters: line.count)
            let color: Color? = line.hasPrefix("+++") || line.hasPrefix("---") ? attr
                : line.hasPrefix("+") ? Color(uiColor: .systemGreen)
                : line.hasPrefix("-") ? Color(uiColor: .systemRed)
                : line.hasPrefix("@@") ? function : nil
            if let color { out[start..<end].foregroundColor = color }
            start = end < out.endIndex ? out.index(afterCharacter: end) : end
        }
    }

    private static func hit(_ m: NSTextCheckingResult, _ name: String) -> Bool {
        m.range(withName: name).location != NSNotFound
    }
}

// MARK: - Code block

/// Highlighted, horizontally scrolling code with an optional line-number
/// gutter, a header (file name or language) with a copy button, and a
/// collapsed preview for long code.
struct CodeBlock: View {
    let code: String
    var language: String?
    var title: String?
    var lineNumbers = false
    var startLine = 1
    var collapsedLines: Int? = nil

    @State private var expanded = false
    @State private var copied = false

    private var lines: [Substring] { code.split(separator: "\n", omittingEmptySubsequences: false) }

    var body: some View {
        let all = lines
        let limit = (collapsedLines != nil && !expanded) ? collapsedLines! : Int.max
        let shown = all.count > limit ? all.prefix(limit).joined(separator: "\n") : code
        VStack(alignment: .leading, spacing: 0) {
            header(lineCount: all.count)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    if lineNumbers {
                        Text((0..<min(all.count, limit)).map { String(startLine + $0) }.joined(separator: "\n"))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.trailing)
                    }
                    Text(Highlighter.highlight(shown, language: language))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .inkAnchor("code-\(title ?? "")-\(startLine)-\(code.hashValue)") { [title, startLine] r, size in
                            // Monospaced, one line per row: the rows under the ink are the lines.
                            let rows = shown.split(separator: "\n", omittingEmptySubsequences: false)
                            guard !rows.isEmpty, size.height > 0 else { return nil }
                            let h = size.height / CGFloat(rows.count)
                            let a = max(0, min(rows.count - 1, Int(r.minY / h)))
                            let b = max(a, min(rows.count - 1, Int(max(r.minY, r.maxY - 1) / h)))
                            let first = startLine + a, last = startLine + b
                            let lines = rows[a...min(b, a + 11)].joined(separator: "\n")
                            return "\(title ?? "code") \(first == last ? "line \(first)" : "lines \(first)–\(last)"):\n```\n\(lines)\n```"
                        }
                }
                .font(.system(.footnote, design: .monospaced))
                .padding(10)
            }
            if all.count > limit || (expanded && collapsedLines != nil && all.count > collapsedLines!) {
                Button(expanded ? "Show less" : "Show all \(all.count) lines") {
                    withAnimation { expanded.toggle() }
                }
                .font(Theme.Fonts.caption)
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(uiColor: .separator).opacity(0.5)))
    }

    private func header(lineCount: Int) -> some View {
        HStack(spacing: 8) {
            Text(title ?? (language?.isEmpty == false ? language! : "code"))
                .font(Theme.Fonts.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer()
            Button {
                UIPasteboard.general.string = code
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(Theme.Fonts.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10).padding(.top, 8)
    }
}

// MARK: - Diff

/// Line diff of an Edit (old → new), red/green with +/- markers.
struct DiffBlock: View {
    let path: String?
    let edits: [(old: String, new: String)]
    var collapsedLines = 14

    @State private var expanded = false

    private struct Line: Hashable { let mark: Character; let text: String }

    var body: some View {
        let lines = edits.enumerated().flatMap { i, e in
            (i > 0 ? [Line(mark: "~", text: "")] : []) + Self.diff(e.old, e.new)
        }
        let added = lines.filter { $0.mark == "+" }.count
        let removed = lines.filter { $0.mark == "-" }.count
        let shown = expanded ? lines : Array(lines.prefix(collapsedLines))
        let lang = path.map(Highlighter.language(forPath:))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(path.map { ($0 as NSString).lastPathComponent } ?? "edit")
                    .font(Theme.Fonts.caption.weight(.medium)).foregroundStyle(.secondary)
                Text("+\(added)").font(Theme.Fonts.caption.monospacedDigit()).foregroundStyle(.green)
                Text("−\(removed)").font(Theme.Fonts.caption.monospacedDigit()).foregroundStyle(.red)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, l in
                        if l.mark == "~" {
                            Text("⋯").foregroundStyle(.tertiary).padding(.horizontal, 10)
                        } else {
                            HStack(spacing: 6) {
                                Text(String(l.mark == " " ? " " : l.mark == "-" ? "−" : "+"))
                                    .foregroundStyle(l.mark == "+" ? .green : l.mark == "-" ? .red : .secondary)
                                Text(Highlighter.highlight(l.text.isEmpty ? " " : l.text, language: lang))
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(l.mark == "+" ? Color.green.opacity(0.14)
                                        : l.mark == "-" ? Color.red.opacity(0.14) : Color.clear)
                        }
                    }
                }
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .padding(.bottom, 8)
            }
            if lines.count > collapsedLines {
                Button(expanded ? "Show less" : "Show all \(lines.count) lines") {
                    withAnimation { expanded.toggle() }
                }
                .font(Theme.Fonts.caption).padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(uiColor: .separator).opacity(0.5)))
    }

    /// LCS line diff; falls back to "all removed, all added" for huge edits.
    private static func diff(_ a: String, _ b: String) -> [Line] {
        let x = a.components(separatedBy: "\n"), y = b.components(separatedBy: "\n")
        if x.count * y.count > 1_000_000 {
            return x.map { Line(mark: "-", text: $0) } + y.map { Line(mark: "+", text: $0) }
        }
        let n = x.count, m = y.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = x[i] == y[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, x[i] == y[j] { out.append(Line(mark: " ", text: x[i])); i += 1; j += 1 }
            else if j < m, i == n || dp[i][j + 1] >= dp[i + 1][j] { out.append(Line(mark: "+", text: y[j])); j += 1 }
            else { out.append(Line(mark: "-", text: x[i])); i += 1 }
        }
        return out
    }
}

// MARK: - Read output

/// Claude Code's Read results come as "   12→code"; split off the numbers so
/// the code can be highlighted with a real gutter.
func parseNumberedListing(_ s: String) -> (code: String, start: Int)? {
    var start: Int?
    var lines: [Substring] = []
    for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let arrow = raw.firstIndex(of: "→") else {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            return nil
        }
        guard let n = Int(raw[..<arrow].trimmingCharacters(in: .whitespaces)) else { return nil }
        if start == nil { start = n }
        lines.append(raw[raw.index(after: arrow)...])
    }
    guard let start, !lines.isEmpty else { return nil }
    return (lines.joined(separator: "\n"), start)
}
