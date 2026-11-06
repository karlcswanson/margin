import Observation
import SwiftUI

/// GitHub-style review of a project's changes: pick what to compare against,
/// read the diff, tap lines to comment, then send the review to the team.
struct CodeReviewView: View {
    let ws: WorkspaceState
    let project: String
    /// Inside a chat: reviews go to that chat, and the chat owns the title.
    var chatSessionId: String? = nil
    /// A file Claude pointed at: scrolled to once the changes load.
    var focusPath: String? = nil
    var openSession: (String) -> Void

    @State private var refs: GitRefs?
    #if DEBUG
    // Simulator screenshots: SIMCTL_CHILD_MARGIN_DIFF_BASE=<sha> compares against that commit.
    @State private var base = ProcessInfo.processInfo.environment["MARGIN_DIFF_BASE"] ?? ""
    #else
    @State private var base = ""
    #endif
    @State private var files: [DiffFile] = []
    @State private var truncated = false
    @State private var loading = true
    @State private var error: String?
    @State private var draft = CodeReviewDraft()
    @State private var collapsed: Set<String> = []
    @State private var commenting: DiffLineKey?
    @State private var sending = false
    @State private var sendError: String?
    @State private var markup: (image: UIImage, source: String)?

    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let focusPath, let f = files.first(where: { focusPath.hasSuffix("/" + $0.path) || focusPath == $0.path })
        else { return }
        collapsed.remove(f.id)
        withAnimation { proxy.scrollTo(f.id, anchor: .top) }
    }

    private var baseLabel: String {
        if base.isEmpty { return "Uncommitted changes" }
        if let c = refs?.commits.first(where: { $0.sha == base }) { return "Since \(c.sha) · \(c.subject)" }
        return "Compared with \(base)"
    }

    private var latestSession: SessionRow? {
        if let chatSessionId, let s = ws.session(chatSessionId) { return s }
        return ws.sessions.filter { $0.project == project }.max { ($0.lastModified ?? 0) < ($1.lastModified ?? 0) }
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                summary
                if let error {
                    ContentUnavailableView("Can't show changes", systemImage: "arrow.triangle.branch",
                                           description: Text(error))
                } else if !loading && files.isEmpty {
                    ContentUnavailableView("No changes", systemImage: "checkmark.circle",
                                           description: Text("Nothing differs from \(base.isEmpty ? "the last commit" : base)."))
                }
                ForEach(files) { f in fileCard(f).id(f.id) }
                if truncated {
                    Text("The diff was too large to show completely.").font(Theme.Fonts.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .onChange(of: files.map(\.path)) { scrollToFocus(proxy) }
        .onChange(of: focusPath) { scrollToFocus(proxy) }
        }
        .background(Theme.pageBackground)
        .overlay { if loading { ProgressView() } }
        .safeAreaInset(edge: .bottom) { reviewBar }
        .navigationTitle(chatSessionId == nil ? "\(project) · changes" : ws.session(chatSessionId!)?.title ?? "Changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if chatSessionId == nil { WorkspaceBadge(ws: ws) }
                Menu {
                    Picker("Compare", selection: $base) {
                        Text("Uncommitted changes").tag("")
                        if let refs {
                            Section("Branches") {
                                ForEach(refs.branches.filter { $0 != refs.branch }, id: \.self) { b in
                                    Text("Compared with \(b)").tag(b)
                                }
                            }
                            Section("Since commit") {
                                ForEach(refs.commits.prefix(15), id: \.sha) { c in
                                    Text("\(c.sha) · \(c.subject)").tag(c.sha)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Compare", systemImage: "arrow.triangle.branch")
                }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task { await loadRefs(); await load() }
        .sheet(isPresented: Binding(get: { markup != nil }, set: { if !$0 { markup = nil } })) {
            if let m = markup {
                MarkupSheet(pages: [m.image], source: m.source) { draft.images.markups.append($0) }
            }
        }
        .onChange(of: base) { Task { await load() } }
    }

    private var summary: some View {
        let added = files.reduce(0) { $0 + $1.added }, removed = files.reduce(0) { $0 + $1.removed }
        return VStack(alignment: .leading, spacing: 6) {
            Text(baseLabel).font(Theme.Fonts.h2)
            HStack(spacing: 10) {
                if let b = refs?.branch { Label(b, systemImage: "arrow.triangle.branch") }
                Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                Text("+\(added)").foregroundStyle(.green)
                Text("−\(removed)").foregroundStyle(.red)
            }
            .font(Theme.Fonts.meta.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func fileCard(_ f: DiffFile) -> some View {
        let isCollapsed = collapsed.contains(f.path)
        let comments = draft.comments.keys.filter { $0.path == f.path }.count
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isCollapsed { collapsed.remove(f.path) } else { collapsed.insert(f.path) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").font(Theme.Fonts.caption)
                    Text(f.path).font(.system(.callout, design: .monospaced).weight(.semibold))
                        .lineLimit(1).truncationMode(.head)
                    if f.status != "modified" {
                        Text(f.status).font(Theme.Fonts.small.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.fieldBackground, in: Capsule())
                    }
                    Spacer()
                    if comments > 0 {
                        Label("\(comments)", systemImage: "text.bubble.fill").font(Theme.Fonts.caption).foregroundStyle(Color.accentColor)
                    }
                    Text("+\(f.added)").font(Theme.Fonts.caption.monospacedDigit()).foregroundStyle(.green)
                    Text("−\(f.removed)").font(Theme.Fonts.caption.monospacedDigit()).foregroundStyle(.red)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !isCollapsed {
                Divider()
                if f.binary {
                    Text("Binary file").font(Theme.Fonts.caption).foregroundStyle(.secondary).padding(12)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(f.hunks) { h in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(h.header).font(Theme.Fonts.code).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.accentColor.opacity(0.06))
                                let colored = Highlighter.hunk(h.lines.map { ($0.kind, $0.text) },
                                                               language: Highlighter.language(forPath: f.path))
                                ForEach(Array(h.lines.enumerated()), id: \.element.id) { i, line in
                                    lineRow(f, line, colored[i])
                                }
                            }
                            // Circle code with the Pencil: the hunk as you see it, to draw on.
                            .inkable(source: "\(f.path) \(h.header)") { draft.images.markups.append($0) }
                        }
                    }
                    .frame(minWidth: 600, alignment: .leading)
                }
            }
        }
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner))
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
    }

    @ViewBuilder
    private func lineRow(_ f: DiffFile, _ line: DiffLine, _ colored: AttributedString) -> some View {
        let key = DiffLineKey(path: f.path, old: line.old, new: line.new)
        let note = Binding(get: { draft.comments[key] ?? "" }, set: { draft.comments[key] = $0 })
        Button {
            commenting = key
            if draft.comments[key] == nil { draft.comments[key] = "" }
        } label: {
            HStack(alignment: .top, spacing: 0) {
                Text(line.old.map(String.init) ?? "").frame(width: 44, alignment: .trailing)
                Text(line.new.map(String.init) ?? "").frame(width: 44, alignment: .trailing)
                Text(String(line.kind == "+" ? "+" : line.kind == "-" ? "−" : " "))
                    .frame(width: 22)
                    .foregroundStyle(line.kind == "+" ? .green : line.kind == "-" ? .red : .secondary)
                Text(colored)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            .font(Theme.Fonts.code)
            .foregroundStyle(.primary)
            .padding(.vertical, 1)
            .inkAnchor("\(f.path)#\(line.id)",
                       "\(f.path):\(line.new ?? line.old ?? 0) (\(line.kind == "+" ? "added" : line.kind == "-" ? "removed" : "unchanged")) `\(line.text.trimmingCharacters(in: .whitespaces).prefix(160))`")
            .background(line.kind == "+" ? Color.green.opacity(0.12) : line.kind == "-" ? Color.red.opacity(0.12) : .clear)
            .overlay(alignment: .leading) {
                if draft.comments[key] != nil { Rectangle().fill(Color.accentColor).frame(width: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if draft.comments[key] != nil {
            HStack(alignment: .top) {
                WritingField(placeholder: "Comment on line \(line.new ?? line.old ?? 0)", text: note, maxLines: 6)
                Button { draft.comments[key] = nil } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).padding(.top, 10)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: 700, alignment: .leading)
        }
    }

    private var reviewBar: some View {
        let count = draft.comments.values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        return VStack(alignment: .leading, spacing: 10) {
            if !draft.images.markups.isEmpty { MarkupStrip(draft: draft.images) }
            WritingField(placeholder: "Overall review notes", text: Bindable(draft).overall, maxLines: 5)
            if let sendError { Text(sendError).font(Theme.Fonts.caption).foregroundStyle(.red) }
            HStack {
                Text(count == 0 && draft.images.markups.isEmpty
                     ? "Tap a line to comment, or draw on the code with the Pencil"
                     : "\(count) comment\(count == 1 ? "" : "s")"
                        + (draft.images.markups.isEmpty ? "" : ", \(draft.images.markups.count) markup\(draft.images.markups.count == 1 ? "" : "s")"))
                    .font(Theme.Fonts.meta).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    if let s = latestSession {
                        Button { send(toSession: s.sessionId) } label: {
                            Label(chatSessionId != nil ? "Send to this chat" : "Send to “\(s.title)”",
                                  systemImage: "arrowshape.turn.up.right")
                        }
                    }
                    Button { send(toSession: nil) } label: {
                        Label("New task: propose fixes", systemImage: "doc.text.magnifyingglass")
                    }
                } label: {
                    Label(sending ? "Sending…" : "Request changes", systemImage: "arrow.uturn.backward")
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .fixedSize()                  // the hint beside it wraps instead
                .disabled(sending || !draft.hasContent)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: actions

    private func loadRefs() async {
        refs = try? await ws.api.gitRefs(project: project)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let d = try await ws.api.gitDiff(project: project, base: base)
            files = UnifiedDiff.parse(d.diff)
            truncated = d.truncated
            error = nil
        } catch APIError.http(_, let body) {
            error = (try? JSONDecoder().decode([String: String].self, from: Data(body.utf8)))?["detail"] ?? body
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func send(toSession sid: String?) {
        var text = draft.compose(project: project, scope: baseLabel, files: files)
        sending = true
        sendError = nil
        Task {
            do {
                if !draft.images.markups.isEmpty {
                    text += "\n### Marked-up code (Read each one; the drawing shows what I mean)\n"
                    for (i, m) in draft.images.markups.enumerated() {
                        guard let png = m.image.pngData() else { continue }
                        let path = try await ws.api.uploadMarkup(project: project, png: png)
                        let note = m.note.trimmingCharacters(in: .whitespacesAndNewlines)
                        text += "\(i + 1). \(m.source): ![markup \(i + 1)](\(path))" + (note.isEmpty ? "" : " — \(note)") + "\n"
                        text += m.contextMarkdown
                    }
                }
                if let sid {
                    try await ws.send(sid, text: text)
                    openSession(sid)
                } else {
                    let prompt = text + "\n\nPropose how you'll address this review before changing anything."
                    let newId = try await ws.startSession(project: project, prompt: prompt, mode: .plan)
                    openSession(newId)
                }
                draft = CodeReviewDraft()
            } catch {
                sendError = error.localizedDescription
            }
            sending = false
        }
    }
}

struct DiffLineKey: Hashable {
    let path: String
    let old: Int?
    let new: Int?
}

@Observable
final class CodeReviewDraft {
    var comments: [DiffLineKey: String] = [:]
    var overall = ""
    @MainActor let images = ReviewDraft()     // Pencil markups of hunks

    @MainActor var hasContent: Bool {
        !images.markups.isEmpty
            || comments.values.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            || !overall.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func compose(project: String, scope: String, files: [DiffFile]) -> String {
        var out = "## Code review: \(project) (\(scope))\n"
        for f in files {
            let mine = comments.filter { $0.key.path == f.path && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !mine.isEmpty else { continue }
            out += "\n### `\(f.path)`\n"
            let lines = f.hunks.flatMap(\.lines)
            for (key, note) in mine.sorted(by: { ($0.key.new ?? $0.key.old ?? 0) < ($1.key.new ?? $1.key.old ?? 0) }) {
                let code = lines.first { $0.old == key.old && $0.new == key.new }
                let where_ = key.new.map { "line \($0)" } ?? key.old.map { "old line \($0)" } ?? "?"
                let quoted = code.map { " `\($0.kind == " " ? "" : String($0.kind))\($0.text.trimmingCharacters(in: .whitespaces).prefix(120))`" } ?? ""
                out += "- **\(where_)**\(quoted): \(note.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            }
        }
        let o = overall.trimmingCharacters(in: .whitespacesAndNewlines)
        if !o.isEmpty { out += "\n### Overall\n\(o)\n" }
        return out
    }
}

// MARK: - Unified diff

struct DiffLine: Identifiable {
    let id: Int
    let kind: Character      // "+", "-", " "
    let text: String
    let old: Int?
    let new: Int?
}

struct DiffHunk: Identifiable {
    let id: Int
    let header: String
    var lines: [DiffLine]
}

struct DiffFile: Identifiable {
    var path: String
    var status = "modified"
    var binary = false
    var hunks: [DiffHunk] = []
    var id: String { path }
    var added: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == "+" }.count } }
    var removed: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == "-" }.count } }
}

enum UnifiedDiff {
    private static let hunkRe = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$"#)

    static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var cur: DiffFile?
        var oldNo = 0, newNo = 0, n = 0
        func flush() { if let c = cur { files.append(c) }; cur = nil }

        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("diff --git ") {
                flush()
                let parts = raw.dropFirst("diff --git ".count).components(separatedBy: " b/")
                cur = DiffFile(path: parts.count > 1 ? parts.last! : String(raw.dropFirst(13)))
                continue
            }
            guard cur != nil else { continue }
            if raw.hasPrefix("new file") { cur!.status = "added"; continue }
            if raw.hasPrefix("deleted file") { cur!.status = "deleted"; continue }
            if raw.hasPrefix("rename to ") { cur!.status = "renamed"; cur!.path = String(raw.dropFirst(10)); continue }
            if raw.hasPrefix("Binary files") { cur!.binary = true; continue }
            if raw.hasPrefix("+++ ") || raw.hasPrefix("--- ") || raw.hasPrefix("index ") || raw.hasPrefix("similarity")
                || raw.hasPrefix("rename from") || raw.hasPrefix("old mode") || raw.hasPrefix("new mode") { continue }
            let ns = raw as NSString
            if let m = hunkRe.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
                oldNo = Int(ns.substring(with: m.range(at: 1))) ?? 0
                newNo = Int(ns.substring(with: m.range(at: 2))) ?? 0
                n += 1
                cur!.hunks.append(DiffHunk(id: n, header: raw, lines: []))
                continue
            }
            guard !cur!.hunks.isEmpty, let first = raw.first else { continue }
            n += 1
            let body = String(raw.dropFirst())
            switch first {
            case "+":
                cur!.hunks[cur!.hunks.count - 1].lines.append(DiffLine(id: n, kind: "+", text: body, old: nil, new: newNo)); newNo += 1
            case "-":
                cur!.hunks[cur!.hunks.count - 1].lines.append(DiffLine(id: n, kind: "-", text: body, old: oldNo, new: nil)); oldNo += 1
            case " ":
                cur!.hunks[cur!.hunks.count - 1].lines.append(DiffLine(id: n, kind: " ", text: body, old: oldNo, new: newNo)); oldNo += 1; newNo += 1
            default:
                break            // "\ No newline at end of file"
            }
        }
        flush()
        return files
    }
}
