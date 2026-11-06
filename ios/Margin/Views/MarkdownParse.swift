import Foundation
import Markdown
import SwiftUI

/// Markdown read with Apple's swift-markdown (cmark-gfm: CommonMark plus
/// GitHub's tables, task lists and strikethrough), turned into the blocks
/// `MarkdownText` draws. Its node types share names with SwiftUI's (Text,
/// Image, Table), hence this file of its own and the `Markdown.` prefixes.
enum MarkdownBlocks {
    struct ListItem {
        let depth: Int
        let marker: String
        var checked: Bool?              // a task list item: [x] or [ ]
        let text: AttributedString
        var more: [Block] = []          // code, quotes or further paragraphs inside the item
    }

    enum Block {
        case heading(Int, AttributedString)
        case paragraph(AttributedString)
        case list([ListItem])
        case quote([Block])
        case table([AttributedString], [[AttributedString]])
        case code(String, String?)
        case rule
    }

    private final class Box { let blocks: [Block]; init(_ b: [Block]) { blocks = b } }
    private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 300
        return c
    }()

    static func parse(_ text: String) -> [Block] {
        if let hit = cache.object(forKey: text as NSString) { return hit.blocks }
        // Quotes and dashes stay as written (no smart punctuation).
        let doc = Document(parsing: text, options: [.disableSmartOpts])
        let out = blocks(doc.children)
        cache.setObject(Box(out), forKey: text as NSString)
        return out
    }

    private static func blocks(_ nodes: MarkupChildren) -> [Block] {
        var out: [Block] = []
        for node in nodes { out += block(node) }
        return out
    }

    private static func block(_ node: any Markdown.Markup) -> [Block] {
        switch node {
        case let h as Heading:
            return [.heading(h.level, inline(h.children))]
        case let p as Paragraph:
            return [.paragraph(inline(p.children))]
        case let c as CodeBlock:
            var code = c.code
            if code.hasSuffix("\n") { code.removeLast() }
            let lang = c.language?.split(separator: " ").first.map(String.init)
            return [.code(code, lang?.isEmpty == false ? lang : nil)]
        case let q as BlockQuote:
            return [.quote(blocks(q.children))]
        case let l as UnorderedList:
            return [.list(items(l, depth: 0))]
        case let l as OrderedList:
            return [.list(items(l, depth: 0))]
        case let t as Markdown.Table:
            let header = t.head.cells.map { inline($0.children) }
            let rows = t.body.rows.map { row in Array(row.cells.map { inline($0.children) }) }
            return [.table(Array(header), Array(rows))]
        case is ThematicBreak:
            return [.rule]
        case let h as HTMLBlock:
            let raw = h.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? [] : [.paragraph(AttributedString(raw))]
        default:
            return blocks(node.children)
        }
    }

    /// A list flattened to rows with depths; nested lists become deeper rows,
    /// anything else in an item (code, a quote) hangs under that item.
    private static func items(_ list: ListItemContainer, depth: Int) -> [ListItem] {
        var out: [ListItem] = []
        let start = (list as? OrderedList).map { Int($0.startIndex) }
        for (i, item) in list.listItems.enumerated() {
            var text = AttributedString()
            var more: [Block] = []
            var nested: [ListItem] = []
            for child in item.children {
                switch child {
                case let p as Paragraph where text.characters.isEmpty && more.isEmpty:
                    text = inline(p.children)
                case let l as ListItemContainer:
                    nested += items(l, depth: depth + 1)
                default:
                    more += block(child)
                }
            }
            let checked: Bool? = item.checkbox.map { $0 == .checked }
            out.append(ListItem(depth: min(depth, 4), marker: start.map { "\($0 + i)." } ?? "•",
                                checked: checked, text: text, more: more))
            out += nested
        }
        return out
    }

    /// A one-line title as Claude wrote it (`code`, **bold**), without the marks showing.
    static func title(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    // MARK: inline

    /// Inline Markdown as styled text. Links stay links (the surrounding view
    /// decides what opening one does); images become links to the file (the
    /// picture itself is shown below the text); bare URLs and backticked file
    /// paths become tappable; `code` is monospaced on a faint chip.
    private static func inline(_ nodes: MarkupChildren, _ intent: InlinePresentationIntent = []) -> AttributedString {
        var out = AttributedString()
        for node in nodes { out += inline(node, intent) }
        return out
    }

    private static func inline(_ node: any Markdown.Markup, _ intent: InlinePresentationIntent) -> AttributedString {
        switch node {
        case let t as Markdown.Text:
            return linkingURLs(t.string, intent)
        case let e as Emphasis:
            return inline(e.children, intent.union(.emphasized))
        case let s as Strong:
            return inline(s.children, intent.union(.stronglyEmphasized))
        case let s as Strikethrough:
            return inline(s.children, intent.union(.strikethrough))
        case let c as InlineCode:
            var a = styled(c.code, intent.union(.code))
            a.backgroundColor = SwiftUI.Color.secondary.opacity(0.14)
            if looksLikeFile(c.code), let url = URL(string: "margin-file:" + escape(c.code)) { a.link = url }
            return a
        case let l as Markdown.Link:
            var a = inline(l.children, intent)
            if a.characters.isEmpty { a = styled(l.destination ?? "", intent) }
            if let d = l.destination, let url = URL(string: d) ?? URL(string: escape(d)) { a.link = url }
            return a
        case let i as Markdown.Image:
            let src = i.source ?? ""
            let alt = i.plainText
            var a = styled(alt.isEmpty ? (src as NSString).lastPathComponent : alt, intent)
            if let url = URL(string: src) ?? URL(string: escape(src)) { a.link = url }
            return a
        case is SoftBreak, is LineBreak:
            return styled("\n", intent)     // Claude's line breaks read as it wrote them
        case let h as InlineHTML:
            return styled(h.rawHTML, intent)
        default:
            return inline(node.children, intent)
        }
    }

    private static func styled(_ s: String, _ intent: InlinePresentationIntent) -> AttributedString {
        var a = AttributedString(s)
        if !intent.isEmpty { a.inlinePresentationIntent = intent }
        return a
    }

    private static let bareURLRe = try! NSRegularExpression(pattern: #"\bhttps?://[^\s<>()\[\]`]+[^\s<>()\[\]`.,;:!?'"]"#)

    private static func linkingURLs(_ s: String, _ intent: InlinePresentationIntent) -> AttributedString {
        let ns = s as NSString
        var out = AttributedString()
        var last = 0
        for m in bareURLRe.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += styled(ns.substring(with: NSRange(location: last, length: m.range.location - last)), intent)
            let u = ns.substring(with: m.range)
            var a = styled(u, intent)
            a.link = URL(string: u)
            out += a
            last = NSMaxRange(m.range)
        }
        out += styled(ns.substring(from: last), intent)
        return out
    }

    private static let fileExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "pdf", "stl", "obj", "ply", "usdz", "step", "stp",
        "kicad_sch", "kicad_pcb", "kicad_pro", "md", "txt", "csv", "json", "toml", "yaml", "yml", "py", "c", "h",
        "cpp", "hpp", "rs", "go", "js", "ts", "tsx", "vue", "swift", "sh", "html", "css", "ini", "cfg", "log",
    ]

    private static let pathRe = try! NSRegularExpression(pattern: #"^[\w.~-]*/?[\w./~-]*\.[A-Za-z][A-Za-z0-9_]{0,11}$"#)

    private static func looksLikeFile(_ p: String) -> Bool {
        guard pathRe.firstMatch(in: p, range: NSRange(location: 0, length: (p as NSString).length)) != nil else { return false }
        let ext = (p as NSString).pathExtension.lowercased()
        return fileExts.contains(ext) && !p.hasPrefix(".") || (p.contains("/") && !ext.isEmpty)
    }

    private static func escape(_ p: String) -> String {
        p.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))) ?? p
    }
}
