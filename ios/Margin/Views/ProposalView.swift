import SwiftUI

/// A plan Claude presented, laid out as a document you mark up: comment on
/// any section, draw on any render, then approve (your notes travel with the
/// approval) or send it back for the next version.
struct ProposalView: View {
    let ws: WorkspaceState
    let proposalId: String
    var openSession: ((String) -> Void)? = nil

    @State private var showChanges = false
    @State private var editing: String?
    @State private var sending = false
    @State private var error: String?
    @State private var openFile: FileTarget?
    @State private var sectionMarkup: SectionMarkup?
    @FocusState private var noteFocused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    private struct SectionMarkup: Identifiable {
        let title: String
        let image: UIImage
        var id: String { title }
    }

    private var proposal: Proposal? { ws.proposals[proposalId] }

    var body: some View {
        if let p = proposal {
            content(p)
        } else {
            ContentUnavailableView("Proposal not found", systemImage: "doc.questionmark")
        }
    }

    private func content(_ p: Proposal) -> some View {
        let sections = ProposalSections(p.plan)
        let draft = ws.draft(for: p.sessionId)
        let history = ws.proposals(for: p.sessionId)
        let previous = history.last(where: { $0.version < p.version })
        let cwd = ws.session(p.sessionId)?.cwd

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(p, history: history)

                if let prev = previous {
                    previousRound(prev, current: p)
                }

                if !sections.summary.isEmpty {
                    MarkdownText(text: sections.summary, document: true)
                    media(in: sections.summary, cwd: cwd)
                }

                ForEach(sections.items, id: \.title) { s in
                    sectionCard(s, draft: draft, pending: p.isPending, cwd: cwd)
                }

                // Overall notes: the last thing in the list, after the sections they sum up.
                if p.isPending {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Overall").font(Theme.Fonts.meta.weight(.semibold)).foregroundStyle(.secondary)
                        WritingField(placeholder: "Overall notes for the team", text: Bindable(draft).overall,
                                     maxLines: 8, focus: $noteFocused)
                    }
                }

