import SwiftUI

enum DetailRoute: Hashable {
    case folio
    case session(workspace: UUID, sessionId: String)
    case proposal(workspace: UUID, proposalId: String)
    case changes(workspace: UUID, project: String)
    case file(workspace: UUID, project: String, entry: FileEntry)
    case ideas(workspace: UUID, project: String)
}

/// A new chat started from ideas: where, what to say, which ideas it uses.
struct NewTaskSeed: Identifiable {
    let id = UUID()
    let workspace: UUID
    let project: String
    let ideas: IdeaInsert
}

/// One sidebar (slides in and out): the folio, then each workspace's chats
/// by project. A chat fills the rest of the screen, its project inside it.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var detail: DetailRoute? = .folio
    @State private var showAdd = false
    @State private var newTaskIn: UUID??
    @State private var seed: NewTaskSeed?
    // Simulator screenshots: SIMCTL_CHILD_MARGIN_SIDEBAR=hide starts with the sidebar out of the way.
    @State private var columns: NavigationSplitViewVisibility =
        ProcessInfo.processInfo.environment["MARGIN_SIDEBAR"] == "hide" ? .detailOnly : .all
    @State private var filter = ""
    @AppStorage("sidebar.collapsed") private var collapsedRaw = ""     // folded projects, "ws/project" per line
    @AppStorage("sidebar.order") private var orderRaw = ""             // projects moved by hand, "ws/project" per line, in order

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $detail) {
                Label("Folio", systemImage: "rectangle.stack")
                    .badge(model.badgeCount)
                    .tag(DetailRoute.folio)
                ForEach(model.workspaces) { ws in
                    Section {
                        if case .offline(let why) = ws.connection {
                            Label(why, systemImage: "wifi.exclamationmark").foregroundStyle(.red).font(Theme.Fonts.caption)
                        }
                        ForEach(groups(ws), id: \.0) { project, rows in
                            DisclosureGroup(isExpanded: expanded("\(ws.id)/\(project)")) {
                                let ideas = ws.openIdeas(project).count
                                if ideas > 0 {
                                    Label("Ideas", systemImage: "lightbulb")
                                        .badge(ideas)
                                        .tag(DetailRoute.ideas(workspace: ws.id, project: project))
                                }
                                ForEach(rows) { row in
                                    SessionRowView(ws: ws, row: row)
                                        .tag(DetailRoute.session(workspace: ws.id, sessionId: row.sessionId))
                                }
                            } label: {
                                Label(project, systemImage: "folder")
                                    .badge(rows.reduce(0) { $0 + ws.pending(for: $1.sessionId).count })
                                    .contextMenu {
                                        Button("Ideas", systemImage: "lightbulb") {
                                            detail = .ideas(workspace: ws.id, project: project)
                                        }
                                        let names = groups(ws).map(\.0)
                                        Button("Move Up", systemImage: "arrow.up") { move(project, in: ws, by: -1) }
                                            .disabled(names.first == project)
                                        Button("Move Down", systemImage: "arrow.down") { move(project, in: ws, by: 1) }
                                            .disabled(names.last == project)
                                    }
                            }
                        }
                    } header: {
                        WorkspaceHeader(ws: ws) { newTaskIn = .some(ws.id) }
                            .contextMenu { Button("Remove workspace", role: .destructive) { model.remove(ws) } }
                    }
                }
                Button { showAdd = true } label: { Label("Add workspace", systemImage: "plus") }
            }
            .searchable(text: $filter, placement: .sidebar, prompt: "Chats")
            .refreshable { for ws in model.workspaces { await ws.refresh() } }
            .navigationTitle("Margin")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { newTaskIn = .some(nil) } label: { Image(systemName: "square.and.pencil") }
                        .disabled(model.workspaces.isEmpty)
                        .keyboardShortcut("n")
                }
            }
        } detail: {
            switch detail {
            case .folio, .none:
                FolioView(detail: $detail)
            case .session(let wid, let sid):
                if let ws = model.workspace(wid) {
                    SessionView(ws: ws, sessionId: sid).id(sid)
                }
            case .proposal(let wid, let pid):
                if let ws = model.workspace(wid) {
                    ProposalView(ws: ws, proposalId: pid) { sid in
                        detail = .session(workspace: wid, sessionId: sid)
                    }
                    .id(pid)
                }
            case .changes(let wid, let project):
                if let ws = model.workspace(wid) {
                    CodeReviewView(ws: ws, project: project) { sid in
                        detail = .session(workspace: wid, sessionId: sid)
                    }
                    .id("\(wid)-\(project)")
                }
            case .file(let wid, let project, let entry):
                if let ws = model.workspace(wid) {
                    FilePreviewView(ws: ws, project: project, entry: entry).id(entry.path)
                }
            case .ideas(let wid, let project):
                if let ws = model.workspace(wid) {
                    IdeasView(ws: ws, project: project) { ideas in
                        seed = NewTaskSeed(workspace: wid, project: project, ideas: ideas)
                    } openChat: { sid in
                        detail = .session(workspace: wid, sessionId: sid)
                    }
                    .id("ideas-\(wid)-\(project)")
                }
            }
        }
        .background {
            // Keyboard: the folio, and the chat above or below in the sidebar.
            Group {
                Button("Folio") { detail = .folio }.keyboardShortcut("0")
                Button("Previous chat") { step(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Next chat") { step(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Show or hide the sidebar") {
                    withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .environment(\.expandDetail, Binding(
            get: { columns == .detailOnly },
            set: { columns = $0 ? .detailOnly : .all }))
        .onChange(of: model.openRequest) {
            guard let r = model.openRequest else { return }
            detail = r
            model.openRequest = nil
        }
        .sheet(isPresented: $showAdd) { AddWorkspaceSheet() }
        .sheet(isPresented: Binding(get: { newTaskIn != nil }, set: { if !$0 { newTaskIn = nil } })) {
            NewTaskSheet(initialWorkspace: newTaskIn ?? nil) { wsId, sid in
                detail = .session(workspace: wsId, sessionId: sid)
            }
        }
        .sheet(item: $seed) { s in
            NewTaskSheet(initialWorkspace: s.workspace, initialProject: s.project, ideas: s.ideas) { wsId, sid in
                detail = .session(workspace: wsId, sessionId: sid)
            }
        }
        .overlay {
            if model.workspaces.isEmpty {
                ContentUnavailableView {
                    Label("No workspaces yet", systemImage: "network")
                } description: {
                    Text("Run `margind pair` on a host and open the link here, or add one by hand.")
                } actions: {
                    Button("Add workspace") { showAdd = true }.buttonStyle(.borderedProminent)
                }
                .background(.background)        // covers the folio, not drawn over it
            }
        }
    }

    private func expanded(_ key: String) -> Binding<Bool> {
        Binding(get: { !collapsedRaw.split(separator: "\n").contains(Substring(key)) || !filter.isEmpty },
                set: { open in
                    var keys = Set(collapsedRaw.split(separator: "\n").map(String.init))
                    if open { keys.remove(key) } else { keys.insert(key) }
                    collapsedRaw = keys.sorted().joined(separator: "\n")
                })
    }

    /// Every chat in sidebar order.
    private var chatOrder: [DetailRoute] {
        model.workspaces.flatMap { ws in
            groups(ws).flatMap { $0.1.map { DetailRoute.session(workspace: ws.id, sessionId: $0.sessionId) } }
        }
    }

    private func step(_ by: Int) {
        let order = chatOrder
        guard !order.isEmpty else { return }
        let i = detail.flatMap { order.firstIndex(of: $0) }
        detail = order[i.map { min(max($0 + by, 0), order.count - 1) } ?? 0]
    }

    private func groups(_ ws: WorkspaceState) -> [(String, [SessionRow])] {
        let rows = ws.sessions.filter {
            filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter)
                || ($0.project ?? "").localizedCaseInsensitiveContains(filter)
        }
        var byProject = Dictionary(grouping: rows) { $0.project ?? "Other" }
        // A project with ideas waiting is listed even before it has a chat.
        if filter.isEmpty { for p in ws.projectsWithIdeas where byProject[p] == nil { byProject[p] = [] } }
        let order = projectOrder(ws)
        let rank = { (p: String) in order.firstIndex(of: p) ?? order.count }
        // Nothing moves on its own: projects keep their place, and chats are
        // newest first by when they were started, not by when they last changed.
        return byProject.map { project, rows in
            (project, rows.sorted { ($0.createdAt ?? $0.lastModified ?? 0) > ($1.createdAt ?? $1.lastModified ?? 0) })
        }
        .sorted { (rank($0.0), $0.0) < (rank($1.0), $1.0) }
    }

    /// The workspace's projects in the order they're listed in its config,
    /// with any moved by hand where they were put.
    private func projectOrder(_ ws: WorkspaceState) -> [String] {
        let prefix = "\(ws.id)/"
        let moved = orderRaw.split(separator: "\n").filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        return moved + ws.projects.map(\.name).filter { !moved.contains($0) }
    }

    private func move(_ project: String, in ws: WorkspaceState, by: Int) {
        var names = groups(ws).map(\.0)
        guard let i = names.firstIndex(of: project), names.indices.contains(i + by) else { return }
        names.swapAt(i, i + by)
        let prefix = "\(ws.id)/"
        let others = orderRaw.split(separator: "\n").filter { !$0.hasPrefix(prefix) }.map(String.init)
        withAnimation { orderRaw = (others + names.map { prefix + $0 }).joined(separator: "\n") }
    }
}

/// A workspace's heading in the sidebar: its colour, name, connection, and
/// a new chat in it.
struct WorkspaceHeader: View {
    let ws: WorkspaceState
    let newChat: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(ws.color).frame(width: 9, height: 9)
            Text(model.label(ws))
            if case .online = ws.connection {} else {
                Text(subtitle).font(Theme.Fonts.small).foregroundStyle(.secondary).textCase(nil)
            }
            Spacer()
            Button(action: newChat) { Image(systemName: "plus.bubble") }
                .buttonStyle(.borderless)
                .accessibilityLabel("New chat on \(model.label(ws))")
        }
    }

    private var subtitle: String {
        switch ws.connection {
        case .connecting: "connecting…"
        case .online: ""
        case .offline: "offline"
        }
    }
}

/// Small colored tag naming the workspace, used everywhere content from several
/// workspaces is shown together.
struct WorkspaceBadge: View {
    let ws: WorkspaceState
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.showsBadges {
            Text(model.label(ws))
                .font(Theme.Fonts.small.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(ws.color.opacity(0.18), in: Capsule())
                .foregroundStyle(ws.color)
        }
    }
}

struct StatusDot: View {
    let status: String
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .accessibilityLabel(Self.words(status) ?? "Not running")
    }

    /// The status as you'd say it; nil for a chat that isn't running (nothing to say).
    static func words(_ status: String) -> String? {
        switch status {
        case "starting": "Starting"
        case "running": "Working"
        case "waiting": "Needs you"
        case "idle": "Ready"
        case "active_elsewhere": "Open at desk"
        case "error": "Error"
        default: nil
        }
    }
    private var color: Color {
        switch status {
        case "running", "starting": return .blue
        case "waiting": return Theme.needsYou
        case "idle": return .green
        case "active_elsewhere": return .purple
        case "error": return .red
        default: return .gray.opacity(0.4)
        }
    }
}
