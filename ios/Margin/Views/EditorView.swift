import SwiftUI
import UIKit

/// Write and edit files on the host: Markdown and copy (blog posts, docs,
/// READMEs) with a live preview, or plain code. Select a passage and ask
/// Claude to revise it; the suggestion comes back as a tracked change.
struct EditorView: View {
    let ws: WorkspaceState
    let project: String
    let path: String
    var isNew = false

    enum Mode: String, CaseIterable { case edit = "Edit", split = "Split", preview = "Preview" }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var text = ""
    @State private var saved = ""
    @State private var modified: Double?
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var conflict = false
    @State private var created = false
    @State private var confirmClose = false
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var mode: Mode = .edit
    @State private var assist: AssistRequest?
    @State private var openFile: FileTarget?

    private var name: String { (path as NSString).lastPathComponent }
    private var isProse: Bool { ["md", "markdown", "txt", ""].contains((path as NSString).pathExtension.lowercased()) }
    private var dirty: Bool { text != saved }
    private var cwd: String? { ws.projects.first { $0.name == project }?.path }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Opening \(name)…")
                } else {
                    content
                }
            }
            .navigationTitle(name + (dirty ? " •" : ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .top) { banner }
            .confirmationDialog("Save changes to \(name)?", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("Save") { Task { if await save() { dismiss() } } }
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .sheet(item: $assist) { req in
                AssistSheet(ws: ws, project: project, path: path, request: req) { replacement in
                    apply(replacement, to: req.range)
                }
            }
            .projectLinks(ws, cwd: cwd, open: $openFile)
            .sheet(item: $openFile) { t in
                NavigationStack {
                    FilePreviewView(ws: ws, project: t.project, entry: t.entry)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { openFile = nil } } }
                }
            }
        }
        .task { await load() }
        .interactiveDismissDisabled(dirty)
    }

    @ViewBuilder private var content: some View {
        let effective = (mode == .split && sizeClass == .compact) ? .edit : mode
        switch effective {
        case .edit:
            editor
        case .preview:
            preview
        case .split:
            HStack(spacing: 0) {
                editor
                Divider()
                preview
            }
        }
    }

    private var editor: some View {
        WritingTextView(text: $text, selection: $selection, prose: isProse,
                        language: Highlighter.language(forPath: path))
            .background(Color(uiColor: .systemBackground))
    }

    private var preview: some View {
        ScrollView {
            Group {
                if isProse {
                    MarkdownText(text: text, document: true)
                } else {
                    CodeBlock(code: text, language: Highlighter.language(forPath: path), title: path, lineNumbers: true)
                }
            }
            .frame(maxWidth: Theme.docWidth, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.pageBackground)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close") { if dirty { confirmClose = true } else { dismiss() } }
        }
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { m in
                    if m != .split || sizeClass != .compact { Text(m.rawValue).tag(m) }
                }
            }
            .pickerStyle(.segmented)
            .frame(width: sizeClass == .compact ? 160 : 240)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                let r = selection.length > 0 ? selection : NSRange(location: 0, length: (text as NSString).length)
                assist = AssistRequest(range: r, passage: (text as NSString).substring(with: r),
                                       context: context(around: r), wholeDocument: selection.length == 0)
            } label: {
                Label("Ask Claude", systemImage: "sparkles")
            }
            .disabled(loading || text.isEmpty)
            .help("Revise the selection (or the whole document) with Claude")

            Button {
                Task { await save() }
            } label: {
                if saving { ProgressView() } else { Text("Save").bold() }
            }
            .disabled(!dirty || saving)
            .keyboardShortcut("s", modifiers: .command)
        }
    }

    @ViewBuilder private var banner: some View {
        if conflict {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(name) changed on the host since you opened it.").font(Theme.Fonts.meta)
                Spacer()
                Button("Reload theirs") { Task { conflict = false; await load() } }
                Button("Keep mine") { Task { modified = nil; conflict = false; _ = await save() } }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.orange.opacity(0.15))
        } else if let error {
            Text(error).font(Theme.Fonts.caption).foregroundStyle(.red).padding(8)
        }
    }

    // MARK: actions

    private func load() async {
        loading = true
        defer { loading = false }
        if isNew {
            let title = ((name as NSString).deletingPathExtension).replacingOccurrences(of: "-", with: " ")
            text = isProse ? "# \(title.capitalized)\n\n" : ""
            saved = ""
            return
        }
        do {
            let (data, m) = try await ws.api.fileForEditing(project: project, path: path)
            text = String(decoding: data, as: UTF8.self)
            saved = text
            modified = m
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    private func save() async -> Bool {
        saving = true
        defer { saving = false }
        do {
            modified = try await ws.api.saveFile(project: project, path: path, data: Data(text.utf8),
                                                 baseModified: modified, createOnly: isNew && !created)
            created = true
            saved = text
            error = nil
            return true
        } catch APIError.http(409, _) where isNew && !created {
            error = "\(name) already exists. Close and open it from Files, or pick another name."
        } catch APIError.http(409, _) {
            conflict = true
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
        return false
    }

    private func apply(_ replacement: String, to range: NSRange) {
        let ns = text as NSString
        guard range.location + range.length <= ns.length else { return }
        text = ns.replacingCharacters(in: range, with: replacement)
        selection = NSRange(location: range.location, length: (replacement as NSString).length)
    }

    private func context(around r: NSRange) -> String {
        let ns = text as NSString
        let start = max(0, r.location - 3000)
        let end = min(ns.length, r.location + r.length + 1500)
        return ns.substring(with: NSRange(location: start, length: end - start))
    }
}

struct AssistRequest: Identifiable {
    let id = UUID()
    let range: NSRange
    let passage: String
    let context: String
    let wholeDocument: Bool
}

/// Ask Claude to revise a passage; review the change word by word, then accept.
struct AssistSheet: View {
    let ws: WorkspaceState
    let project: String
    let path: String
    let request: AssistRequest
    let onAccept: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var instruction = ""
    @State private var result: String?
    @State private var segments: [WordDiff.Segment] = []
    @State private var rejected: Set<Int> = []
    @State private var working = false
    @State private var error: String?

    private static let quick = ["Tighten", "Fix grammar and typos", "Make it friendlier", "More concise",
                                "Expand with detail", "Turn into bullet points", "Punchier headline"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(request.wholeDocument ? "Whole document" : "Selected passage")
                        .font(Theme.Fonts.meta.weight(.semibold)).foregroundStyle(.secondary)
                    if result != nil {
                        Text(WordDiff.attributed(segments, rejected: rejected))
                            .font(Theme.Fonts.body).lineSpacing(Theme.lineSpacing)
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner))
                    } else {
                        Text(request.passage).font(Theme.Fonts.body).lineSpacing(Theme.lineSpacing)
                            .lineLimit(14)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner))
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Self.quick, id: \.self) { q in
                                Button(q) { instruction = q; run() }.buttonStyle(.bordered).disabled(working)
                            }
                        }
                    }
                    WritingField(placeholder: "Or tell Claude what to change…", text: $instruction, maxLines: 6)
                        .onSubmit(run)
                    if result != nil, segments.contains(where: { if case .change = $0 { true } else { false } }) {
                        ChangeList(segments: segments, rejected: $rejected)
                    }
                    if let error { Text(error).font(Theme.Fonts.caption).foregroundStyle(.red) }
                }
                .padding(20)
                .frame(maxWidth: Theme.docWidth)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Ask Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else if result != nil {
                        Button("Try again") { run() }
                        Button(rejected.isEmpty ? "Accept" : "Apply kept") {
                            onAccept(WordDiff.apply(segments, rejected: rejected))
                            dismiss()
                        }
                        .bold()
                        .keyboardShortcut(.return, modifiers: .command)
                    } else {
                        Button("Revise", action: run).bold()
                            .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func run() {
        let ins = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ins.isEmpty, !working else { return }
        working = true
        error = nil
        Task {
            do {
                let r = try await ws.api.assist(project: project, path: path, passage: request.passage,
                                                instruction: ins, context: request.wholeDocument ? "" : request.context)
                segments = WordDiff.segments(old: request.passage, new: r)
                rejected = []
                result = r
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// Word-level tracked changes: the revision as runs of unchanged text and
/// changes (old → new). Each change can be kept or rejected on its own.
enum WordDiff {
    enum Segment: Hashable {
        case same(String)
        case change(old: String, new: String)
    }

    static func segments(old: String, new: String) -> [Segment] {
        let a = tokens(old), b = tokens(new)
        guard a.count * b.count <= 4_000_000 else { return [.change(old: old, new: new)] }
        let n = a.count, m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [Segment] = []
        var del = "", ins = ""
        func flushChange() {
            if !del.isEmpty || !ins.isEmpty { out.append(.change(old: del, new: ins)) }
            del = ""; ins = ""
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                flushChange()
                if case .same(let s)? = out.last { out[out.count - 1] = .same(s + a[i]) } else { out.append(.same(a[i])) }
                i += 1; j += 1
            } else if j < m, i == n || dp[i][j + 1] >= dp[i + 1][j] {
                ins += b[j]; j += 1
            } else {
                del += a[i]; i += 1
            }
        }
        flushChange()
        return out
    }

    /// The text with the kept changes applied.
    static func apply(_ segs: [Segment], rejected: Set<Int>) -> String {
        segs.enumerated().map { i, s in
            switch s {
            case .same(let t): return t
            case .change(let old, let new): return rejected.contains(i) ? old : new
            }
        }.joined()
    }

    /// Kept changes as tracked changes (deletions struck in red, insertions
    /// green); rejected ones read as the original.
    static func attributed(_ segs: [Segment], rejected: Set<Int> = []) -> AttributedString {
        var out = AttributedString()
        for (i, seg) in segs.enumerated() {
            switch seg {
            case .same(let t):
                out += AttributedString(t)
            case .change(let old, _) where rejected.contains(i):
                out += AttributedString(old)
            case .change(let old, let new):
                var d = AttributedString(old)
                d.foregroundColor = .red
                d.strikethroughStyle = .single
                var a = AttributedString(new)
                a.foregroundColor = .green
                a.backgroundColor = Color.green.opacity(0.12)
                out += d + a
            }
        }
        return out
    }

    static func attributed(old: String, new: String) -> AttributedString {
        attributed(segments(old: old, new: new))
    }

    /// Words with their trailing whitespace, so joining tokens rebuilds the text.
    private static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inSpace = false
        for ch in s {
            if ch.isWhitespace {
                inSpace = true
                cur.append(ch)
            } else {
                if inSpace { out.append(cur); cur = ""; inSpace = false }
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

/// Claude's revision, change by change: keep or reject each one, then apply.
struct ChangeList: View {
    let segments: [WordDiff.Segment]
    @Binding var rejected: Set<Int>

    private var changes: [(Int, String, String)] {
        segments.enumerated().compactMap { i, s in
            if case .change(let o, let n) = s { return (i, o, n) } else { return nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(changes.count - rejected.count) of \(changes.count) changes kept")
                    .font(Theme.Fonts.meta.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Keep all") { rejected = [] }.disabled(rejected.isEmpty)
                Button("Reject all") { rejected = Set(changes.map(\.0)) }.disabled(rejected.count == changes.count)
            }
            .font(Theme.Fonts.meta)
            .buttonStyle(.borderless)
            ForEach(changes, id: \.0) { i, old, new in
                let kept = !rejected.contains(i)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button {
                        if kept { rejected.insert(i) } else { rejected.remove(i) }
                    } label: {
                        Image(systemName: kept ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(kept ? Color.green : .secondary)
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(kept ? "Reject this change" : "Keep this change")
                    VStack(alignment: .leading, spacing: 2) {
                        if !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(old.trimmingCharacters(in: .whitespacesAndNewlines))
                                .strikethrough().foregroundStyle(kept ? Color.red : .secondary)
                        }
                        if !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(new.trimmingCharacters(in: .whitespacesAndNewlines))
                                .foregroundStyle(kept ? Color.green : .secondary)
                        }
                    }
                    .font(Theme.Fonts.meta)
                    .lineLimit(4)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 10))
                .opacity(kept ? 1 : 0.6)
            }
        }
    }
}

/// The editing surface: Apple's text view, so Scribble (writing with the
/// Pencil), dictation, selection and the edit menu work as everywhere else.
/// Prose gets comfortable typography and light Markdown styling; code gets
/// tree-sitter colouring as you type, line numbers and auto-indent. ⌘F finds
/// and replaces.
struct WritingTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var prose: Bool
    var language = ""

    func makeUIView(context: Context) -> EditorTextView {
        let v = EditorTextView.make()
        v.delegate = context.coordinator
        v.alwaysBounceVertical = true
        v.keyboardDismissMode = .interactive
        v.backgroundColor = .clear
        v.autocorrectionType = prose ? .default : .no
        v.autocapitalizationType = prose ? .sentences : .none
        v.smartQuotesType = prose ? .default : .no
        v.smartDashesType = prose ? .default : .no
        v.spellCheckingType = prose ? .yes : .no
        v.isFindInteractionEnabled = true
        v.configure(prose: prose, language: language)
        v.attributedText = NSAttributedString(string: text, attributes: v.typingAttributes)
        v.textChanged()
        return v
    }

    func updateUIView(_ v: EditorTextView, context: Context) {
        context.coordinator.parent = self
        if v.text != text {
            let sel = v.selectedRange
            v.attributedText = NSAttributedString(string: text, attributes: v.base)
            let len = (text as NSString).length
            v.selectedRange = NSRange(location: min(selection.location, len),
                                      length: min(selection.length, max(0, len - min(selection.location, len))))
            if selection.length == 0 { v.selectedRange = NSRange(location: min(sel.location, len), length: 0) }
            v.textChanged()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: WritingTextView
        init(_ p: WritingTextView) { parent = p }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            (tv as? EditorTextView)?.textChanged()
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            parent.selection = tv.selectedRange
            tv.setNeedsLayout()            // the current line's number is drawn brighter
        }

        /// Code: Return keeps the line's indent (one level more after an opening bracket or colon).
        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText t: String) -> Bool {
            guard !parent.prose, t == "\n" else { return true }
            let ns = tv.text as NSString
            let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
            let before = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
            var indent = String(before.prefix { $0 == " " || $0 == "\t" })
            if let last = before.trimmingCharacters(in: .whitespaces).last, "{([:".contains(last) {
                indent += indent.hasPrefix("\t") ? "\t" : "    "
            }
            guard !indent.isEmpty else { return true }
            tv.insertText("\n" + indent)
            return false
        }
    }
}

/// UITextView that keeps prose at a readable measure, colours as you type
/// and draws line numbers for code.
final class EditorTextView: UITextView {
    /// A TextKit 1 text view (line numbers come from its layout manager).
    /// Not `UITextView(usingTextLayoutManager:)`: that's a factory method,
    /// and the object it returns skips this subclass's stored properties.
    static func make() -> EditorTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let v = EditorTextView(frame: .zero, textContainer: container)
        v.storage = storage
        return v
    }

    private var storage: NSTextStorage?      // the text view doesn't keep its own storage alive
    private(set) var prose = true
    private var language = ""
    private(set) var base: [NSAttributedString.Key: Any] = [:]
    private var lineStarts: [Int] = [0]
    private var restyle: Task<Void, Never>?
    private let gutter = Gutter()

    func configure(prose: Bool, language: String) {
        self.prose = prose
        self.language = language.lowercased()
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = prose ? 1.35 : 1.15
        para.paragraphSpacing = prose ? 6 : 0
        let body = UIFont.preferredFont(forTextStyle: .body).fontDescriptor
        let font: UIFont = prose
            ? UIFont(descriptor: body.withDesign(.serif) ?? body, size: 19)
            : UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        base = [.font: font, .paragraphStyle: para, .foregroundColor: UIColor.label]
        typingAttributes = base
        if !prose {
            gutter.owner = self
            gutter.isUserInteractionEnabled = false
            gutter.backgroundColor = .clear
            gutter.contentMode = .redraw
            addSubview(gutter)
        }
    }

    private var gutterWidth: CGFloat {
        prose ? 0 : CGFloat(max(3, String(lineStarts.count).count)) * 8 + 20
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: UIEdgeInsets
        if prose {
            let side = max(20, (bounds.width - Theme.docWidth) / 2)
            inset = UIEdgeInsets(top: 24, left: side, bottom: 120, right: side)
        } else {
            inset = UIEdgeInsets(top: 16, left: gutterWidth + 10, bottom: 120, right: 16)
        }
        if textContainerInset != inset { textContainerInset = inset }
        if !prose {
            // The gutter covers what's on screen and redraws as you scroll.
            gutter.frame = CGRect(x: 0, y: contentOffset.y, width: gutterWidth, height: bounds.height)
            gutter.setNeedsDisplay()
        }
    }

    /// After every edit: line numbers now, colours a moment later.
    func textChanged() {
        let ns = text as NSString
        var starts = [0]
        var i = 0
        while i < ns.length {
            let r = ns.range(of: "\n", range: NSRange(location: i, length: ns.length - i))
            if r.location == NSNotFound { break }
            starts.append(r.location + 1)
            i = r.location + 1
        }
        lineStarts = starts
        setNeedsLayout()
        restyle?.cancel()
        restyle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.applyStyle()
        }
    }

    func lineNumber(at index: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= index { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    private func applyStyle() {
        let code = text ?? ""
        let ns = code as NSString
        guard ns.length <= 300_000 else { return }
        let full = NSRange(location: 0, length: ns.length)
        let spans: [(NSRange, [NSAttributedString.Key: Any])] = prose ? MarkdownStyle.spans(code, base: base) : codeSpans(code)
        let storage = textStorage
        storage.beginEditing()
        storage.setAttributes(base, range: full)
        for (r, attrs) in spans where NSMaxRange(r) <= ns.length {
            storage.addAttributes(attrs, range: r)
        }
        storage.endEditing()
        typingAttributes = base
    }

    private func codeSpans(_ code: String) -> [(NSRange, [NSAttributedString.Key: Any])] {
        if let spans = SyntaxTrees.spans(code, language: language) {
            return spans.map { ($0.0, [.foregroundColor: UIColor($0.1)]) }
        }
        // No grammar: the regex colouring the read-only views use.
        let a = Highlighter.highlight(code, language: language)
        return a.runs.compactMap { run in
            guard let c = run.foregroundColor else { return nil }
            return (NSRange(run.range, in: a), [.foregroundColor: UIColor(c)])
        }
    }

    final class Gutter: UIView {
        weak var owner: EditorTextView?

        override func draw(_ rect: CGRect) {
            guard let tv = owner else { return }
            let lm = tv.layoutManager
            let ns = tv.text as NSString
            let inset = tv.textContainerInset
            let top = tv.contentOffset.y - inset.top
            let visible = CGRect(x: 0, y: top, width: tv.textContainer.size.width, height: bounds.height)
            let font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.tertiaryLabel]
            let current = tv.lineNumber(at: tv.selectedRange.location)
            func label(_ n: Int, y: CGFloat, height: CGFloat) {
                var a = attrs
                if n == current { a[.foregroundColor] = UIColor.secondaryLabel }
                let s = "\(n)" as NSString
                let size = s.size(withAttributes: a)
                s.draw(at: CGPoint(x: bounds.width - size.width - 8, y: y + (height - size.height) / 2), withAttributes: a)
            }
            let glyphs = lm.glyphRange(forBoundingRect: visible, in: tv.textContainer)
            lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, range, _ in
                let ci = lm.characterIndexForGlyph(at: range.location)
                guard ci == 0 || ns.character(at: ci - 1) == 10 else { return }    // first fragment of a line only
                label(tv.lineNumber(at: ci), y: frag.minY - top, height: frag.height)
            }
            let extra = lm.extraLineFragmentRect
            if extra.height > 0, extra.minY >= top, extra.minY <= top + bounds.height {
                label(tv.lineNumber(at: ns.length), y: extra.minY - top, height: extra.height)
            }
        }
    }
}

/// Markdown made readable while you write it: headings bigger and bold,
/// emphasis, `code` in a monospaced chip, links tinted, quotes and list
/// markers quieter. The marks themselves stay visible and editable.
enum MarkdownStyle {
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines]) }
    private static let heading = re(#"^(#{1,6})[ \t]+.*$"#)
    private static let strong = re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let emphasis = re(#"(?<![*_\w])([*_])(?![*_\s])(.+?)(?<![*_\s])\1(?![*_\w])"#)
    private static let code = re(#"`[^`\n]+`"#)
    private static let link = re(#"!?\[[^\]\n]*\]\([^)\n]*\)"#)
    private static let quote = re(#"^>.*$"#)
    private static let marker = re(#"^[ \t]*(?:[-*+]|\d+[.)])(?=[ \t])"#)
    private static let fence = re(#"^(```|~~~)[^\n]*\n[\s\S]*?^\1[ \t]*$"#)

    static func spans(_ text: String, base: [NSAttributedString.Key: Any]) -> [(NSRange, [NSAttributedString.Key: Any])] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let font = base[.font] as? UIFont ?? .preferredFont(forTextStyle: .body)
        let mono = UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.85, weight: .regular)
        func with(_ traits: UIFontDescriptor.SymbolicTraits, size: CGFloat? = nil) -> UIFont {
            let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) ?? font.fontDescriptor
            return UIFont(descriptor: d, size: size ?? font.pointSize)
        }
        var out: [(NSRange, [NSAttributedString.Key: Any])] = []
        for m in heading.matches(in: text, range: all) {
            let level = m.range(at: 1).length
            let size = font.pointSize * [1.6, 1.35, 1.18, 1.08, 1, 1][level - 1]
            out.append((m.range, [.font: with(.traitBold, size: size)]))
            out.append((m.range(at: 1), [.foregroundColor: UIColor.tertiaryLabel]))
        }
        for m in strong.matches(in: text, range: all) { out.append((m.range, [.font: with(.traitBold)])) }
        for m in emphasis.matches(in: text, range: all) { out.append((m.range, [.font: with(.traitItalic)])) }
        for m in link.matches(in: text, range: all) { out.append((m.range, [.foregroundColor: UIColor.tintColor])) }
        for m in quote.matches(in: text, range: all) { out.append((m.range, [.foregroundColor: UIColor.secondaryLabel])) }
        for m in marker.matches(in: text, range: all) { out.append((m.range, [.foregroundColor: UIColor.secondaryLabel])) }
        let chip: [NSAttributedString.Key: Any] = [.font: mono, .backgroundColor: UIColor.secondarySystemFill]
        for m in code.matches(in: text, range: all) { out.append((m.range, chip)) }
        for m in fence.matches(in: text, range: all) {
            out.append((m.range, [.font: mono, .foregroundColor: UIColor.secondaryLabel]))
        }
        return out
    }
}
