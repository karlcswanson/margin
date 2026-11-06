import SwiftUI

/// What a chat shows: the conversation, and the project it works in
/// (its git changes, its files, the web pages it serves).
enum ChatTab: String, CaseIterable, Identifiable {
    case chat = "Chat", changes = "Changes", files = "Files", preview = "Preview", shell = "Shell"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .changes: "arrow.triangle.branch"
        case .files: "folder"
        case .preview: "globe"
        case .shell: "terminal"
        }
    }
}

// MARK: - Files

/// The chat's project as a browser. A file opens right here, filling the
/// pane, with a way back to the folder it was in.
struct ChatFilesView: View {
    let ws: WorkspaceState
    let project: String
    @Binding var folder: String
    @Binding var file: FileEntry?
    var focusLines: ClosedRange<Int>? = nil

    @State private var entries: [FileEntry] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var naming = false
    @State private var newName = ""
    @State private var creating: String?

    var body: some View {
        if let file {
            FilePreviewView(ws: ws, project: project, entry: file, focusLines: focusLines)
                .id(file.path)
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        Button { self.file = nil } label: {
                            Label(folder.isEmpty ? project : (folder as NSString).lastPathComponent,
                                  systemImage: "chevron.backward")
                        }
                        Text(file.name).font(Theme.Fonts.meta.weight(.semibold)).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.bar)
                }
        } else {
            List {
                Section {
                    if let error { Text(error).foregroundStyle(.red) }
                    ForEach(entries) { e in
                        Button {
                            if e.dir { folder = e.path } else { file = e }
                        } label: {
                            HStack {
                                Label(e.name, systemImage: e.dir ? "folder" : FileIcon.name(e.kind))
                                Spacer()
                                if let s = e.size, !e.dir {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file))
                                        .font(Theme.Fonts.caption).foregroundStyle(.secondary)
                                }
                                if e.dir { Image(systemName: "chevron.right").font(Theme.Fonts.caption).foregroundStyle(.tertiary) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    breadcrumbs
                }
            }
            .overlay { if !loaded { ProgressView() } }
            .task(id: folder) { await load() }
            .refreshable { await load() }
            .alert("New document", isPresented: $naming) {
                TextField("name.md", text: $newName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Create") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    creating = (folder as NSString).appendingPathComponent(name.contains(".") ? name : name + ".md")
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("In \(project)/\(folder)")
            }
            .fullScreenCover(isPresented: Binding(get: { creating != nil }, set: { if !$0 { creating = nil } }),
                             onDismiss: { Task { await load() } }) {
                if let creating { EditorView(ws: ws, project: project, path: creating, isNew: true) }
            }
        }
    }

    private var breadcrumbs: some View {
        let parts = folder.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button(project) { folder = "" }
                ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                    Image(systemName: "chevron.right").font(Theme.Fonts.small).foregroundStyle(.tertiary)
                    Button(p) { folder = parts[...i].joined(separator: "/") }
                }
                Button { newName = "untitled.md"; naming = true } label: {
                    Label("New document", systemImage: "doc.badge.plus")
                }
                .padding(.leading, 12)
            }
            .font(Theme.Fonts.meta)
            .textCase(nil)
        }
    }

    private func load() async {
        loaded = false
        do {
            entries = try await ws.api.files(project: project, path: folder)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

enum FileIcon {
    static func name(_ kind: String) -> String {
        switch kind {
        case "image": "photo"
        case "svg": "scribble.variable"
        case "pdf": "doc.richtext"
        case "model": "cube"
        case "cad": "cube.transparent"
        case "kicad": "cpu"
        case "markdown", "text", "csv": "doc.text"
        default: "doc"
        }
    }
}

// MARK: - Preview

/// Web pages running on the host: this project's servers first. The one you
/// open (or Claude links in the chat) shows right here.
struct ChatPreviewView: View {
    let ws: WorkspaceState
    let project: String?
    var sessionId: String? = nil
    @Binding var target: WebTarget?
    /// Show a server's output in the Shell tab: "task:<id>" for one of
    /// Claude's background commands, "screen:<name>" for a screen session.
    var showShell: ((String) -> Void)? = nil

    @State private var servers: [ListeningServer]?
    @State private var error: String?
    @State private var port = ""

    var body: some View {
        if let target {
            WebPreviewView(ws: ws, target: target, embedded: true)
                .id(target.id)
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        Button { self.target = nil } label: { Label("Servers", systemImage: "chevron.backward") }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(.bar)
                }
        } else {
            List {
                let pages = project.flatMap { ws.published[$0] } ?? []
                if !pages.isEmpty {
                    Section("Published by Claude") {
                        ForEach(pages) { p in
                            Button { target = WebTarget(port: p.port, path: p.path) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: p.kind == "service" ? "server.rack" : "globe")
                                        .foregroundStyle(p.alive == false ? Color.secondary : Color.accentColor)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.name).font(Theme.Fonts.body.weight(.medium))
                                        if let d = p.description, !d.isEmpty {
                                            Text(d).font(Theme.Fonts.caption).foregroundStyle(.secondary)
                                        }
                                        Text("localhost:\(String(p.port))\(p.path)" + (p.alive == false ? " · not running" : ""))
                                            .font(Theme.Fonts.caption.monospaced()).foregroundStyle(.tertiary)
                                    }
                                    .opacity(p.alive == false ? 0.55 : 1)       // a page whose server is down recedes
                                }
                            }
                            .tint(.primary)             // a row, not a blue link: the icon says it opens
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    if let project { Task { await ws.unpublish(p, project: project) } }
                                }
                            }
                        }
                    }
                }
                if let servers {
                    let unpublished = servers.filter { s in !pages.contains { $0.port == s.port } }
                    let claudes = unpublished.filter { $0.claudeSession != nil && $0.claudeSession == sessionId }
                    if !claudes.isEmpty {
                        Section("Claude started in this chat") {
                            ForEach(claudes) { s in claudeRow(s) }
                        }
                    }
                    let mine = unpublished.filter { project == nil || $0.project == project }
                        .filter { s in !claudes.contains { $0.port == s.port } }
                    if !mine.isEmpty {
                        Section("Running in \(project ?? "the host")") { rows(mine) }
                    } else if pages.isEmpty {
                        Text("Nothing is running for \(project ?? "this project"). Ask Claude to start the dev server; what it publishes shows here.")
                            .foregroundStyle(.secondary)
                    }
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
                Section("Another port") {
                    HStack {
                        TextField("5173", text: $port).keyboardType(.numberPad)
                        Button("Open") { if let p = Int(port) { target = WebTarget(port: p) } }
                            .disabled(Int(port) == nil)
                    }
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func claudeRow(_ s: ListeningServer) -> some View {
        Button { target = WebTarget(port: s.port) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkle").foregroundStyle(Color.accentColor).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.claudeDescription ?? "localhost:\(String(s.port))").font(Theme.Fonts.body.weight(.medium))
                    Text("localhost:\(String(s.port))" + (s.claudeCommand.map { " · \($0)" } ?? ""))
                        .font(Theme.Fonts.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let shell = s.claudeTask.map({ "task:\($0)" }) ?? s.screen.map({ "screen:\($0)" }), let showShell {
                    Button { showShell(shell) } label: { Image(systemName: "terminal") }
                        .buttonStyle(.borderless)
                        .tint(.accentColor)
                        .accessibilityLabel("Output")
                }
            }
        }
        .tint(.primary)
    }

    private func rows(_ list: [ListeningServer]) -> some View {
        ForEach(list) { s in
            Button { target = WebTarget(port: s.port) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "network").foregroundStyle(Color.accentColor).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("localhost:\(String(s.port))").font(Theme.Fonts.body.monospaced())
                        Text([s.command, s.screen.map { "screen \($0)" }, s.cwd].compactMap { $0 }.joined(separator: " · "))
                            .font(Theme.Fonts.caption).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if let name = s.screen, s.project == project, let showShell {
                        Button { showShell("screen:\(name)") } label: { Image(systemName: "terminal") }
                            .buttonStyle(.borderless)
                            .tint(.accentColor)
                            .accessibilityLabel("Output")
                    }
                }
            }
            .tint(.primary)
        }
    }

    private func load() async {
        if let project { await ws.loadPublished(project) }
        do { servers = try await ws.api.previewServers(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - Environment

private struct OpenWebPreviewKey: EnvironmentKey {
    static let defaultValue: ((WebTarget) -> Void)? = nil
}

private struct ExpandDetailKey: EnvironmentKey {
    static let defaultValue: Binding<Bool>? = nil
}

extension EnvironmentValues {
    /// Inside a chat, localhost links open in its Preview tab instead of over everything.
    var openWebPreview: ((WebTarget) -> Void)? {
        get { self[OpenWebPreviewKey.self] }
        set { self[OpenWebPreviewKey.self] = newValue }
    }

    /// Hides the sidebars so the detail (a chat, a preview, a file) fills the screen.
    var expandDetail: Binding<Bool>? {
        get { self[ExpandDetailKey.self] }
        set { self[ExpandDetailKey.self] = newValue }
    }
}

// MARK: - Buttons

/// Buttons Claude set up for the project, above the message box. A command
/// is shown before its first run (and again whenever it changes).
struct ActionBar: View {
    let ws: WorkspaceState
    let project: String
    let sessionId: String
    let ran: (ActionResult) -> Void

    @AppStorage("actions.confirmed") private var confirmedRaw = ""
    @State private var confirming: ActionButton?
    @State private var running: String?
    @State private var error: String?

    private var buttons: [ActionButton] { ws.actions[project] ?? [] }

    var body: some View {
        if !buttons.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(buttons) { a in
                        Button { tap(a) } label: {
                            Label(a.label, systemImage: running == a.label ? "hourglass" : a.symbol)
                                .font(Theme.Fonts.meta.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .help(a.description ?? a.command ?? a.prompt ?? a.url ?? "")
                        .contextMenu {
                            if let c = a.command { Text("$ \(c)") }
                            if let d = a.description { Text(d) }
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                Task { await ws.removeAction(a, project: project) }
                            }
                        }
                    }
                }
            }
            .confirmationDialog("Run “\(confirming?.label ?? "")”?", isPresented: Binding(
                get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
                Button("Run") {
                    if let a = confirming {
                        confirmedRaw += "\n" + a.fingerprint
                        Task { await run(a) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let a = confirming {
                    Text("In a new shell in \(project)\(a.cwd.map { "/\($0)" } ?? ""):\n\n$ \(a.command ?? "")")
                }
            }
            .alert("Couldn't run it", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func tap(_ a: ActionButton) {
        if a.kind == "run" && !confirmedRaw.split(separator: "\n").contains(Substring(a.fingerprint)) {
            confirming = a
        } else {
            Task { await run(a) }
        }
    }

    private func run(_ a: ActionButton) async {
        running = a.label
        defer { running = nil }
        do {
            ran(try await ws.api.runAction(project: project, a, sessionId: sessionId))
        } catch {
            self.error = error.localizedDescription
            await ws.loadActions(project)
        }
    }
}
