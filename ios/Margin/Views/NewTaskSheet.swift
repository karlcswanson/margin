import SwiftUI

/// Dispatch a new task to any workspace/project. Templates cover the things
/// you send often; the prompt is editable before sending.
struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var initialWorkspace: UUID?
    var initialProject: String? = nil
    /// Started from ideas: they fill the prompt and are marked used once it starts.
    var ideas: IdeaInsert? = nil
    var onStarted: (UUID, String) -> Void

    @State private var workspaceId: UUID?
    @State private var project = ""
    @State private var prompt = ""
    @State private var mode: PermissionMode = .plan
    @State private var sending = false
    @State private var error: String?

    private static let templates: [(String, String)] = [
        ("Propose", "Look into this and propose a plan I can review: \n\n"),
        ("Review KiCad", "Run ERC and DRC with kicad-cli on the current board, summarize the problems by severity, and export a fresh schematic PDF and board renders I can look at."),
        ("Fix & test", "Find out why this is failing, fix it, and run the tests: \n\n"),
        ("Status", "Summarize where this project stands: recent commits, open TODOs, anything half done, and what you'd do next."),
    ]

    private var ws: WorkspaceState? { model.workspace(workspaceId) }
    private var empty: Bool { prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var online: Bool { if case .online = ws?.connection { true } else { false } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Where") {
                    Picker("Workspace", selection: $workspaceId) {
                        ForEach(model.workspaces) { w in
                            HStack { Circle().fill(w.color).frame(width: 8, height: 8); Text(model.label(w)) }
                                .tag(Optional(w.id))
                        }
                    }
                    Picker("Project", selection: $project) {
                        ForEach(ws?.projects ?? []) { p in Text(p.name).tag(p.name) }
                    }
                    .disabled(ws?.projects.isEmpty ?? true)
                }
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Self.templates, id: \.0) { t in
                                Button(t.0) { prompt = t.1 }.buttonStyle(.bordered)
                            }
                        }
                    }
                    WritingField(placeholder: "What should the team do?", text: $prompt, minLines: 5, maxLines: 16)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                } header: { Text("Task") }
                Section("Permissions") {
                    Picker("Mode", selection: $mode) {
                        ForEach(PermissionMode.allCases) { m in Text(m.label).tag(m) }
                    }
                }
                if let ws, !online {
                    Label("\(ws.machine) is offline. Keep this as an idea and start it when it's back.",
                          systemImage: "wifi.slash")
                        .font(Theme.Fonts.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if ideas == nil {
                        Button(action: keep) { Image(systemName: "lightbulb") }
                            .disabled(ws == nil || project.isEmpty || empty)
                            .help("Keep as an idea for later")
                            .accessibilityLabel("Keep as an idea")
                    }
                    Button("Start", action: start)
                        .disabled(sending || ws == nil || project.isEmpty || empty || !online)
                }
            }
            .onAppear {
                workspaceId = initialWorkspace ?? model.workspaces.first?.id
                if let initialProject { project = initialProject }
                if let ideas { prompt = ideas.text }
                syncDefaults()
            }
            .onChange(of: workspaceId) { syncDefaults() }
        }
    }

    private func syncDefaults() {
        guard let ws else { return }
        if !ws.projects.contains(where: { $0.name == project }) { project = ws.projects.first?.name ?? "" }
        // New work starts as a proposal for review; the workspace default applies to replies.
    }

    private func keep() {
        guard let ws, ws.addIdea(prompt, project: project) != nil else { return }
        dismiss()
    }

    private func start() {
        guard let ws else { return }
        sending = true
        Task {
            do {
                let sid = try await ws.startSession(project: project, prompt: prompt, mode: mode)
                if let ideas { ws.markIdeas(ideas.ids, usedIn: sid, project: project) }
                onStarted(ws.id, sid)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}

struct AddWorkspaceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = "https://"
    @State private var token = ""
    @State private var link = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("margin://add?…", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add from link") {
                        if let u = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), model.handle(url: u) {
                            dismiss()
                        }
                    }
                    .disabled(!link.hasPrefix("margin://"))
                } header: { Text("Paste the link from `margind pair`") }

                Section("Or enter it yourself") {
                    TextField("Name (e.g. Personal)", text: $name)
                    TextField("https://mac.dev.example.com:8787", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Token", text: $token)
                }
            }
            .navigationTitle("Add workspace")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let u = URL(string: url) {
                            model.addEndpoint(name: name.isEmpty ? (u.host ?? "Workspace") : name, url: u, token: token)
                            dismiss()
                        }
                    }
                    .disabled(URL(string: url)?.host == nil || token.isEmpty)
                }
            }
        }
    }
}
