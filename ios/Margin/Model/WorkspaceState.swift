import Foundation
import Observation
import SwiftUI
import CryptoKit

/// Live state for one workspace endpoint: sessions, transcripts, approvals,
/// and the event stream that keeps them current.
@MainActor
@Observable
final class WorkspaceState: Identifiable {
    enum Connection: Equatable { case connecting, online, offline(String) }

    var endpoint: Endpoint
    var info: WorkspaceInfo?
    var sessions: [SessionRow] = []
    var pending: [String: PermissionRequest] = [:]
    var transcripts: [String: [TranscriptItem]] = [:]
    var liveStatus: [String: String] = [:]
    var results: [String: SessionResult] = [:]
    var resultTimes: [String: Date] = [:]
    var proposals: [String: Proposal] = [:]
    /// Messages waiting for each session to finish its turn.
    var queued: [String: [QueuedMessage]] = [:]
    var settings: [String: SessionSettings] = [:]
    var published: [String: [PublishedPage]] = [:]      // by project
    var actions: [String: [ActionButton]] = [:]          // by project
    var shows: [String: [ShowItem]] = [:]               // by session: what Claude pointed at
    var replies: [String: [String]] = [:]                // by session: answers Claude offered
    var wakeups: [String: [Wakeup]] = [:]                // by session: when Claude will check back
    var activity: [String: Activity] = [:]               // by session, while Claude works
    @ObservationIgnored private var displayReported: [String: String] = [:]
    var connection: Connection = .connecting
    /// Ideas jotted down for each project, used and not.
    var ideas: [String: [Idea]] = [:]
    /// Idea changes not yet on the computer: made offline, sent when it's back.
    var outbox: [IdeaChange] = []
    /// Ideas picked from the Ideas page for a chat, to drop into its message box.
    var composerInserts: [String: IdeaInsert] = [:]
    /// The last time the computer answered; what an offline view is "as of".
    var lastOnline: Date?
    @ObservationIgnored var flushing = false
    @ObservationIgnored var saveTask: Task<Void, Never>?
    /// Chats loaded from the computer since launch (the rest come from the cache).
    @ObservationIgnored var fresh: Set<String> = []
    /// Chats most recently opened first: the ones worth keeping offline.
    @ObservationIgnored var viewed: [String] = []

    /// Unsent review notes, markups and attachments, per session.
    @ObservationIgnored private var drafts: [String: ReviewDraft] = [:]

    @ObservationIgnored private var lastSeq = 0
    @ObservationIgnored private var historySeq: [String: Int] = [:]
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var lastHeard = Date()
    @ObservationIgnored private var boot: String?

    let id: UUID
    var api: HostAPI { HostAPI(endpoint: endpoint) }

    /// The computer it's on ("Alex's MacBook Pro"), as the Mac names itself.
    var machine: String { info?.machine ?? info?.host ?? endpoint.name }
    var workspaceName: String { info?.workspace ?? endpoint.name }
    var color: Color { Color(hex: info?.color ?? endpoint.colorHex ?? "#4F7CFF") }
    var projects: [ProjectInfo] { info?.projects ?? [] }

    init(endpoint: Endpoint) {
        self.endpoint = endpoint
        self.id = endpoint.id
        restoreCache()
    }

