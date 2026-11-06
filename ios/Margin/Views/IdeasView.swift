import SwiftUI

/// A project's ideas: things to bring up with Claude later. Nothing goes
/// anywhere until you pick ideas and start a chat with them or put them in
/// one; they're marked used once that message is sent.
struct IdeasView: View {
    let ws: WorkspaceState
    let project: String
    /// Start a new chat with this text (the sheet opens; you can still edit it).
    var startChat: (IdeaInsert) -> Void
    var openChat: (String) -> Void

    @State private var text = ""
    @State private var selected: Set<String> = []
    @State private var editing: Idea?
    @State private var showUsed = false

    private var open: [Idea] { ws.openIdeas(project) }
    private var used: [Idea] { ws.usedIdeas(project) }
    private var online: Bool { if case .online = ws.connection { true } else { false } }

    /// This project's chats, newest first: where an idea can go.
    private var chats: [SessionRow] {
        Array(ws.sessions.filter { $0.project == project }
            .sorted { ($0.lastModified ?? 0) > ($1.lastModified ?? 0) }.prefix(8))
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .bottom, spacing: 10) {
                    WritingField(placeholder: "An idea for \(project)…", text: $text, minLines: 2, maxLines: 10)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 30))
                    }
                    .buttonStyle(.borderless)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Keep this idea")
                }
            } footer: {
                if !online {
                    Label("\(ws.machine) is offline. Ideas are kept here and reach it when it's back.",
                          systemImage: "wifi.slash")
                }
            }

            Section {
                if open.isEmpty {
                    Text("Nothing saved yet. Jot down what you'd like Claude to look at, and bring it into a chat when the time is right.")
                        .font(Theme.Fonts.meta).foregroundStyle(.secondary)
                }
                ForEach(open) { i in
                    row(i)
                        .swipeActions {
                            Button(role: .destructive) { ws.deleteIdea(i, project: project) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu { menu(for: [i]) }
                }
            } header: {
                if !open.isEmpty { Text("\(open.count) waiting") }
            }

            if !used.isEmpty {
                Section(isExpanded: $showUsed) {
                    ForEach(used) { i in
                        usedRow(i)
                            .swipeActions {
                                Button(role: .destructive) { ws.deleteIdea(i, project: project) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { ws.markIdeas([i.id], usedIn: nil, project: project) } label: {
                                    Label("Back on the list", systemImage: "arrow.uturn.backward")
                                }
                            }
                    }
                } header: {
                    Text("Used")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Ideas · \(project)")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !selected.isEmpty { selectionBar }
        }
        .onChange(of: open.map(\.id)) { _, ids in selected.formIntersection(ids) }
        .sheet(item: $editing) { i in EditIdeaSheet(idea: i) { ws.editIdea(i, text: $0, project: project) } }
    }

    private func row(_ i: Idea) -> some View {
        let on = selected.contains(i.id)
        return HStack(alignment: .top, spacing: 12) {
            Button {
                if on { selected.remove(i.id) } else { selected.insert(i.id) }
            } label: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(on ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(on ? "Selected" : "Select")
            VStack(alignment: .leading, spacing: 4) {
                Text(i.text).font(Theme.Fonts.body).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(i.created.formatted(.relative(presentation: .named)))
                    if ws.isUnsent(i.id) {
                        Image(systemName: "icloud.slash").accessibilityLabel("Not on \(ws.machine) yet")
                    }
                }
                .font(Theme.Fonts.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { editing = i }
        }
        .padding(.vertical, 4)
    }

    private func usedRow(_ i: Idea) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(i.text).font(Theme.Fonts.body).foregroundStyle(.secondary).lineLimit(3)
            if let sid = i.usedIn {
                Button {
                    openChat(sid)
                } label: {
                    Label(ws.session(sid)?.title ?? "A chat", systemImage: "bubble.left")
                        .font(Theme.Fonts.caption).lineLimit(1)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    /// Start a chat with these ideas, or put them in one of the project's chats.
    @ViewBuilder private func menu(for ideas: [Idea]) -> some View {
        Button { start(ideas) } label: { Label("Start a chat", systemImage: "plus.bubble") }
            .disabled(!online)
        Menu {
            ForEach(chats) { c in
                Button(c.title) { put(ideas, in: c.sessionId) }
            }
        } label: {
            Label("Add to a chat", systemImage: "text.bubble")
        }
        .disabled(chats.isEmpty)
        if ideas.count == 1, let i = ideas.first {
            Button { editing = i } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { ws.deleteIdea(i, project: project) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private var selectionBar: some View {
        let picked = open.filter { selected.contains($0.id) }
        return HStack(spacing: 12) {
            Text("\(picked.count) selected").font(Theme.Fonts.meta.weight(.semibold))
            Button("Clear") { selected = [] }.font(Theme.Fonts.meta)
            Spacer()
            Menu {
                ForEach(chats) { c in
                    Button(c.title) { put(picked, in: c.sessionId) }
                }
            } label: {
                Label("Add to a chat", systemImage: "text.bubble")
            }
            .disabled(chats.isEmpty)
            Button { start(picked) } label: { Label("Start a chat", systemImage: "plus.bubble") }
                .buttonStyle(.borderedProminent)
                .disabled(!online)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }

    private func add() {
        if ws.addIdea(text, project: project) != nil { text = "" }
    }

    private func combined(_ ideas: [Idea]) -> IdeaInsert {
        // Oldest first: the order you had them in.
        let ordered = ideas.sorted { $0.createdAt < $1.createdAt }
        return IdeaInsert(text: ordered.map(\.text).joined(separator: "\n\n"), ids: ordered.map(\.id))
    }

    private func start(_ ideas: [Idea]) {
        guard !ideas.isEmpty else { return }
        startChat(combined(ideas))
        selected = []
    }

    private func put(_ ideas: [Idea], in sessionId: String) {
        guard !ideas.isEmpty else { return }
        ws.composerInserts[sessionId] = combined(ideas)
        selected = []
        openChat(sessionId)
    }
}

private struct EditIdeaSheet: View {
    let idea: Idea
    var save: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                WritingField(placeholder: "The idea", text: $text, minLines: 5, maxLines: 20)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            .navigationTitle("Idea")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(text); dismiss() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { text = idea.text }
        }
    }
}
