import Foundation
import Observation
import UIKit

/// Everything the app knows: one WorkspaceState per endpoint, merged on-device.
/// Nothing is merged on a server; each workspace's content stays on its host.
@MainActor
@Observable
final class AppModel {
    var workspaces: [WorkspaceState] = []

    /// What to call a workspace: its computer, plus the workspace's own name
    /// only when that computer runs more than one.
    func label(_ ws: WorkspaceState) -> String {
        let shared = workspaces.filter { $0.machine == ws.machine }.count > 1
        return shared ? "\(ws.machine) · \(ws.workspaceName)" : ws.machine
    }

    /// Badges tell workspaces apart; with only one there's nothing to tell.
    var showsBadges: Bool { workspaces.count > 1 }
    var apnsToken: String?
    /// Set when something outside the views (a notification tap) wants a screen opened.
    var openRequest: DetailRoute?

    func open(slug: String, proposalId: String?, sessionId: String?) {
        guard let ws = workspace(slug: slug) else { return }
        if let proposalId { openRequest = .proposal(workspace: ws.id, proposalId: proposalId) }
        else if let sessionId { openRequest = .session(workspace: ws.id, sessionId: sessionId) }
    }

    init() {
        workspaces = EndpointStore.load().map { WorkspaceState(endpoint: $0) }
    }

    func startAll() { workspaces.forEach { $0.start() } }

    func workspace(_ id: UUID?) -> WorkspaceState? { workspaces.first { $0.id == id } }
    func workspace(slug: String) -> WorkspaceState? { workspaces.first { $0.endpoint.slug == slug } }

    // MARK: endpoints

    @discardableResult
    func addEndpoint(name: String, url: URL, token: String) -> WorkspaceState {
        let ep = Endpoint(name: name, baseURL: url)
        ep.token = token
        let ws = WorkspaceState(endpoint: ep)
        workspaces.append(ws)
        persist()
        ws.start()
        Task {
            await ws.refresh()
            persist()                       // keep slug/color learned from /v1/info
            await registerPush(on: ws)
        }
        return ws
    }

    func remove(_ ws: WorkspaceState) {
        ws.stop()
        ws.dropCache()
        ws.endpoint.token = nil
        workspaces.removeAll { $0.id == ws.id }
        persist()
    }

    func persist() { EndpointStore.save(workspaces.map { $0.endpoint }) }

    /// margin://add?url=https://mac.dev.example.com:8787&token=…&name=Personal
    func handle(url: URL) -> Bool {
        guard url.scheme == "margin", url.host == "add",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "url" })?.value, let base = URL(string: raw),
              let token = items.first(where: { $0.name == "token" })?.value else { return false }
        let name = items.first(where: { $0.name == "name" })?.value ?? base.host ?? "Workspace"
        if workspaces.contains(where: { $0.endpoint.baseURL == base }) { return true }
        addEndpoint(name: name, url: base, token: token)
        return true
    }

    // MARK: inbox

    struct InboxApproval: Identifiable {
        let workspace: WorkspaceState
        let request: PermissionRequest
        var id: String { "\(workspace.id)-\(request.requestId)" }
    }

    struct InboxResult: Identifiable {
        let workspace: WorkspaceState
        let result: SessionResult
        let at: Date
        var id: String { "\(workspace.id)-\(result.sessionId)" }
    }

    var approvals: [InboxApproval] {
        workspaces.flatMap { ws in ws.pending.values.map { InboxApproval(workspace: ws, request: $0) } }
            .sorted { ($0.request.createdAt ?? 0) < ($1.request.createdAt ?? 0) }
    }

    var recentResults: [InboxResult] {
        workspaces.flatMap { ws in
            ws.results.values.map { InboxResult(workspace: ws, result: $0, at: ws.resultTimes[$0.sessionId] ?? .distantPast) }
        }
        .sorted { $0.at > $1.at }
    }

    var badgeCount: Int {
        workspaces.reduce(0) { $0 + $1.pending.count + $1.proposals.values.filter(\.isPending).count }
    }

    // MARK: folio

    struct FolioItem: Identifiable {
        let workspace: WorkspaceState
        let proposal: Proposal
        var id: String { "\(workspace.id)-\(proposal.id)" }
    }

    struct ActiveSession: Identifiable {
        let workspace: WorkspaceState
        let sessionId: String
        let status: String
        var id: String { "\(workspace.id)-\(sessionId)" }
    }

    /// The newest proposal of every session, across all workspaces.
    private var latestProposals: [FolioItem] {
        workspaces.flatMap { ws in
            Dictionary(grouping: ws.proposals.values, by: \.sessionId).values
                .compactMap { $0.max { $0.version < $1.version } }
                .map { FolioItem(workspace: ws, proposal: $0) }
        }
    }

    var decisions: [FolioItem] {
        latestProposals.filter { $0.proposal.isPending }.sorted { $0.proposal.createdAt > $1.proposal.createdAt }
    }

    /// Approved and being carried out, or sent back and being revised.
    var inProgress: [FolioItem] {
        latestProposals.filter { ["approved", "revise"].contains($0.proposal.status) }
            .sorted { $0.proposal.updated > $1.proposal.updated }
    }

    var decided: [FolioItem] {
        Array(latestProposals.filter { $0.proposal.status == "done" }
            .sorted { $0.proposal.updated > $1.proposal.updated }.prefix(40))
    }

    /// Sessions working right now that aren't tied to a proposal in the lists above.
    var activeSessions: [ActiveSession] {
        let tracked = Set(latestProposals.filter { $0.proposal.status != "done" }.map(\.proposal.sessionId))
        return workspaces.flatMap { ws in
            ws.liveStatus.filter { ["starting", "running", "waiting"].contains($0.value) && !tracked.contains($0.key) }
                .map { ActiveSession(workspace: ws, sessionId: $0.key, status: $0.value) }
        }
    }

    // MARK: push

    func didRegister(deviceToken: Data) {
        apnsToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { for ws in workspaces { await registerPush(on: ws) } }
    }

    func registerPush(on ws: WorkspaceState) async {
        guard let token = apnsToken else { return }
        #if DEBUG
        let env = "development"
        #else
        let env = "production"
        #endif
        try? await ws.api.registerDevice(token: token, name: UIDevice.current.name, environment: env)
    }

    /// Called from a notification action (Allow / Deny), possibly from the lock screen.
    func resolveFromNotification(slug: String, requestId: String, allow: Bool) async {
        guard let ws = workspace(slug: slug) else { return }
        try? await ws.api.decide(requestId: requestId, allow: allow)
        ws.pending[requestId] = nil
    }
}
