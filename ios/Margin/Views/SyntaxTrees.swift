import SwiftTreeSitter
import SwiftUI
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterLua
import TreeSitterPHP
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// Syntax colouring from tree-sitter: the code is parsed, and each grammar's
/// own highlights.scm says what every piece is (keyword, string, function,
/// type…), the way GitHub, Zed and Neovim colour code. Languages without a
/// grammar here fall back to `Highlighter`'s regexes.
enum SyntaxTrees {
    private struct Grammar {
        let language: () -> OpaquePointer?
        let bundle: String                       // TreeSitterX_TreeSitterY: where its queries are
        var queries = ["highlights.scm"]
        var inherits: [(bundle: String, file: String)] = []    // e.g. TypeScript builds on JavaScript's
    }

    private static let js = "TreeSitterJavaScript_TreeSitterJavaScript"
    private static let grammars: [String: Grammar] = {
        let jsBase: [(bundle: String, file: String)] = [(js, "highlights.scm")]
        var g: [String: Grammar] = [
            "swift": Grammar(language: { tree_sitter_swift() }, bundle: "TreeSitterSwift_TreeSitterSwift"),
            "python": Grammar(language: { tree_sitter_python() }, bundle: "TreeSitterPython_TreeSitterPython"),
            "javascript": Grammar(language: { tree_sitter_javascript() }, bundle: js,
                                  queries: ["highlights.scm", "highlights-jsx.scm"]),
            "typescript": Grammar(language: { tree_sitter_typescript() },
                                  bundle: "TreeSitterTypeScript_TreeSitterTypeScript", inherits: jsBase),
            "tsx": Grammar(language: { tree_sitter_tsx() }, bundle: "TreeSitterTypeScript_TreeSitterTSX",
                           inherits: jsBase + [(js, "highlights-jsx.scm")]),
            "rust": Grammar(language: { tree_sitter_rust() }, bundle: "TreeSitterRust_TreeSitterRust"),
            "go": Grammar(language: { tree_sitter_go() }, bundle: "TreeSitterGo_TreeSitterGo"),
            "c": Grammar(language: { tree_sitter_c() }, bundle: "TreeSitterC_TreeSitterC"),
            "cpp": Grammar(language: { tree_sitter_cpp() }, bundle: "TreeSitterCPP_TreeSitterCPP",
                           inherits: [("TreeSitterC_TreeSitterC", "highlights.scm")]),
            "java": Grammar(language: { tree_sitter_java() }, bundle: "TreeSitterJava_TreeSitterJava"),
            "json": Grammar(language: { tree_sitter_json() }, bundle: "TreeSitterJSON_TreeSitterJSON"),
            "bash": Grammar(language: { tree_sitter_bash() }, bundle: "TreeSitterBash_TreeSitterBash"),
            "html": Grammar(language: { tree_sitter_html() }, bundle: "TreeSitterHTML_TreeSitterHTML"),
            "css": Grammar(language: { tree_sitter_css() }, bundle: "TreeSitterCSS_TreeSitterCSS"),
            "ruby": Grammar(language: { tree_sitter_ruby() }, bundle: "TreeSitterRuby_TreeSitterRuby"),
            "php": Grammar(language: { tree_sitter_php() }, bundle: "TreeSitterPHP_TreeSitterPHP"),
            "lua": Grammar(language: { tree_sitter_lua() }, bundle: "TreeSitterLua_TreeSitterLua"),
            "toml": Grammar(language: { tree_sitter_toml() }, bundle: "TreeSitterTOML_TreeSitterTOML"),
            "yaml": Grammar(language: { tree_sitter_yaml() }, bundle: "TreeSitterYAML_TreeSitterYAML"),
        ]
        g["jsx"] = g["javascript"]
        return g
    }()

    private static let aliases: [String: String] = [
        "py": "python", "js": "javascript", "mjs": "javascript", "cjs": "javascript", "ts": "typescript",
        "mts": "typescript", "rs": "rust", "h": "c", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
        "c++": "cpp", "ino": "cpp", "sh": "bash", "zsh": "bash", "shell": "bash", "console": "bash",
        "jsonc": "json", "yml": "yaml", "rb": "ruby", "htm": "html", "xhtml": "html", "vue": "html",
        "svelte": "html", "scss": "css",
    ]

