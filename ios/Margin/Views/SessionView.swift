import PhotosUI
import SwiftUI

struct SessionView: View {
    let ws: WorkspaceState
    let sessionId: String
    @State private var draft = ""
    @State private var sending = false
    @State private var sentAt: Date?        // tapped send: show it's on its way before the host answers
    @State private var error: String?
    @State private var showThinking = false
    @State private var atBottom = true
    @State private var scrollRequest = 0
    @State private var openFile: FileTarget?
    @State private var openProposal: String?
    @State private var photo: PhotosPickerItem?
    @State private var interrupted = false
    @State private var voice = Dictation()
    @State private var voiceText = ""
    @State private var allowedToast: String?
    @State private var ideaIds: [String] = []       // ideas put in the message box: marked used once it's sent
    #if DEBUG
    // Simulator screenshots: SIMCTL_CHILD_MARGIN_TAB=Changes opens chats on that tab.
    @State private var tab: ChatTab = ProcessInfo.processInfo.environment["MARGIN_TAB"].flatMap(ChatTab.init(rawValue:)) ?? .chat
    #else
    @State private var tab: ChatTab = .chat
    #endif
    @State private var filesFolder = ""
    @State private var filesFile: FileEntry?
    @State private var previewTarget: WebTarget?
    @State private var shellSelected: String?
    @State private var filesFocus: (path: String, lines: ClosedRange<Int>)?
    @State private var changesFocus: String?
    @State private var focus = false        // full screen: the tab's content, nothing else
    @Environment(\.expandDetail) private var expanded
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }      // iPhone, or a narrow iPad split

    private var tabPicker: some View {
        Picker("Show", selection: $tab) {
            ForEach(ChatTab.allCases) { t in
                Image(systemName: t.icon).accessibilityLabel(t.rawValue).tag(t)   // icons on iPad and phone alike
            }
        }
        .pickerStyle(.segmented)
    }
    @State private var composerFocused = false

    private var cwd: String? { ws.session(sessionId)?.cwd }
    private var project: String? { ws.session(sessionId)?.project }

    private var items: [TranscriptItem] {
        (ws.transcripts[sessionId] ?? []).filter { showThinking || $0.kind != "thinking" }
    }
    private var status: String { ws.status(of: sessionId) }
    private var busy: Bool { ["running", "starting", "waiting"].contains(status) }
    private var offline: Bool { if case .offline = ws.connection { true } else { false } }

    /// tool_use id → its result, so each tool call renders with its output.
    private var resultsByTool: [String: TranscriptItem] {
        var d: [String: TranscriptItem] = [:]
        for it in ws.transcripts[sessionId] ?? [] where it.kind == "tool_result" {
            if let t = it.toolUseId { d[t] = it }
        }
        return d
    }

    /// The conversation and the message box.
    private var chatPane: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        let results = resultsByTool
                        // Position-based ids stay the same when history reloads, so
                        // SwiftUI keeps the rows (and the scroll position) instead of
                        // rebuilding the list.
                        ForEach(Array(items.filter { $0.kind != "tool_result" }.enumerated()), id: \.offset) { _, item in
                            TranscriptRow(ws: ws, cwd: cwd, item: item,
                                          result: item.toolId.flatMap { results[$0] },
                                          openFile: { openFile = $0 },
                                          openProposal: { plan in
                                              let ps = ws.proposals(for: sessionId)
                                              openProposal = (ps.last { $0.plan == plan } ?? ps.last)?.id
                                          })
                        }
                        ForEach(ws.pending(for: sessionId)) { req in
                            ApprovalCard(ws: ws, request: req).id(req.requestId)
                        }
                        if let r = ws.results[sessionId], !busy {
                            ResultFooter(result: r)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { atBottom = true }
                            .onDisappear { atBottom = false }
                    }
                    .frame(maxWidth: Theme.chatWidth, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .task {
                    // Rows are measured lazily: right after opening a chat, the
                    // bottom anchor can land on space not yet filled in. Settle
                    // on the real end once rows have been laid out.
                    for wait in [50, 250, 600] {
                        try? await Task.sleep(for: .milliseconds(wait))
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: ws.transcripts[sessionId]?.count ?? 0) { old, _ in
                    // First load jumps to the end; after that, follow new output only
                    // while you're already at the bottom, so reading back isn't yanked.
                    if old == 0 || atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                    if old == 0 {
                        Task {
                            for wait in [80, 400] {
                                try? await Task.sleep(for: .milliseconds(wait))
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                }
                .onChange(of: ws.pending(for: sessionId).count) {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: scrollRequest) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if busy || sentAt != nil { activityLine }
            Divider()
            composer
                .frame(maxWidth: Theme.chatWidth)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch tab {
            case .chat: chatPane
            case .changes:
                if let project {
                    CodeReviewView(ws: ws, project: project, chatSessionId: sessionId, focusPath: changesFocus) { _ in tab = .chat }
                }
            case .files:
                if let project {
                    ChatFilesView(ws: ws, project: project, folder: $filesFolder, file: $filesFile, focusLines: filesFocus?.path == filesFile?.path ? filesFocus?.lines : nil)
                }
            case .preview:
                ChatPreviewView(ws: ws, project: project, sessionId: sessionId, target: $previewTarget) { task in
                    shellSelected = "task:\(task)"
                    withAnimation { tab = .shell }
                }
            case .shell:
                if let project {
                    ChatShellView(ws: ws, project: project, sessionId: sessionId, selected: $shellSelected)
                }
            }
        }
        .background {
            // Esc interrupts, as in Claude Code (⌘. on the stop button too).
            if busy {
                Button("Interrupt", action: stop)
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .background {
            // Keyboard: ⌘1–⌘5 for the tabs, ⌘L to the message box, ⌘⇧A / ⌘⇧D to allow or deny
            // what's waiting, ⌘⇧P for the plan to review.
            Group {
                ForEach(Array(ChatTab.allCases.enumerated()), id: \.offset) { i, t in
                    Button(t.rawValue) { withAnimation { tab = t } }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
                Button("Write a message") { tab = .chat; composerFocused = true }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Allow what's waiting") { allowNext() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(ws.pending(for: sessionId).isEmpty)
                Button("Deny what's waiting") { denyNext() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(ws.pending(for: sessionId).isEmpty)
                Button("Review the plan") {
                    if let p = ws.latestProposal(for: sessionId), p.isPending { openProposal = p.id }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .toolbar(focus ? .hidden : .automatic, for: .navigationBar)
        .statusBarHidden(focus)
        .overlay(alignment: .topTrailing) {
            if focus {
                Button { setFocus(false) } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(Theme.Fonts.body.weight(.semibold)).padding(10)
                        .background(.regularMaterial, in: Circle())
                }
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel("Leave full screen")
                .padding(12)
            }
        }
        .navigationTitle(ws.session(sessionId)?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)          // title on the left, the tabs in the middle
        // On a phone the tabs get their own row under the title.
        .safeAreaInset(edge: .top, spacing: 0) {
            if compact && !focus {
                tabPicker
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
        .toolbar {
            if !compact {
                ToolbarItem(placement: .principal) { tabPicker.fixedSize() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if compact {
                    StatusDot(status: status)
                    ChatSettingsMenu(ws: ws, sessionId: sessionId, showThinking: $showThinking)
                    if busy {
                        Button(role: .destructive, action: stop) { Image(systemName: "stop.circle") }
                            .keyboardShortcut(".", modifiers: .command)
                    }
                    Button { setFocus(true) } label: { Image(systemName: "viewfinder") }
                        .accessibilityLabel("Full screen")
                } else {
                    WorkspaceBadge(ws: ws)
                    HStack(spacing: 4) {
                        StatusDot(status: status)
                        if let words = StatusDot.words(status) {
                            Text(words).font(Theme.Fonts.caption).foregroundStyle(.secondary)
                        }
                    }
                    // Hiding the sidebar is the system's own button (or ⌃⌘S).
                    ChatSettingsMenu(ws: ws, sessionId: sessionId, showThinking: $showThinking)
                    Button { setFocus(true) } label: { Image(systemName: "viewfinder") }
                        .keyboardShortcut("f", modifiers: [.command, .shift])
                        .help("Full screen: just this \(tab.rawValue.lowercased())")
                    if busy {
                        Button(role: .destructive, action: stop) {
                            Image(systemName: "stop.circle")
                        }
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Interrupt (Esc)")
                    }
                }
            }
        }
        .onChange(of: ws.activity[sessionId] != nil) { _, has in if has { sentAt = nil } }
        .onChange(of: status) { old, new in
            // Ended without ever reporting (an error, or nothing to do): stop showing "Sending".
            if ["running", "starting", "waiting"].contains(old), !["running", "starting", "waiting"].contains(new) { sentAt = nil }
        }
        .task {
            await ws.loadHistory(sessionId)
            await ws.loadSettings(sessionId)
            if let project { await ws.loadActions(project) }
            #if DEBUG
            // Simulator screenshots: SIMCTL_CHILD_MARGIN_FILE=path opens a file in the Files tab.
            if let f = ProcessInfo.processInfo.environment["MARGIN_FILE"],
               let t = ws.fileTarget(f, cwd: ws.session(sessionId)?.cwd) { show(t) }
            // MARGIN_PREVIEW=<port> opens that page in the Preview tab; MARGIN_SHELL=<shell id or task:<id>> picks a shell.
            if let p = ProcessInfo.processInfo.environment["MARGIN_PREVIEW"].flatMap(Int.init) { previewTarget = WebTarget(port: p) }
            if let s = ProcessInfo.processInfo.environment["MARGIN_SHELL"] { shellSelected = s }
            #endif
        }
        // Pencil double-tap: allow the oldest request waiting in this session, then the next.
        .onPencilDoubleTap(enabled: !ws.pending(for: sessionId).isEmpty) { allowNext() }
        .overlay(alignment: .top) {
            if let allowedToast {
                Label(allowedToast, systemImage: "checkmark.circle.fill")
                    .font(Theme.Fonts.meta).lineLimit(1)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: allowedToast) {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { self.allowedToast = nil }
                    }
            }
        }
        .projectLinks(ws, cwd: cwd, open: Binding(get: { nil }, set: { t in if let t { show(t) } }))
        .environment(\.openWebPreview) { t in
            previewTarget = t
            withAnimation { tab = .preview }
        }
        .environment(\.reviewSessionId, sessionId)
        .environment(\.markupSink) { [draft = draftAttachments] in draft.markups.append($0) }
        .sheet(item: $openFile) { target in
            NavigationStack {
                FilePreviewView(ws: ws, project: target.project, entry: target.entry)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { openFile = nil } }
                    }
                    .environment(\.reviewSessionId, sessionId)
            }
        }
        .sheet(isPresented: Binding(get: { openProposal != nil }, set: { if !$0 { openProposal = nil } })) {
            if let id = openProposal {
                NavigationStack {
                    ProposalView(ws: ws, proposalId: id)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Done") { openProposal = nil } }
                        }
                }
            }
        }
        .onChange(of: photo) {
            guard let item = photo else { return }
            photo = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    attach(img, source: "Photo")
                }
            }
        }
    }

    private var draftAttachments: ReviewDraft { ws.draft(for: sessionId) }

    private func attach(_ image: UIImage, source: String) {
        draftAttachments.markups.append(Markup(image: image, note: "", source: source))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let project {
                ActionBar(ws: ws, project: project, sessionId: sessionId) { r in
                    switch r.kind {
                    case "run":
                        shellSelected = r.terminal?.id
                        withAnimation { tab = .shell }
                    case "open":
                        if let u = r.url.flatMap(URL.init(string:)), let t = WebTarget(url: u) {
                            previewTarget = t
                            withAnimation { tab = .preview }
                        }
                    default:
                        scrollRequest += 1
                    }
                }
            }
            pointers
            replies
            wakeups
            if let p = ws.latestProposal(for: sessionId), p.isPending {
                Button { openProposal = p.id } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass").font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Proposal\(p.version > 1 ? " v\(p.version)" : "") needs your decision")
                                .font(Theme.Fonts.meta.weight(.semibold))
                            Text(MarkdownBlocks.title(p.title)).font(Theme.Fonts.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("Review").font(Theme.Fonts.meta.weight(.semibold))
                        Image(systemName: "chevron.right").font(Theme.Fonts.caption)
                    }
                    .padding(12)
                    .background(Theme.needsYou.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.cardCorner))
                }
                .buttonStyle(.plain)
            }
            if status == "active_elsewhere" {
                Label("This session looks open at your desk. Sending from here too can tangle the transcript.",
                      systemImage: "exclamationmark.triangle")
                    .font(Theme.Fonts.caption).foregroundStyle(.orange)
            }
            if offline { offlineNote }
            if let error { Text(error).font(Theme.Fonts.caption).foregroundStyle(.red) }
            ForEach(ws.queued[sessionId] ?? []) { q in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(q.text).font(Theme.Fonts.body).lineLimit(3)
                        Text(status == "starting" ? "Starting Claude Code · this goes first"
                                                  : "Queued · goes to Claude when it finishes")
                            .font(Theme.Fonts.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await ws.cancelQueued(sessionId, id: q.id) } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Don't send")
                }
                .padding(10)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner))
            }
            if voice.isRecording || !voiceText.isEmpty {
                voiceNote
            }
            if !draftAttachments.markups.isEmpty {
                MarkupStrip(draft: draftAttachments)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Photo library", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        if let img = UIPasteboard.general.image { attach(img, source: "Pasted image") }
                    } label: {
                        Label("Paste image", systemImage: "doc.on.clipboard")
                    }
                    .disabled(!UIPasteboard.general.hasImages)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: Theme.composerHeight, height: Theme.composerHeight)
                        .background(Theme.fieldBackground, in: Circle())
                        .overlay(Circle().stroke(Color(uiColor: .separator).opacity(0.4)))
                }
                .accessibilityLabel("Attach an image")
                if let project, !ws.openIdeas(project).isEmpty { ideasMenu(project) }
                ComposerField(placeholder: placeholder, text: $draft, maxLines: 8, focused: $composerFocused,
                              onSubmit: send, onEscape: {
                                  guard busy else { return false }
                                  stop()
                                  return true
                              }) {
                    Button(action: toggleVoiceNote) {
                        VoiceGlyph(recording: voice.isRecording, level: voice.level, size: 22)
                            .frame(width: Theme.composerButton, height: Theme.composerButton)
                    }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .help("Voice note (⇧⌘V): speak, tap again to send. Queued if Claude is working.")
                    .accessibilityLabel(voice.isRecording ? "Send voice note" : "Record a voice note")
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .frame(width: Theme.composerButton, height: Theme.composerButton)
                    }
                    .disabled(!canSend || sending)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Send")
                }
            }
        }
        .onAppear(perform: takeIdeas)
        .onChange(of: ws.composerInserts[sessionId]) { takeIdeas() }
        .dropDestination(for: Data.self) { items, _ in
            let images = items.compactMap(UIImage.init(data:))
            images.forEach { attach($0, source: "Dropped image") }
            return !images.isEmpty
        }
    }

    /// Speak and it goes to Claude: straight away if it's free, otherwise
    /// queued for when it finishes. "Stop & send" interrupts first.
    private var voiceNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(.red)
                    .symbolEffect(.variableColor.iterative, isActive: voice.isRecording)
                Text(voice.isRecording ? "Listening…" : "Voice note").font(Theme.Fonts.caption.weight(.semibold))
                Spacer()
                Button("Discard", role: .destructive) { voice.stop(); voiceText = "" }
                    .font(Theme.Fonts.caption)
            }
            Text(voiceText.isEmpty ? "Speak now" : voiceText)
                .font(Theme.Fonts.body)
                .foregroundStyle(voiceText.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if busy {
                    Button { finishVoiceNote(interrupt: true) } label: {
                        Label("Stop Claude & send", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button { finishVoiceNote(interrupt: false) } label: {
                    Label(busy ? "Queue it" : "Send", systemImage: busy ? "clock" : "arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
            .font(Theme.Fonts.meta)
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.corner))
        .alert("Voice notes unavailable", isPresented: Binding(
            get: { voice.error != nil }, set: { if !$0 { voice.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(voice.error ?? "") }
    }

    private func toggleVoiceNote() {
        if voice.isRecording { finishVoiceNote(interrupt: false) }
        else { voiceText = ""; voice.start(appendingTo: "") { voiceText = $0 } }
    }

    private func finishVoiceNote(interrupt: Bool) {
        voice.stop()
        Task {
            try? await Task.sleep(for: .milliseconds(700))      // the final transcription lands after stopping
            let text = voiceText.trimmingCharacters(in: .whitespacesAndNewlines)
            voiceText = ""
            guard !text.isEmpty else { return }
            do {
                try await ws.send(sessionId, text: "(voice note) " + text)
                if interrupt { await ws.interrupt(sessionId) }
                error = nil
                scrollRequest += 1
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// What Claude asked to show: a page in the Preview tab, a file in Files.
    private func setFocus(_ on: Bool) {
        withAnimation {
            focus = on
            if on { expanded?.wrappedValue = true }
        }
    }

    /// Claude Code's spinner line: what it's doing, for how long, how many tokens.
    private var activityLine: some View {
        let a = ws.activity[sessionId]
        return TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 8) {
                Image(systemName: status == "waiting" ? "hand.raised.fill" : "asterisk")
                    .foregroundStyle(status == "waiting" ? Theme.needsYou : Color.accentColor)
                    .symbolEffect(.pulse, isActive: status != "waiting")
                Text(status == "waiting" ? "Waiting for you" : (a?.doing ?? Self.before(status)))
                    .font(Theme.Fonts.meta.weight(.medium))
                if let d = a?.detail, !d.isEmpty, status != "waiting" {
                    Text(d).font(Theme.Fonts.meta.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if a == nil, let sentAt {
                    Text(Self.elapsed(ctx.date.timeIntervalSince(sentAt)))
                        .font(Theme.Fonts.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if let a {
                    Text([Self.elapsed(ctx.date.timeIntervalSince1970 - a.startedAt),
                          a.tokens > 0 ? "↓ \(Self.tokens(a.tokens)) tokens" : nil,
                          "esc to interrupt"].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.Fonts.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: Theme.chatWidth)
        .padding(.horizontal, 20).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    /// Before Claude reports what it's doing: still sending, or Claude Code starting up.
    private static func before(_ status: String) -> String {
        switch status {
        case "starting": "Starting Claude Code"
        case "running": "Thinking"
        default: "Sending"
        }
    }

    private static func elapsed(_ s: Double) -> String {
        let t = max(0, Int(s))
        return t < 60 ? "\(t)s" : t < 3600 ? "\(t / 60)m \(t % 60)s" : "\(t / 3600)h \(t % 3600 / 60)m"
    }

    private static func tokens(_ n: Int) -> String {
        n < 1000 ? "\(n)" : String(format: "%.1fk", Double(n) / 1000)
    }

    /// You tapped something Claude pointed at: open it here, then it's off the list.
    private func present(_ s: ShowItem) {
        if s.kind == "page", let port = s.port {
            previewTarget = WebTarget(port: port, path: s.path ?? "/")
            withAnimation { tab = .preview }
        } else if s.kind == "changes", let p = s.path {
            changesFocus = p
            withAnimation { tab = .changes }
        } else if let p = s.path, let t = ws.fileTarget(p, cwd: cwd) {
            filesFocus = s.line.map { (t.entry.path, $0...max($0, s.endLine ?? $0)) }
            show(t)
        }
        Task { await ws.dismissShow(sessionId, id: s.id) }
    }

    /// What Claude pointed at, waiting for you: nothing opens until you tap it.
    @ViewBuilder private var pointers: some View {
        let items = ws.shows[sessionId] ?? []
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Label("Claude", systemImage: "sparkle").font(Theme.Fonts.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(items.reversed()) { s in
                        HStack(spacing: 6) {
                            Button { present(s) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: s.icon)
                                    Text(s.title).lineLimit(1)
                                }
                                .font(Theme.Fonts.meta.weight(.medium))
                            }
                            .buttonStyle(.plain)
                            .help(s.note ?? s.title)
                            Button { Task { await ws.dismissShow(sessionId, id: s.id) } } label: {
                                Image(systemName: "xmark").font(Theme.Fonts.small.weight(.bold))
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Not now")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
    }

    /// Answers Claude offered for its question: a tap puts one in your message, to edit or send.
    /// Shown as soon as Claude offers them, even while it finishes its turn:
    /// nothing is sent until you send it.
    @ViewBuilder private var replies: some View {
        let options = ws.replies[sessionId] ?? []
        if !options.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { o in
                        Button(o) {
                            draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? o : draft + " " + o
                        }
                        .buttonStyle(.bordered)
                        .font(Theme.Fonts.meta)
                    }
                }
            }
        }
    }

    /// When Claude will check back on its own (a wakeup it scheduled), like
    /// Claude Code's line under the prompt.
    @ViewBuilder private var wakeups: some View {
        let next = (ws.wakeups[sessionId] ?? []).filter { $0.nextAt != nil }.min { $0.nextAt! < $1.nextAt! }
        if let w = next, let at = w.nextAt {
            let date = Date(timeIntervalSince1970: at)
            let when = Calendar.current.isDateInToday(date)
                ? date.formatted(date: .omitted, time: .shortened)
                : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            HStack(spacing: 6) {
                Image(systemName: w.recurring ? "repeat" : "alarm")
                Text("Claude will check back at \(when)")
                if !w.prompt.isEmpty {
                    Text("· \(w.prompt)").foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .font(Theme.Fonts.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A file Claude linked: this project's open in the Files tab (filling
    /// the pane); another project's in a sheet.
    private func show(_ t: FileTarget) {
        guard t.project == project else { openFile = t; return }
        filesFolder = (t.entry.path as NSString).deletingLastPathComponent
        filesFile = t.entry
        withAnimation { tab = .files }
    }

    private func denyNext() {
        guard let req = ws.pending(for: sessionId).first else { return }
        Task { try? await ws.decide(req, allow: false) }
    }

    private func allowNext() {
        guard let req = ws.pending(for: sessionId).first else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let left = ws.pending(for: sessionId).count - 1
        withAnimation {
            allowedToast = "Allowed \(req.toolName)" + (left > 0 ? " · \(left) more waiting" : "")
        }
        Task { try? await ws.decide(req, allow: true) }
    }

    private var placeholder: String {
        if offline && project != nil { return "An idea for later" }
        if interrupted && !busy { return "Interrupted · what should Claude do instead?" }
        return busy ? "Claude is working… Esc to interrupt, or add a message for after" : "Reply to Claude"
    }

    /// Stops the current turn and puts you in the reply box to redirect it.
    private func stop() {
        interrupted = true
        composerFocused = true
        Task { await ws.interrupt(sessionId) }
    }

    /// The computer is out of reach: you're reading what was saved, and a
    /// message waits as an idea instead of going anywhere.
    private var offlineNote: some View {
        Label {
            Text("\(ws.machine) is offline. ")
                + Text(ws.lastOnline.map { "This is the chat as of \($0.formatted(date: .omitted, time: .shortened)). " } ?? "")
                + Text(project.map { "What you write is kept as an idea for \($0)." } ?? "")
        } icon: {
            Image(systemName: "wifi.slash")
        }
        .font(Theme.Fonts.caption).foregroundStyle(.secondary)
    }

    /// Ideas saved for this project: one tap puts it in your message.
    private func ideasMenu(_ project: String) -> some View {
        Menu {
            ForEach(ws.openIdeas(project)) { i in
                Button(i.text.count > 80 ? String(i.text.prefix(80)) + "…" : i.text) { insertIdea(i.text, id: i.id) }
                    .disabled(ideaIds.contains(i.id))
            }
        } label: {
            Image(systemName: "lightbulb")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: Theme.composerHeight, height: Theme.composerHeight)
                .background(Theme.fieldBackground, in: Circle())
                .overlay(Circle().stroke(Color(uiColor: .separator).opacity(0.4)))
                .overlay(alignment: .topTrailing) {
                    Text("\(ws.openIdeas(project).count)")
                        .font(Theme.Fonts.small.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).background(Color.accentColor, in: Capsule())
                        .offset(x: 4, y: -4)
                }
        }
        .accessibilityLabel("Ideas for \(project)")
    }

    private func insertIdea(_ text: String, id: String) { insertIdeas(IdeaInsert(text: text, ids: [id])) }

    private func insertIdeas(_ ins: IdeaInsert) {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = t.isEmpty ? ins.text : t + "\n\n" + ins.text
        ideaIds += ins.ids
        composerFocused = true
    }

    /// Ideas sent here from the Ideas page.
    private func takeIdeas() {
        if let ins = ws.composerInserts.removeValue(forKey: sessionId) { insertIdeas(ins) }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.markups.isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        if offline, let project {
            // Nothing can reach Claude now: keep it for later instead.
            guard !text.isEmpty else { return }
            ws.addIdea(text, project: project)
            // Ideas put in the box are part of the new one now.
            for id in ideaIds { if let i = ws.ideas[project]?.first(where: { $0.id == id }) { ws.deleteIdea(i, project: project) } }
            draft = ""
            ideaIds = []
            withAnimation { allowedToast = "Kept as an idea for \(project)" }
            return
        }
        sending = true
        draft = ""                  // it's on its way: the box empties now, not when the host answers
        if !busy { sentAt = Date() }
        Task {
            do {
                try await ws.sendWithAttachments(sessionId, text: text)
                if let project, !ideaIds.isEmpty { ws.markIdeas(ideaIds, usedIn: sessionId, project: project) }
                ideaIds = []
                error = nil
                interrupted = false
                scrollRequest += 1
            } catch {
                if draft.isEmpty { draft = text }       // didn't go: put it back
                sentAt = nil
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}

/// A file in one of the workspace's projects, opened from a transcript row.
struct FileTarget: Identifiable {
    let project: String
    let entry: FileEntry
    var id: String { project + "/" + entry.path }
}

struct TranscriptRow: View {
    let ws: WorkspaceState
    let cwd: String?
    let item: TranscriptItem
    let result: TranscriptItem?
    let openFile: (FileTarget) -> Void
    var openProposal: (String) -> Void = { _ in }
    @State private var expanded = false
    @Environment(\.reviewSessionId) private var reviewSessionId

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
                // Circle or underline anything in the chat with the Pencil; it goes with your reply.
                .inkable(enabled: reviewSessionId != nil && markable, source: markupSource) { m in
                    if let sid = reviewSessionId { ws.draft(for: sid).markups.append(m) }
                }
            ForEach(mediaPaths, id: \.self) { path in
                // Paths mentioned in prose may be loose; only tool paths show load errors.
                MediaThumb(ws: ws, path: path, cwd: cwd, hideIfMissing: item.kind == "text")
            }
            if mediaPaths.isEmpty {   // a Read of an image already shows the file itself
                ForEach(Array((result?.images ?? []).enumerated()), id: \.offset) { _, img in
                    InlineImageView(image: img)
                }
            }
        }
        .padding(.leading, item.parentToolUseId == nil ? 0 : 24)
        .padding(.vertical, ["text", "user_text"].contains(item.kind) ? 8 : 0)
    }

    private var markable: Bool {
        ["text", "user_text", "tool_use"].contains(item.kind) && item.name != "ExitPlanMode"
    }

    private var markupSource: String {
        switch item.kind {
        case "user_text": return "my earlier message"
        case "text": return "your message: “\((item.text ?? "").prefix(60))…”"
        default: return "\(name)" + (filePath.map { " of \($0)" } ?? (summary.isEmpty ? "" : ": \(summary.prefix(80))"))
        }
    }

    @ViewBuilder private var content: some View {
            switch item.kind {
            case "user_text":
                HStack {
                    Spacer(minLength: 60)
                    MarkdownText(text: item.text ?? "")
                        .padding(12)
                        .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: Theme.corner))   // neutral: blue is for tapping
                }
            case "tool_use" where item.name == "ExitPlanMode":
                planCard
            case "text":
                MarkdownText(text: item.text ?? "", color: item.error == true ? .red : .primary)
            case "thinking":
                Text(item.text ?? "").font(Theme.Fonts.meta).italic().foregroundStyle(.secondary)
            case "tool_use":
                toolCall
            default:
                EmptyView()
            }
    }

    // MARK: tool calls

    private var planCard: some View {
        let plan = item.input?["plan"]?.stringValue ?? ""
        return Button { openProposal(plan) } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Presented a proposal").font(Theme.Fonts.caption).foregroundStyle(.secondary)
                    Text(ProposalTitle.of(plan)).font(.system(.headline, design: .serif)).lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Color(uiColor: .separator).opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    private var name: String { item.name ?? "tool" }
    private var filePath: String? { item.input?["file_path"]?.stringValue ?? item.input?["notebook_path"]?.stringValue }
    private var hasMedia: Bool { !(item.media ?? []).isEmpty }

    /// Image paths made absolute against the session folder, without repeats.
    private var mediaPaths: [String] {
        var seen = Set<String>()
        return (item.media ?? []).compactMap { p in
            let abs = p.hasPrefix("/") || cwd == nil ? p : (cwd! as NSString).appendingPathComponent(p)
            let norm = (abs as NSString).standardizingPath
            return seen.insert(norm).inserted ? norm : nil
        }
    }

    private var toolCall: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: result == nil ? "gearshape" : (result?.isError == true ? "xmark.octagon" : "checkmark.circle"))
                        .foregroundStyle(result?.isError == true ? Color.red : Color.secondary)
                    Text(name).font(Theme.Fonts.meta.weight(.medium)).foregroundStyle(.secondary)
                    if let filePath, let target = fileTarget(filePath) {
                        Button { openFile(target) } label: {
                            Text(display(filePath)).font(.system(.caption, design: .monospaced)).lineLimit(1)
                                .truncationMode(.head)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Text(summary).font(.system(.caption, design: .monospaced)).lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(Theme.Fonts.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            preview

            if expanded { details }
        }
        .padding(.vertical, 2)          // a quiet line, not a box: what it did, in grey
        .inkAnchor("tool-\(item.toolId ?? name)", "your \(name) call" + (filePath.map { " on \($0)" } ?? (summary.isEmpty ? "" : ": `\(summary.prefix(160))`")))
    }

    /// Always-visible preview: diffs for edits, code for writes, the command for Bash.
    @ViewBuilder private var preview: some View {
        switch name {
        case "Edit":
            if let old = item.input?["old_string"]?.stringValue, let new = item.input?["new_string"]?.stringValue {
                DiffBlock(path: filePath, edits: [(old, new)])
            }
        case "MultiEdit":
            if case .array(let edits)? = item.input?["edits"] {
                DiffBlock(path: filePath, edits: edits.compactMap { e in
                    guard let o = e["old_string"]?.stringValue, let n = e["new_string"]?.stringValue else { return nil }
                    return (o, n)
                })
            }
        case "Write":
            if !hasMedia, let content = item.input?["content"]?.stringValue {
                CodeBlock(code: content, language: filePath.map(Highlighter.language(forPath:)),
                          title: filePath.map { ($0 as NSString).lastPathComponent },
                          lineNumbers: true, collapsedLines: 14)
            }
        case "Bash":
            if let cmd = item.input?["command"]?.stringValue, cmd.count > 60 || cmd.contains("\n") {
                CodeBlock(code: cmd, language: "sh", title: item.input?["description"]?.stringValue,
                          collapsedLines: 8)
            }
        default:
            EmptyView()
        }
    }

    /// Shown when the row is expanded: the tool's output, as code where it is code.
    @ViewBuilder private var details: some View {
        let out = result?.text ?? ""
        switch name {
        case "Read" where !hasMedia:
            if let listing = parseNumberedListing(out) {
                CodeBlock(code: listing.code, language: filePath.map(Highlighter.language(forPath:)),
                          title: filePath.map { ($0 as NSString).lastPathComponent },
                          lineNumbers: true, startLine: listing.start)
            } else { plainOutput(out) }
        case "Bash":
            if let cmd = item.input?["command"]?.stringValue, cmd.count <= 60, !cmd.contains("\n") {
                CodeBlock(code: cmd, language: "sh", title: item.input?["description"]?.stringValue)
            }
            if !out.isEmpty { CodeBlock(code: out, language: nil, title: "output", collapsedLines: 40) }
        case "Edit", "MultiEdit", "Write":
            if result?.isError == true { plainOutput(out) }
        default:
            if let input = item.input { CodeBlock(code: input.pretty, language: "json", title: "input") }
            if !out.isEmpty { plainOutput(out) }
        }
    }

    private func plainOutput(_ s: String) -> some View {
        CodeBlock(code: s, language: nil, title: result?.isError == true ? "error" : "output", collapsedLines: 40)
            .foregroundStyle(result?.isError == true ? Color.red : Color.primary)
    }

    private var summary: String {
        for k in ["command", "file_path", "filePath", "path", "pattern", "url", "query", "description"] {
            if let v = item.input?[k]?.stringValue { return v }
        }
        return ""
    }

    // MARK: file links

    /// The path relative to its project, for display.
    private func display(_ path: String) -> String {
        fileTarget(path)?.entry.path ?? path
    }

    private func fileTarget(_ path: String) -> FileTarget? { ws.fileTarget(path, cwd: cwd) }
}

struct ResultFooter: View {
    let result: SessionResult
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(result.isError ? Color.red : Color.green)
            if let t = result.numTurns { Text("\(t) turns") }
            if let ms = result.durationMs { Text(Duration.milliseconds(ms).formatted(.units(allowed: [.minutes, .seconds]))) }
            if let c = result.costUsd { Text(c, format: .currency(code: "USD")) }
        }
        .font(Theme.Fonts.caption).foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}

/// This chat's permission mode, model and effort, switchable while it runs.
private struct ChatSettingsMenu: View {
    let ws: WorkspaceState
    let sessionId: String
    @Binding var showThinking: Bool

    private static let modes = ["default", "auto", "acceptEdits", "plan"]

    var body: some View {
        let s = ws.settings[sessionId]
        Menu {
            if let s {
                Picker("Permissions", selection: Binding(
                    get: { s.permissionMode },
                    set: { m in Task { await ws.updateSettings(sessionId, mode: m) } })) {
                    ForEach(Self.modes + (Self.modes.contains(s.permissionMode) ? [] : [s.permissionMode]), id: \.self) { m in
                        Label(SessionSettings.modeName(m), systemImage: SessionSettings.modeIcon(m)).tag(m)
                    }
                }
                .pickerStyle(.inline)
                if !s.models.isEmpty {
                    Picker("Model", selection: Binding(
                        get: { s.model ?? "default" },
                        set: { m in Task { await ws.updateSettings(sessionId, model: m == "default" ? "" : m) } })) {
                        ForEach(s.models) { m in
                            Text(m.displayName ?? m.value).tag(m.value)
                        }
                    }
                    .pickerStyle(.menu)
                }
                let levels = s.models.first { $0.value == (s.model ?? "default") }?.supportedEffortLevels
                    ?? ["low", "medium", "high", "xhigh", "max"]
                Picker("Effort", selection: Binding(
                    get: { s.effort ?? "" },
                    set: { e in Task { await ws.updateSettings(sessionId, effort: e) } })) {
                    Text("Default").tag("")
                    ForEach(levels, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .pickerStyle(.menu)
            } else {
                Text("Loading…")
            }
            Section {
                Toggle(isOn: $showThinking) { Label("Show Claude's thinking", systemImage: "brain") }
            }
        } label: {
            Label(s.map { SessionSettings.modeName($0.permissionMode) } ?? "Mode",
                  systemImage: s.map { SessionSettings.modeIcon($0.permissionMode) } ?? "slider.horizontal.3")
                .labelStyle(.titleAndIcon)
                .font(Theme.Fonts.caption)
        }
        .help("Permission mode, model and effort for this chat, and whether to show Claude's thinking")
        .onAppear { if s == nil { Task { await ws.loadSettings(sessionId) } } }
    }
}