                outcome(p)
            }
            .frame(maxWidth: Theme.docWidth, alignment: .leading)
            .padding(.horizontal, sizeClass == .compact ? 16 : 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.pageBackground)
        .safeAreaInset(edge: .bottom) {
            if p.isPending { reviewBar(p, draft: draft, sections: sections) }
        }
        .projectLinks(ws, cwd: cwd, open: $openFile)
        .environment(\.reviewSessionId, p.sessionId)
        .environment(\.markupSink) { draft.markups.append($0) }
        .sheet(item: $openFile) { target in
            NavigationStack {
                FilePreviewView(ws: ws, project: target.project, entry: target.entry)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { openFile = nil } } }
                    .environment(\.reviewSessionId, p.sessionId)
            }
        }
        .sheet(item: $sectionMarkup) { m in
            MarkupSheet(pages: [m.image], source: "section “\(m.title)”") { draft.markups.append($0) }
        }
        .navigationTitle(p.project ?? "Proposal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                WorkspaceBadge(ws: ws)
                if let openSession {
                    Button { openSession(p.sessionId) } label: { Label("Conversation", systemImage: "bubble.left.and.text.bubble.right") }
                }
            }
        }
    }

    // MARK: pieces

    private func header(_ p: Proposal, history: [Proposal]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // One line when it fits; on a phone the details go under the status.
            let meta = HStack(spacing: 8) {
                Text("v\(p.version)").font(Theme.Fonts.meta.monospacedDigit()).foregroundStyle(.secondary)
                if let proj = p.project { Text("· \(proj)").font(Theme.Fonts.meta).foregroundStyle(.secondary) }
                Text("· \(p.created, style: .relative) ago").font(Theme.Fonts.meta).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { StatusPill(status: p.status).fixedSize(); meta.fixedSize() }
                VStack(alignment: .leading, spacing: 6) { StatusPill(status: p.status).fixedSize(); meta.lineLimit(1) }
            }
            Text(MarkdownBlocks.title(p.title)).font(Theme.Fonts.docTitle).fixedSize(horizontal: false, vertical: true)
            if history.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(history) { h in
                            Text("v\(h.version)")
                                .font(Theme.Fonts.caption.weight(h.id == p.id ? .bold : .regular))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(h.id == p.id ? Color.accentColor.opacity(0.2) : Theme.fieldBackground,
                                            in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private func previousRound(_ prev: Proposal, current: Proposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let fb = prev.feedback, !fb.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Your notes on v\(prev.version)", systemImage: "text.bubble")
                        .font(Theme.Fonts.meta.weight(.semibold)).foregroundStyle(.secondary)
                    MarkdownText(text: fb, color: .secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner))
            }
            DisclosureGroup(isExpanded: $showChanges) {
                DiffBlock(path: "plan.md", edits: [(prev.plan, current.plan)], collapsedLines: 60)
                    .padding(.top, 6)
            } label: {
                Label("What changed since v\(prev.version)", systemImage: "arrow.left.arrow.right")
                    .font(Theme.Fonts.meta.weight(.medium))
            }
        }
    }

    private func sectionCard(_ s: ProposalSections.Section, draft: ReviewDraft, pending: Bool, cwd: String?) -> some View {
        let note = Binding(get: { draft.sectionNotes[s.title] ?? "" }, set: { draft.sectionNotes[s.title] = $0 })
        let hasNote = !(draft.sectionNotes[s.title] ?? "").isEmpty
        let out = draft.leftOut.contains(s.title)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: Theme.blockSpacing) {
                ForEach(Array(s.parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .markdown(let md): MarkdownText(text: md, document: true)
                    case .choice(let c): ChoiceView(choice: c, draft: draft, pending: pending && !out)
                    }
                }
            }
            .opacity(out ? 0.45 : 1)
            .inkable(enabled: pending, source: "section “\(s.title)”") { draft.markups.append($0) }
            if out {
                Label("Left out: the team won't do this part", systemImage: "minus.circle")
                    .font(Theme.Fonts.meta.weight(.medium)).foregroundStyle(Color.accentColor)
            }
            media(in: s.markdown, cwd: cwd)
            if s.title.lowercased().contains("command") {
                Label("Approving lets these run without asking while the team carries out the plan. Anything else still comes to you.",
                      systemImage: "checkmark.shield")
                    .font(Theme.Fonts.caption).foregroundStyle(.secondary)
            }
            if pending {
                if editing == s.title || hasNote {
                    WritingField(placeholder: "Comment on “\(s.title)”", text: note, maxLines: 8)
                } else {
                    HStack {
                        Button { editing = s.title } label: {
                            Label("Comment", systemImage: "text.bubble")
                                .font(Theme.Fonts.meta)
                        }
                        Button { markUp(s) } label: {
                            Label("Mark up", systemImage: "pencil.tip.crop.circle")
                                .font(Theme.Fonts.meta)
                        }
                        Spacer()
                        if !s.title.lowercased().contains("command") {
                            leaveOut(s, draft: draft, out: out)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                if editing == s.title || hasNote, !s.title.lowercased().contains("command") {
                    HStack { Spacer(); leaveOut(s, draft: draft, out: out).buttonStyle(.bordered) }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(alignment: .leading) {
            if hasNote {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 4).padding(.vertical, 12)
            }
        }
    }

    private func leaveOut(_ s: ProposalSections.Section, draft: ReviewDraft, out: Bool) -> some View {
        Button {
            if out { draft.leftOut.remove(s.title) } else { draft.leftOut.insert(s.title) }
        } label: {
            Label(out ? "Keep" : "Leave out", systemImage: out ? "arrow.uturn.backward" : "minus.circle")
                .font(Theme.Fonts.meta)
        }
        .tint(.accentColor)         // what you picked is blue, like the choices
    }

    /// The section as a page to draw on (Pencil on the text does this too).
    private func markUp(_ s: ProposalSections.Section) {
        let page = MarkdownText(text: s.markdown, document: true)
            .frame(width: 640, alignment: .leading)
            .padding(32)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let r = ImageRenderer(content: page)
        r.scale = 2
        if let img = r.uiImage { sectionMarkup = SectionMarkup(title: s.title, image: img) }
    }

    @ViewBuilder
    private func media(in markdown: String, cwd: String?) -> some View {
        let paths = MediaRefs.find(in: markdown)
        if !paths.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(paths, id: \.self) { MediaThumb(ws: ws, path: $0, cwd: cwd, hideIfMissing: true) }
            }
        }
    }

    @ViewBuilder
    private func outcome(_ p: Proposal) -> some View {
        switch p.status {
        case "approved":
            Label("Approved \(p.updated, style: .relative) ago. The team is working on it.", systemImage: "hammer")
                .font(Theme.Fonts.meta).foregroundStyle(.secondary)
        case "revise":
            Label("Sent back \(p.updated, style: .relative) ago. A new version is on its way.",
                  systemImage: "arrow.uturn.backward")
                .font(Theme.Fonts.meta).foregroundStyle(.secondary)
        case "superseded":
            Label("A newer version replaced this one.", systemImage: "square.stack")
                .font(Theme.Fonts.meta).foregroundStyle(.secondary)
        case "done":
            VStack(alignment: .leading, spacing: 8) {
                Label(p.outcomeError == true ? "Finished with problems" : "Done",
                      systemImage: p.outcomeError == true ? "exclamationmark.triangle" : "checkmark.seal")
                    .font(Theme.Fonts.h3)
                    .foregroundStyle(p.outcomeError == true ? Color.orange : Color.green)
                if let o = p.outcome { MarkdownText(text: o) }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner))
        default:
            EmptyView()
        }
        if let fb = p.feedback, p.status != "pending", p.status != "superseded" {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your notes").font(Theme.Fonts.meta.weight(.semibold)).foregroundStyle(.secondary)
                MarkdownText(text: fb, color: .secondary)
            }
        }
    }

    private func reviewBar(_ p: Proposal, draft: ReviewDraft, sections: ProposalSections) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !draft.markups.isEmpty {
                MarkupStrip(draft: draft)
            }
            if let error { Text(error).font(Theme.Fonts.caption).foregroundStyle(.red) }
            HStack {
                let count = draft.sectionNotes.values.filter { !$0.isEmpty }.count + draft.markups.count
                let summary = [
                    count > 0 ? "\(count) comment\(count == 1 ? "" : "s")" : nil,
                    draft.choices.isEmpty ? nil : "\(draft.choices.count) choice\(draft.choices.count == 1 ? "" : "s")",
                    draft.leftOut.isEmpty ? nil : "\(draft.leftOut.count) left out",
                ].compactMap { $0 }
                if !summary.isEmpty {
                    Text(summary.joined(separator: " · ")).font(Theme.Fonts.meta).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    decide(p, approve: false, sections: sections)
                } label: {
                    Label("Send back", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(sending || !draft.hasNotes)
                Button {
                    decide(p, approve: true, sections: sections)
                } label: {
                    Label(draft.hasNotes ? "Approve with notes" : "Approve", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(sending)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: Theme.docWidth + 48)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func decide(_ p: Proposal, approve: Bool, sections: ProposalSections) {
        sending = true
        error = nil
        Task {
            do {
                try await ws.decide(p, approve: approve, sections: sections.items.map(\.title))
                editing = nil
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}

/// Options to tap. Claude's recommendation is picked until you pick another;
/// only a different pick is sent back.
struct ChoiceView: View {
    let choice: Choice
    let draft: ReviewDraft
    let pending: Bool

    private var picked: String? { draft.choices[choice.question] ?? choice.recommended?.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(choice.options, id: \.self) { o in
                let on = picked == o.text
                Button {
                    draft.choices[choice.question] = o.recommended && choice.recommended == o ? nil : o.text
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: on ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(on ? Color.accentColor : .secondary)
                        Text(MarkdownBlocks.parse(o.text).first.flatMap { b -> AttributedString? in
                            if case .paragraph(let a) = b { return a } else { return nil }
                        } ?? AttributedString(o.text))
                            .font(Theme.Fonts.body)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(on ? Color.accentColor.opacity(0.1) : Theme.fieldBackground,
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(on ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!pending)
                .inkAnchor("choice-\(choice.question.hashValue)-\(o.text.hashValue)",
                           "option “\(o.text.prefix(160))” for “\(choice.question)”")
            }
        }
    }
}

/// Thumbnails of markups and attachments waiting to be sent; tap ✕ to drop one.
struct MarkupStrip: View {
    let draft: ReviewDraft

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(draft.markups) { m in
                    ZStack(alignment: .topTrailing) {
                        VStack(alignment: .leading, spacing: 3) {
                            Image(uiImage: m.image).resizable().scaledToFill()
                                .frame(width: 96, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(m.note.isEmpty ? m.source : m.note)
                                .font(Theme.Fonts.small).lineLimit(1).frame(width: 96, alignment: .leading)
                                .foregroundStyle(.secondary)
                        }
                        Button { draft.markups.removeAll { $0.id == m.id } } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(4)
                    }
                }
            }
        }
    }
}

struct StatusPill: View {
    let status: String

    var body: some View {
        Text(label)
            .font(Theme.Fonts.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case "pending": return "Needs your decision"
        case "approved": return "Approved · in progress"
        case "revise": return "Sent back"
        case "superseded": return "Superseded"
        case "done": return "Done"
        default: return status
        }
    }

    private var color: Color {
        switch status {
        case "pending": return Theme.needsYou
        case "approved": return .blue
        case "revise": return .purple
        case "done": return .green
        default: return .secondary
        }
    }
}

/// A plan split for review: the summary before the first section heading,
/// then one section per `##` heading (or `#` when the plan has no `##`).
struct ProposalSections {
    struct Section {
        let title: String
        let markdown: String
        var parts: [Part] { Choice.split(markdown) }
    }
    let summary: String
    let items: [Section]

    init(_ plan: String) {
        let lines = plan.components(separatedBy: "\n")
        let level = lines.contains { $0.hasPrefix("## ") } ? "## " : "# "
        var summary: [String] = []
        var items: [Section] = []
        var title: String?
        var body: [String] = []
        var inFence = false
        var skippedTitle = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            if !inFence, level == "## ", !skippedTitle, title == nil, line.hasPrefix("# ") {
                skippedTitle = true            // the document title is shown in the header
                continue
            }
            if !inFence, line.hasPrefix(level) {
                if let t = title { items.append(Section(title: t, markdown: body.joined(separator: "\n"))) }
                title = String(line.dropFirst(level.count)).trimmingCharacters(in: .whitespaces)
                body = [line]
            } else if title == nil {
                summary.append(line)
            } else {
                body.append(line)
            }
        }
        if let t = title { items.append(Section(title: t, markdown: body.joined(separator: "\n"))) }
        if level == "# " && items.count == 1 && summary.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            // A single "# Title" plan: show its body as the summary.
            let only = items[0].markdown.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            self.summary = only.trimmingCharacters(in: .whitespacesAndNewlines)
            self.items = []
        } else {
            self.summary = summary.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            self.items = items
        }
    }
}

/// A decision inside a plan: a line ending in "?" followed by a list of
/// options, the one Claude suggests marked "(recommended)". Shown as options
/// you tap instead of a plain list.
struct Choice {
    struct Option: Hashable { let text: String; let recommended: Bool }
    let question: String
    let options: [Option]
    var recommended: Option? { options.first(where: \.recommended) }
}

enum Part {
    case markdown(String)
    case choice(Choice)
}

extension Choice {
    private static let item = try! NSRegularExpression(pattern: #"^(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?(.*)$"#)

    /// The section as Markdown with its choices cut out.
    static func split(_ markdown: String) -> [Part] {
        let lines = markdown.components(separatedBy: "\n")
        var parts: [Part] = []
        var text: [String] = []
        var inFence = false
        var i = 0
        func flush() {
            let t = text.joined(separator: "\n")
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.markdown(t)) }
            text = []
        }
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            text.append(line)
            i += 1
            guard !inFence, let q = question(line) else { continue }
            // Options: top-level list items right after the question (blank lines allowed).
            var j = i
            while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
            var options: [Option] = []
            while j < lines.count {
                let l = lines[j]
                if !l.hasPrefix(" "), let t = match(l) {
                    let rec = t.range(of: "(recommended)", options: .caseInsensitive) != nil
                        || t.lowercased().hasPrefix("**recommended")
                    options.append(Option(text: t, recommended: rec))
                } else if l.hasPrefix(" "), !l.trimmingCharacters(in: .whitespaces).isEmpty, let last = options.popLast() {
                    // a continuation line of the option above
                    options.append(Option(text: last.text + " " + l.trimmingCharacters(in: .whitespaces),
                                          recommended: last.recommended))
                } else { break }
                j += 1
            }
            guard options.count >= 2 else { continue }
            flush()
            parts.append(.choice(Choice(question: q, options: options)))
            i = j
        }
        flush()
        return parts
    }

    /// "Which database?" from "### Which database?", "**Which database?**" or "Which database?:"
    private static func question(_ line: String) -> String? {
        var t = line.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " *_:"))
        guard t.hasSuffix("?"), t.count > 3, match(t) == nil else { return nil }
        return t
    }

    private static func match(_ line: String) -> String? {
        let ns = line as NSString
        guard let m = item.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
    }
}