    // MARK: lifecycle

    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in await self?.runStream() }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    func refresh() async {
        do {
            let info = try await self.api.info()
            self.info = info
            endpoint.slug = info.slug
            endpoint.colorHex = info.color
            if lastSeq > info.seq || (boot != nil && info.boot != boot) {
                // The daemon restarted and its event numbers started over.
                lastSeq = 0
                historySeq = [:]
            }
            boot = info.boot
            let api = self.api
            async let s = api.sessions()
            async let p = api.pending()
            async let pr = api.proposals()
            let (rows, perms) = try await (s, p)
            if let props = try? await pr {
                proposals = Dictionary(props.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
            sessions = rows
            pending = Dictionary(uniqueKeysWithValues: perms.map { ($0.requestId, $0) })
            for r in rows where r.isLive { liveStatus[r.sessionId] = r.status }
            if let i = try? await api.ideas() {
                ideas = Dictionary(uniqueKeysWithValues: i.map { ($0.key, withOutbox($0.value, project: $0.key)) })
            }
            connection = .online
            lastOnline = Date()
            scheduleSave()
            Task { await flushOutbox() }
        } catch {
            connection = .offline(error.localizedDescription)
        }
    }

    /// Debounced session-list refresh after events that change titles/order.
    private func scheduleListRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            if let rows = try? await self.api.sessions() { self.sessions = rows }
        }
    }

    /// The app came back to the foreground: a socket left open in the
    /// background is often dead without knowing it, so reconnect now.
    func wake() {
        socket?.cancel(with: .goingAway, reason: nil)
    }

    private func runStream() async {
        var backoff: Double = 1
        while !Task.isCancelled {
            await refresh()
            if case .offline = connection {
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 30)
                continue
            }
            // Anything missed while disconnected: reload the chats that are open.
            for sid in Array(fresh) { await loadHistory(sid, force: true) }
            let task: URLSessionWebSocketTask
            do { task = try api.eventsTask(since: lastSeq) } catch {
                connection = .offline(error.localizedDescription)
                try? await Task.sleep(for: .seconds(backoff))
                continue
            }
            socket = task
            task.resume()
            lastHeard = Date()
            // The daemon pings every 25s; a socket silent for much longer is dead
            // (Wi-Fi change, VPN, sleep) even though receive() never returns.
            let watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard let self else { return }
                    if Date().timeIntervalSince(self.lastHeard) > 60 {
                        task.cancel(with: .goingAway, reason: nil)
                        return
                    }
                }
            }
            do {
                while !Task.isCancelled {
                    let msg = try await task.receive()
                    lastHeard = Date()
                    backoff = 1
                    let data: Data
                    switch msg {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: continue
                    }
                    if let ev = try? JSONDecoder.snake.decode(ServerEvent.self, from: data) {
                        handle(ev)
                    }
                }
            } catch {
                connection = .connecting
            }
            watchdog.cancel()
            task.cancel(with: .goingAway, reason: nil)
            socket = nil
            if !Task.isCancelled {
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    // MARK: events

    private func handle(_ ev: ServerEvent) {
        if let s = ev.seq { lastSeq = max(lastSeq, s) }
        switch ev.type {
        case "ping":
            connection = .online
            lastOnline = Date()
        case "resync":
            Task { await refresh(); for sid in fresh { await loadHistory(sid, force: true) } }
        case "session.started":
            if let sid = ev.sessionId {
                liveStatus[sid] = "starting"
                if transcripts[sid] == nil { transcripts[sid] = [] }
                fresh.insert(sid)
                scheduleListRefresh()
            }
        case "session.status":
            if let sid = ev.sessionId, let st = ev.status {
                liveStatus[sid] = st
                if let i = sessions.firstIndex(where: { $0.sessionId == sid }) { sessions[i].status = st }
                if st == "closed" || st == "idle" { scheduleListRefresh() }
            }
        case "session.items":
            guard let sid = ev.sessionId, let items = ev.items else { return }
            if let hs = historySeq[sid], let s = ev.seq, s <= hs { return }
            transcripts[sid, default: []].append(contentsOf: items)
            scheduleSave()
        case "session.queue":
            if let sid = ev.sessionId { queued[sid] = ev.queued ?? [] }
        case "session.show":
            if let sid = ev.sessionId { shows[sid] = ev.shows ?? [] }
        case "session.activity":
            if let sid = ev.sessionId { activity[sid] = ev.activity }
        case "session.replies":
            if let sid = ev.sessionId { replies[sid] = ev.replies ?? [] }
        case "session.crons":
            if let sid = ev.sessionId { wakeups[sid] = ev.crons ?? [] }
        case "ideas":
            if let p = ev.project { ideas[p] = withOutbox(ev.ideas ?? [], project: p); scheduleSave() }
        case "actions":
            if let p = ev.project { actions[p] = ev.actions ?? [] }
        case "published":
            if let p = ev.project { published[p] = ev.pages ?? [] }
        case "session.settings":
            if let sid = ev.sessionId, let s = ev.settings { settings[sid] = s }
        case "permission.request":
            if let p = ev.permission { pending[p.requestId] = p }
        case "permission.resolved":
            if let r = ev.requestId { pending[r] = nil }
        case "session.result":
            if let r = ev.sessionResult {
                results[r.sessionId] = r
                resultTimes[r.sessionId] = Date()
            }
        case "proposal":
            if let p = ev.proposal {
                proposals[p.id] = p
                for (k, old) in proposals where old.sessionId == p.sessionId && old.version < p.version && old.isPending {
                    proposals[k]?.status = "superseded"
                }
                scheduleSave()
            }
        case "session.error":
            if let sid = ev.sessionId {
                transcripts[sid, default: []].append(
                    TranscriptItem(kind: "text", text: "⚠️ \(ev.message ?? "error")", error: true))
            }
        default:
            break
        }
    }

    // MARK: actions

    func loadHistory(_ sessionId: String, force: Bool = false) async {
        viewed.removeAll { $0 == sessionId }
        viewed.insert(sessionId, at: 0)
        // Sessions started from this app already stream every item; only fetch stored ones.
        if !force, fresh.contains(sessionId), transcripts[sessionId] != nil, liveStatus[sessionId] != nil { return }
        do {
            let h = try await api.history(sessionId)
            transcripts[sessionId] = h.items
            historySeq[sessionId] = h.seq
            queued[sessionId] = h.queued ?? []
            shows[sessionId] = h.shows ?? []
            replies[sessionId] = h.replies ?? []
            wakeups[sessionId] = h.crons ?? []
            activity[sessionId] = h.activity
            fresh.insert(sessionId)
            scheduleSave()
        } catch {
            connection = .offline(error.localizedDescription)
        }
    }

    func startSession(project: String, prompt: String, mode: PermissionMode) async throws -> String {
        let sid = try await api.start(project: project, prompt: prompt, mode: mode.rawValue)
        if transcripts[sid] == nil { transcripts[sid] = [] }
        fresh.insert(sid)
        liveStatus[sid] = liveStatus[sid] ?? "starting"
        scheduleListRefresh()
        return sid
    }

    func send(_ sessionId: String, text: String) async throws {
        if transcripts[sessionId] == nil { await loadHistory(sessionId) }
        historySeq[sessionId] = lastSeq   // anything newer streams in
        try await api.send(sessionId: sessionId, text: text)
    }

    func interrupt(_ sessionId: String) async {
        try? await api.interrupt(sessionId: sessionId)
    }

    /// The daemon's CA, checked against the fingerprint in /v1/info.
    @ObservationIgnored private var ca: SecCertificate?

    func previewCA() async -> SecCertificate? {
        if let ca { return ca }
        guard let want = info?.tls?.caSha256, let pem = try? await api.previewCA() else { return nil }
        let b64 = String(decoding: pem, as: UTF8.self).split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: b64),
              SHA256.hash(data: der).map({ String(format: "%02x", $0) }).joined() == want,
              let cert = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        ca = cert
        return cert
    }

    func dismissShow(_ sessionId: String, id: String) async {
        shows[sessionId]?.removeAll { $0.id == id }
        try? await api.dismissShow(sessionId: sessionId, id: id)
    }

    func loadActions(_ project: String) async {
        if let a = try? await api.actions(project: project) { actions[project] = a }
    }

    func removeAction(_ a: ActionButton, project: String) async {
        actions[project]?.removeAll { $0.label == a.label }
        try? await api.deleteAction(project: project, label: a.label)
    }

    func loadPublished(_ project: String) async {
        if let p = try? await api.published(project: project) { published[project] = p }
    }

    func unpublish(_ page: PublishedPage, project: String) async {
        published[project]?.removeAll { $0.id == page.id }
        try? await api.unpublish(project: project, id: page.id)
    }

    func loadSettings(_ sessionId: String) async {
        if let s = try? await api.settings(sessionId: sessionId) { settings[sessionId] = s }
    }

    func updateSettings(_ sessionId: String, mode: String? = nil, model: String? = nil, effort: String? = nil) async {
        if let s = try? await api.updateSettings(sessionId: sessionId, permissionMode: mode,
                                                 model: model, effort: effort) {
            settings[sessionId] = s
        } else {
            await loadSettings(sessionId)      // show what's really in effect
        }
    }

    func cancelQueued(_ sessionId: String, id: String) async {
        queued[sessionId]?.removeAll { $0.id == id }
        try? await api.cancelQueued(sessionId: sessionId, id: id)
    }

    /// Whether a file Claude referenced showed up; sent once per change.
    func reportDisplay(sessionId: String, path: String, ok: Bool, detail: String?) {
        let key = sessionId + "\u{1}" + path, value = "\(ok)\(detail ?? "")"
        guard displayReported[key] != value else { return }
        displayReported[key] = value
        Task { try? await api.reportDisplay(sessionId: sessionId, path: path, ok: ok, detail: detail) }
    }

    func decide(_ req: PermissionRequest, allow: Bool, always: Bool = false, message: String? = nil) async throws {
        try await api.decide(requestId: req.requestId, allow: allow, always: always, message: message)
        pending[req.requestId] = nil
    }

    func status(of sessionId: String) -> String {
        liveStatus[sessionId] ?? sessions.first(where: { $0.sessionId == sessionId })?.status ?? "stored"
    }

    func pending(for sessionId: String) -> [PermissionRequest] {
        pending.values.filter { $0.sessionId == sessionId }.sorted { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) }
    }

    func session(_ id: String) -> SessionRow? { sessions.first { $0.sessionId == id } }

    // MARK: proposals & review

    func proposals(for sessionId: String) -> [Proposal] {
        proposals.values.filter { $0.sessionId == sessionId }.sorted { $0.version < $1.version }
    }

    func latestProposal(for sessionId: String) -> Proposal? { proposals(for: sessionId).last }

    func draft(for sessionId: String) -> ReviewDraft {
        if let d = drafts[sessionId] { return d }
        let d = ReviewDraft()
        drafts[sessionId] = d
        return d
    }

    func decide(_ p: Proposal, approve: Bool, sections: [String]) async throws {
        let d = draft(for: p.sessionId)
        let feedback = try await d.compose(ws: self, sessionId: p.sessionId, sections: sections,
                                           heading: "Review of v\(p.version)")
        let updated = try await api.decideProposal(id: p.id, approve: approve, feedback: feedback)
        proposals[updated.id] = updated
        d.clear()
    }

    /// Send a chat message with any images attached in the composer.
    func sendWithAttachments(_ sessionId: String, text: String) async throws {
        let d = draft(for: sessionId)
        var body = text
        if !d.markups.isEmpty {
            body += try await d.composeImages(ws: self, sessionId: sessionId)
        }
        try await send(sessionId, text: body)
        d.markups.removeAll()
    }

    // MARK: files

    /// A path Claude mentioned (absolute, or relative to the session folder),
    /// as a file in one of this workspace's projects.
    /// A path Claude mentioned, found on the host: it may be relative to a
    /// folder the shell had moved into rather than the session's own.
    /// Falls back to reading it as written.
    func findFile(_ path: String, cwd: String?) async -> FileTarget? {
        if let r = try? await api.resolve(path: path, cwd: cwd) {
            let name = (r.path as NSString).lastPathComponent
            return FileTarget(project: r.project, entry: FileEntry(
                name: name, path: r.path, dir: false, size: nil, modified: nil, kind: FileEntry.kind(for: name)))
        }
        return fileTarget(path, cwd: cwd)
    }

    func fileTarget(_ path: String, cwd: String?) -> FileTarget? {
        let abs = path.hasPrefix("/") ? path : ((cwd ?? projects.first?.path ?? "") as NSString).appendingPathComponent(path)
        let norm = (abs as NSString).standardizingPath
        for p in projects {
            let root = p.path.hasSuffix("/") ? p.path : p.path + "/"
            if norm.hasPrefix(root) {
                let rel = String(norm.dropFirst(root.count))
                let name = (rel as NSString).lastPathComponent
                return FileTarget(project: p.name, entry: FileEntry(
                    name: name, path: rel, dir: false, size: nil, modified: nil, kind: FileEntry.kind(for: name)))
            }
        }
        return nil
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}
