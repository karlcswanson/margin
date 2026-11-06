import SwiftUI

/// The home screen: everything across your businesses that needs you, what
/// the team is working on, and what's been decided and delivered.
struct FolioView: View {
    @Environment(AppModel.self) private var model
    @Binding var detail: DetailRoute?

    @State private var width: CGFloat = 0

    var body: some View {
        List {
            Section {
                if model.decisions.isEmpty && model.approvals.isEmpty {
                    Text("Nothing waiting on you.").foregroundStyle(.secondary)
                }
                ForEach(model.decisions) { item in
                    proposalRow(item)
                }
                ForEach(model.approvals) { a in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            WorkspaceBadge(ws: a.workspace)
                            Text(a.workspace.session(a.request.sessionId)?.title ?? "Session")
                                .font(Theme.Fonts.meta).lineLimit(1)
                            Spacer()
                            Button { detail = .session(workspace: a.workspace.id, sessionId: a.request.sessionId) } label: {
                                Image(systemName: "arrow.right.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        ApprovalCard(ws: a.workspace, request: a.request)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                header("Needs your decision", count: model.decisions.count + model.approvals.count)
            }

            Section {
                if model.inProgress.isEmpty && model.activeSessions.isEmpty {
                    Text("No one's working on anything right now.").foregroundStyle(.secondary)
                }
                ForEach(model.inProgress) { item in proposalRow(item) }
                ForEach(model.activeSessions) { s in
                    Button { detail = .session(workspace: s.workspace.id, sessionId: s.sessionId) } label: {
                        HStack(spacing: 10) {
                            StatusDot(status: s.status)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.workspace.session(s.sessionId)?.title ?? "New task").lineLimit(2)
                                HStack(spacing: 6) {
                                    WorkspaceBadge(ws: s.workspace)
                                    if let p = s.workspace.session(s.sessionId)?.project {
                                        Text(p).font(Theme.Fonts.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                header("Team is working", count: model.inProgress.count + model.activeSessions.count)
            }

            Section {
                if model.decided.isEmpty {
                    Text("Approved work shows up here when it's delivered.").foregroundStyle(.secondary)
                }
                ForEach(model.decided) { item in proposalRow(item) }
            } header: {
                header("Delivered", count: model.decided.count)
            }
        }
        .listStyle(.insetGrouped)
        // A column like the chat's, not the whole width of a wide iPad.
        .contentMargins(.horizontal, max(0, (width - Theme.chatWidth - 120) / 2), for: .scrollContent)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle("Folio")
        .refreshable { for ws in model.workspaces { await ws.refresh() } }
        // Pencil double-tap allows the oldest waiting request, then the next.
        .onPencilDoubleTap(enabled: !model.approvals.isEmpty) {
            guard let a = model.approvals.first else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Task { try? await a.workspace.decide(a.request, allow: true) }
        }
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            if count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
        }
    }

    private func proposalRow(_ item: AppModel.FolioItem) -> some View {
        let p = item.proposal
        return Button { detail = .proposal(workspace: item.workspace.id, proposalId: p.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    WorkspaceBadge(ws: item.workspace)
                    if let proj = p.project { Text(proj).font(Theme.Fonts.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(p.updated, style: .relative).font(Theme.Fonts.caption).foregroundStyle(.secondary)
                }
                Text(MarkdownBlocks.title(p.title))
                    .font(.system(.headline, design: .serif))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    StatusPill(status: p.status)
                    if p.version > 1 { Text("v\(p.version)").font(Theme.Fonts.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    if p.status == "done", let o = p.outcome?.split(separator: "\n").first {
                        Text(MarkdownBlocks.title(String(o))).font(Theme.Fonts.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
