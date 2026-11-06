import SwiftUI

/// Markdown as Claude writes it: headings, paragraphs, bullet and numbered
/// lists, quotes, tables, rules and fenced code (highlighted). Links are
/// tappable; bare URLs and `path/to/file.ext` mentions become links too, and
/// the surrounding view decides what opening one does (see `ProjectLinks`).
struct MarkdownText: View {
    let blocks: [MarkdownBlocks.Block]
    var color: Color = .primary
    var document = false        // document typography (proposals, .md files)

    init(text: String, color: Color = .primary, document: Bool = false) {
        self.init(blocks: MarkdownBlocks.parse(text), color: color, document: document)
    }

    init(blocks: [MarkdownBlocks.Block], color: Color = .primary, document: Bool = false) {
        self.blocks = blocks
        self.color = color
        self.document = document
    }

    var body: some View {
        VStack(alignment: .leading, spacing: document ? Theme.blockSpacing : 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                if let words = Self.words(block) {
                    view(for: block).inkAnchor("md\(i)-\(words.hashValue)", words)
                } else {
                    view(for: block)
                }
            }
        }
        .foregroundStyle(color)
    }

    /// A block as Claude would quote it back (code and mockups say what's under the ink themselves).
    static func words(_ block: MarkdownBlocks.Block) -> String? {
        let clip = { (s: String) in s.count > 400 ? String(s.prefix(400)) + "…" : s }
        let plain = { (a: AttributedString) in String(a.characters) }
        switch block {
        case .heading(_, let s): return "heading “\(clip(plain(s)))”"
        case .paragraph(let s): return "“\(clip(plain(s)))”"
        case .list(let items): return "list: " + clip(items.map { "“\(plain($0.text))”" }.joined(separator: "; "))
        case .quote(let b): return "quote “\(clip(b.compactMap { words($0) }.joined(separator: " ")))”"
        case .table(let h, let rows): return "table (\(h.map(plain).joined(separator: " | "))), \(rows.count) rows"
        case .code, .rule: return nil
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlocks.Block) -> some View {
        switch block {
        case .heading(let level, let s):
            Text(s)
                .font(level == 1 ? (document ? Theme.Fonts.h1 : .title3.weight(.semibold))
                      : level == 2 ? (document ? Theme.Fonts.h2 : .headline) : Theme.Fonts.h3)
                .padding(.top, document && level <= 2 ? 6 : 2)
                .textSelection(.enabled)
        case .paragraph(let s):
            Text(s)
                .font(Theme.Fonts.body)
                .lineSpacing(document ? Theme.lineSpacing : 2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let checked = it.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .foregroundStyle(checked ? Color.accentColor : .secondary)
                                .frame(minWidth: 14, alignment: .trailing)
                        } else {
                            Text(it.marker)
                                .font(it.marker.count > 1 ? Theme.Fonts.body.monospacedDigit() : Theme.Fonts.body)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 14, alignment: .trailing)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(it.text)
                                .font(Theme.Fonts.body)
                                .lineSpacing(document ? Theme.lineSpacing : 2)
                                .strikethrough(it.checked == true, color: .secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if !it.more.isEmpty {
                                MarkdownText(blocks: it.more, color: color, document: document)
                            }
                        }
                    }
                    .padding(.leading, CGFloat(it.depth) * 20)
                }
            }
        case .quote(let b):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                MarkdownText(blocks: b, color: .secondary, document: document)
            }
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
        case .code(let code, let lang) where lang?.lowercased() == "svg":
            InlineSVG(source: code)
        case .code(let code, let lang) where lang?.lowercased() == "mermaid":
            MermaidView(source: code)
        case .code(let code, let lang):
            CodeBlock(code: code, language: lang, collapsedLines: 40)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }
}

/// An SVG written straight into the text (```svg), e.g. a mockup in a plan,
/// where there are no files yet: drawn, not shown as code. Tap for full
/// screen; the Pencil marks it up.
struct InlineSVG: View {
    let source: String
    @Environment(\.markupSink) private var sink
    @State private var image: UIImage?
    @State private var showSource = false
    @State private var full = false
    @State private var markup: UIImage?