    /// The grammar for a fence info string or file extension, if there is one.
    static func supports(_ lang: String) -> Bool { grammars[aliases[lang] ?? lang] != nil }

    // Parsed queries, one per language, built the first time it's needed.
    @MainActor private static var loaded: [String: (Language, Query)?] = [:]

    @MainActor
    private static func load(_ name: String) -> (Language, Query)? {
        if let hit = loaded[name] { return hit }
        var result: (Language, Query)?
        if let g = grammars[name], let ptr = g.language() {
            let language = Language(language: ptr)
            let parts = g.inherits + g.queries.map { (g.bundle, $0) }
            let source = parts.compactMap { read($0.bundle, $0.file) }.joined(separator: "\n")
            if !source.isEmpty, let q = try? Query(language: language, data: Data(source.utf8)) {
                result = (language, q)
            }
        }
        loaded[name] = result
        return result
    }

    private static func read(_ bundle: String, _ file: String) -> String? {
        guard let dir = Bundle.main.url(forResource: bundle, withExtension: "bundle") else { return nil }
        for sub in ["queries/" + file, "Contents/Resources/queries/" + file] {
            if let s = try? String(contentsOf: dir.appendingPathComponent(sub), encoding: .utf8) { return s }
        }
        return nil
    }

    /// What to colour where, for a language with a grammar here (nil otherwise).
    /// Most general first, so a narrower capture inside it wins; among
    /// captures of exactly the same text the grammar's earlier pattern wins.
    @MainActor
    static func spans(_ code: String, language lang: String) -> [(NSRange, Color)]? {
        guard let (language, query) = load(aliases[lang] ?? lang) else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil, let tree = parser.parse(code) else { return nil }
        let found = query.execute(in: tree).resolve(with: .init(string: code)).highlights()
        let length = (code as NSString).length
        var done = Set<NSRange>()
        var out: [(NSRange, Color)] = []
        for h in found {
            let r = NSRange(location: Int(h.tsRange.bytes.lowerBound) / 2,
                            length: Int(h.tsRange.bytes.upperBound - h.tsRange.bytes.lowerBound) / 2)
            guard r.length > 0, NSMaxRange(r) <= length, !done.contains(r),
                  let c = color(h.nameComponents) else { continue }    // an uncoloured match (a plain name) doesn't block a later one
            done.insert(r)
            out.append((r, c))
        }
        return out
    }

    /// Colours `out` (whose text is `code`) in place. False when there's no
    /// grammar for the language.
    @MainActor
    static func colour(_ out: inout AttributedString, code: String, language lang: String) -> Bool {
        guard let spans = spans(code, language: lang) else { return false }
        for (r, c) in spans {
            if let range = Range(r, in: out) { out[range].foregroundColor = c }
        }
        return true
    }

    /// A capture name (`keyword.function`, `string.special`…) as a colour.
    private static func color(_ name: [String]) -> Color? {
        let first = name.first ?? ""
        let second = name.count > 1 ? name[1] : ""
        switch first {
        case "comment": return Highlighter.comment
        case "string", "character":
            return second == "escape" || second == "special" || second == "regex" ? Highlighter.attr : Highlighter.string
        case "escape": return Highlighter.attr
        case "number", "float", "boolean": return Highlighter.number
        case "constant": return second == "builtin" ? Highlighter.number : Highlighter.number.opacity(0.85)
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass", "tag":
            return Highlighter.keyword
        case "type", "constructor", "module", "namespace": return Highlighter.type
        case "function", "method": return Highlighter.function
        case "attribute", "label", "annotation": return Highlighter.attr
        case "variable": return second == "builtin" ? Highlighter.keyword : nil
        case "property": return Highlighter.property
        default: return nil       // operators, punctuation, plain names
        }
    }
}