/// Media files referenced in Markdown (same rules as the daemon's normalizer).
enum MediaRefs {
    private static let exts = "png|jpe?g|gif|webp|heic|svg|stl|obj|ply|usdz|pdf|kicad_sch|kicad_pcb"
    private static let md = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(<?([^)\s>]+)>?\)"#)
    private static let code = try! NSRegularExpression(pattern: "`([^`\\s]+\\.(?:\(exts)))`", options: .caseInsensitive)

    static func find(in text: String) -> [String] {
        let ns = text as NSString
        var out: [String] = []
        for re in [md, code] {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let p = ns.substring(with: m.range(at: 1))
                if !p.contains("://"), p.range(of: "\\.(\(exts))$", options: [.regularExpression, .caseInsensitive]) != nil,
                   !out.contains(p) {
                    out.append(p)
                }
            }
        }
        return out
    }
}

enum ProposalTitle {
    /// Same rule as the daemon: the first non-empty line, without "#" or "Plan:".
    static func of(_ plan: String) -> String {
        for line in plan.split(separator: "\n") {
            var t = line.trimmingCharacters(in: .whitespaces)
            while t.hasPrefix("#") { t.removeFirst() }
            t = t.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Plan:") { t = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            if !t.isEmpty { return String(t.prefix(120)) }
        }
        return "Proposal"
    }
}