    /// Drawn images by source, so a section rendered for markup (ImageRenderer
    /// draws synchronously) includes them.
    @MainActor static var drawn: [String: UIImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let img = image ?? Self.drawn[source] {
                Image(uiImage: img).resizable().scaledToFit()
                    .inkAnchor("svg-\(source.hashValue)") { [elements = SVGElements(source)] r, shown in
                        elements.under(r, shown: shown)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 560)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(uiColor: .separator).opacity(0.5)))
                    .contentShape(Rectangle())
                    .onTapGesture { full = true }
                    .inkable(enabled: sink != nil, source: "mockup") { sink?($0) }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
            Button(showSource ? "Hide SVG source" : "SVG source") { showSource.toggle() }
                .font(Theme.Fonts.caption).buttonStyle(.borderless)
            if showSource { CodeBlock(code: source, language: "svg", collapsedLines: 40) }
        }
        .task(id: source) {
            if let d = Self.drawn[source] { image = d; return }
            let data = Data(source.utf8)
            if let img = await Rasterize.svg(data, size: Self.canvas(for: source)) {
                Self.drawn[source] = img
                image = img
            }
        }
        .fullScreenCover(isPresented: $full) {
            NavigationStack {
                Group {
                    if let img = image { ZoomableImage(image: img).background(Color.white) }
                }
                .inkable(enabled: sink != nil && image != nil, gestures: true, source: "mockup") { sink?($0) }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { full = false } }
                    if sink != nil, let img = image {
                        ToolbarItem(placement: .primaryAction) {
                            Button { markup = img } label: { Label("Mark up", systemImage: "pencil.tip.crop.circle") }
                        }
                    }
                }
                .sheet(isPresented: Binding(get: { markup != nil && full }, set: { if !$0 { markup = nil } })) {
                    markupSheet
                }
            }
        }
        .sheet(isPresented: Binding(get: { markup != nil && !full }, set: { if !$0 { markup = nil } })) {
            markupSheet
        }
    }

    @ViewBuilder private var markupSheet: some View {
        if let img = markup {
            MarkupSheet(pages: [img], source: "mockup") { sink?($0) }
        }
    }

    /// Draw at the SVG's own aspect ratio (its viewBox), 1600 wide.
    static func canvas(for svg: String) -> CGSize {
        let vb = svg.range(of: #"viewBox\s*=\s*["']([^"']+)["']"#, options: .regularExpression)
            .map { String(svg[$0]) }
        let nums = (vb?.split(separator: "\"").dropFirst().first ?? vb?.split(separator: "'").dropFirst().first)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) } } ?? []
        guard nums.count == 4, nums[2] > 0, nums[3] > 0 else { return CGSize(width: 1600, height: 1200) }
        return CGSize(width: 1600, height: min(4000, 1600 * nums[3] / nums[2]))
    }
}

private struct MarkupSinkKey: EnvironmentKey {
    static let defaultValue: ((Markup) -> Void)? = nil
}

extension EnvironmentValues {
    /// Where a markup made inside this view goes (the review or message being drafted).
    var markupSink: ((Markup) -> Void)? {
        get { self[MarkupSinkKey.self] }
        set { self[MarkupSinkKey.self] = newValue }
    }
}

struct MarkdownTable: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]

    @State private var available: CGFloat = 700

    var body: some View {
        let widths = columnWidths()
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { c, h in
                        cell(h, width: widths[c]).font(Theme.Fonts.meta.weight(.semibold))
                    }
                }
                .background(Theme.fieldBackground)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow(alignment: .top) {
                        ForEach(0..<header.count, id: \.self) { c in
                            cell(c < row.count ? row[c] : AttributedString(), width: widths[c]).font(Theme.Fonts.meta)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(uiColor: .separator).opacity(0.6)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
    }

    /// Each cell gets a set width, so wordy cells wrap and their row grows to
    /// fit. Short columns keep what their text needs; wordy ones share what's
    /// left of the page. Only when that would squeeze them too far does the
    /// table scroll sideways.
    private func columnWidths() -> [CGFloat] {
        let pad: CGFloat = 20, perChar: CGFloat = 7.6, least: CGFloat = 120
        let natural: [CGFloat] = header.indices.map { c in
            let texts = ([header[c]] + rows.compactMap { c < $0.count ? $0[c] : nil }).map { String($0.characters) }
            let longest = texts.map(\.count).max() ?? 0
            // Never narrower than its longest word (headers are bold: a little wider).
            let word = texts.flatMap { $0.split(separator: " ") }.map(\.count).max() ?? 0
            return min(max(CGFloat(longest) * perChar + pad, CGFloat(word) * 9 + pad + 4, 56), 480)
        }
        let total = natural.reduce(0, +)
        guard total > available else { return natural }
        let fixed = natural.filter { $0 <= least }.reduce(0, +)
        let flexible = total - fixed
        let room = max(available - fixed - 2, 0)       // the border
        return natural.map { $0 <= least ? $0 : max(least, $0 / flexible * room) }
    }

    private func cell(_ s: AttributedString, width: CGFloat) -> some View {
        Text(s)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(width: width, alignment: .leading)
    }
}

// MARK: - Links

/// Opens links in Markdown: web links in Safari, localhost links (a dev
/// server on the host) in the built-in browser, project paths in the in-app
/// preview (`margin-file:` or relative links like `v4/board.kicad_pcb`).
struct ProjectLinks: ViewModifier {
    let ws: WorkspaceState
    let cwd: String?
    @Binding var openFile: FileTarget?
    @State private var web: WebTarget?
    @Environment(\.openWebPreview) private var openWebPreview

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            if let t = WebTarget(url: url) {
                if let openWebPreview { openWebPreview(t) } else { web = t }
                return .handled
            }
            if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) {
                return .systemAction
            }
            var raw = url.absoluteString
            if raw.hasPrefix("margin-file:") { raw.removeFirst("margin-file:".count) }
            if raw.hasPrefix("file://") { raw.removeFirst("file://".count) }
            let path = raw.removingPercentEncoding ?? raw
            guard ws.fileTarget(path, cwd: cwd) != nil || !path.hasPrefix("/") else { return .discarded }
            Task { @MainActor in
                if let t = await ws.findFile(path, cwd: cwd) { openFile = t }
            }
            return .handled
        })
        .fullScreenCover(item: $web) { WebPreviewView(ws: ws, target: $0) }
    }
}

extension View {
    func projectLinks(_ ws: WorkspaceState, cwd: String?, open: Binding<FileTarget?>) -> some View {
        modifier(ProjectLinks(ws: ws, cwd: cwd, openFile: open))
    }
}
