import Foundation

enum APIError: LocalizedError {
    case noToken
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noToken: return "No token saved for this workspace."
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        }
    }
}

/// Thin REST + WebSocket client for one margind endpoint.
struct HostAPI {
    let endpoint: Endpoint

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private func request(_ path: String, query: [String: String] = [:], method: String = "GET",
                         body: Encodable? = nil) throws -> URLRequest {
        guard let token = endpoint.token else { throw APIError.noToken }
        var comps = URLComponents(url: endpoint.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        return req
    }

    private func fetch(_ req: URLRequest) async throws -> (Data, HTTPURLResponse?) {
        let (data, resp) = try await Self.session.data(for: req)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError.http(code, String(decoding: data, as: UTF8.self))
        }
        return (data, http)
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await Self.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError.http(code, String(decoding: data, as: UTF8.self))
        }
        return data
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await send(try request(path, query: query))
        return try JSONDecoder.snake.decode(T.self, from: data)
    }

    @discardableResult
    func post(_ path: String, _ body: Encodable) async throws -> Data {
        try await send(try request(path, method: "POST", body: body))
    }

    // MARK: endpoints

    func info() async throws -> WorkspaceInfo { try await get("v1/info") }

    func sessions(limit: Int = 100) async throws -> [SessionRow] {
        try await get("v1/sessions", query: ["limit": String(limit)])
    }

    func history(_ sessionId: String) async throws -> HistoryResponse {
        try await get("v1/sessions/\(sessionId)/messages")
    }

    func pending() async throws -> [PermissionRequest] { try await get("v1/permissions") }

    func start(project: String, prompt: String, mode: String?) async throws -> String {
        struct Body: Encodable { let project: String; let prompt: String; let permission_mode: String? }
        struct Resp: Decodable { let sessionId: String }
        let data = try await post("v1/sessions", Body(project: project, prompt: prompt, permission_mode: mode))
        return try JSONDecoder.snake.decode(Resp.self, from: data).sessionId
    }

    func send(sessionId: String, text: String) async throws {
        struct Body: Encodable { let text: String }
        try await post("v1/sessions/\(sessionId)/messages", Body(text: text))
    }

    func interrupt(sessionId: String) async throws {
        struct Empty: Encodable {}
        try await post("v1/sessions/\(sessionId)/interrupt", Empty())
    }

    func decide(requestId: String, allow: Bool, always: Bool = false, message: String? = nil) async throws {
        struct Body: Encodable { let decision: String; let always: Bool; let message: String? }
        try await post("v1/permissions/\(requestId)",
                       Body(decision: allow ? "allow" : "deny", always: always, message: message))
    }

    func files(project: String, path: String) async throws -> [FileEntry] {
        try await get("v1/files", query: ["project": project, "path": path])
    }

    func fileData(project: String, path: String) async throws -> Data {
        try await send(try request("v1/file", query: ["project": project, "path": path]))
    }

    /// A file plus its modification time on the host (for safe saving).
    func fileForEditing(project: String, path: String) async throws -> (Data, Double?) {
        let (data, resp) = try await fetch(try request("v1/file", query: ["project": project, "path": path]))
        return (data, (resp?.value(forHTTPHeaderField: "X-Modified")).flatMap(Double.init))
    }

    /// Save a file; `baseModified` nil creates or overwrites. Throws HTTP 409 on a conflict.
    func saveFile(project: String, path: String, data: Data, baseModified: Double?,
                  createOnly: Bool = false) async throws -> Double {
        struct Resp: Decodable { let modified: Double }
        var q = ["project": project, "path": path]
        if let baseModified { q["base_modified"] = String(baseModified) }
        if createOnly { q["create_only"] = "true" }
        var req = try request("v1/file", query: q, method: "PUT")
        req.httpBody = data
        return try JSONDecoder.snake.decode(Resp.self, from: try await send(req)).modified
    }

    /// Ask Claude to revise a passage; returns the replacement text.
    func assist(project: String, path: String?, passage: String, instruction: String, context: String) async throws -> String {
        struct Body: Encodable { let project: String; let path: String?; let passage: String; let instruction: String; let context: String }
        struct Resp: Decodable { let text: String }
        var req = try request("v1/assist", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Body(project: project, path: path, passage: passage,
                                                     instruction: instruction, context: context))
        req.timeoutInterval = 200
        return try JSONDecoder.snake.decode(Resp.self, from: try await send(req)).text
    }

    func gitRefs(project: String) async throws -> GitRefs {
        try await get("v1/git/refs", query: ["project": project])
    }

    func gitDiff(project: String, base: String, path: String? = nil) async throws -> GitDiffResponse {
        var q = ["project": project]
        if !base.isEmpty { q["base"] = base }
        if let path { q["path"] = path }
        return try await get("v1/git/diff", query: q)
    }

    /// A project file as it was at `ref` (default: the last commit).
    func gitFile(project: String, path: String, ref: String = "HEAD") async throws -> Data {
        try await send(try request("v1/git/file", query: ["project": project, "path": path, "ref": ref]))
    }

    /// An image Claude wrote or mentioned, by host path (relative paths resolve against `cwd`).
    func media(path: String, cwd: String?) async throws -> Data {
        var q = ["path": path]
        if let cwd { q["cwd"] = cwd }
        return try await send(try request("v1/media", query: q))
    }

    /// A KiCad file rendered on the host: schematic → PDF, board → SVG ("2d") or PNG ("3d").
    func render(path: String, cwd: String?, view: String, ref: String? = nil) async throws -> Data {
        var q = ["path": path, "view": view]
        if let cwd { q["cwd"] = cwd }
        if let ref { q["ref"] = ref }
        var req = try request("v1/render", query: q)
        req.timeoutInterval = 240          // a 3D render or a big STEP conversion takes a while
        return try await send(req)
    }

    func previewServers() async throws -> [ListeningServer] {
        try await get("v1/previews/servers")
    }

    func openPreview(port: Int) async throws -> PreviewInfo {
        struct Body: Encodable { let port: Int }
        return try JSONDecoder.snake.decode(PreviewInfo.self, from: try await post("v1/previews", Body(port: port)))
    }

    func settings(sessionId: String) async throws -> SessionSettings {
        try await get("v1/sessions/\(sessionId)/settings")
    }

    /// Only the fields given change; "" puts model or effort back to the default.
    func updateSettings(sessionId: String, permissionMode: String? = nil, model: String? = nil,
                        effort: String? = nil) async throws -> SessionSettings {
        struct Body: Encodable { let permission_mode: String?; let model: String?; let effort: String? }
        let data = try await send(try request("v1/sessions/\(sessionId)/settings", method: "PATCH",
                                              body: Body(permission_mode: permissionMode, model: model, effort: effort)))
        return try JSONDecoder.snake.decode(SessionSettings.self, from: data)
    }

    func dismissShow(sessionId: String, id: String) async throws {
        _ = try await send(try request("v1/sessions/\(sessionId)/show", query: ["id": id], method: "DELETE"))
    }

    func actions(project: String) async throws -> [ActionButton] {
        try await get("v1/actions", query: ["project": project])
    }

    func runAction(project: String, _ a: ActionButton, sessionId: String) async throws -> ActionResult {
        struct Body: Encodable { let project: String; let label: String; let fingerprint: String; let session_id: String }
        return try JSONDecoder.snake.decode(ActionResult.self, from: try await post(
            "v1/actions/run", Body(project: project, label: a.label, fingerprint: a.fingerprint, session_id: sessionId)))
    }

    func deleteAction(project: String, label: String) async throws {
        _ = try await send(try request("v1/actions", query: ["project": project, "label": label], method: "DELETE"))
    }

    /// Every project's ideas, by project.
    func ideas() async throws -> [String: [Idea]] { try await get("v1/ideas") }

    func putIdea(project: String, _ i: Idea) async throws {
        struct Body: Encodable { let text: String; let created_at: Double; let used_in: String?; let used_at: Double? }
        _ = try await send(try request("v1/ideas/\(i.id)", query: ["project": project], method: "PUT",
                                       body: Body(text: i.text, created_at: i.createdAt, used_in: i.usedIn, used_at: i.usedAt)))
    }

    func deleteIdea(project: String, id: String) async throws {
        _ = try await send(try request("v1/ideas/\(id)", query: ["project": project], method: "DELETE"))
    }

    func terminals(project: String) async throws -> [ShellInfo] {
        try await get("v1/terminals", query: ["project": project])
    }

    func openTerminal(project: String, sessionId: String?, name: String?) async throws -> ShellInfo {
        struct Body: Encodable { let project: String; let session_id: String?; let name: String? }
        return try JSONDecoder.snake.decode(ShellInfo.self,
                                            from: try await post("v1/terminals", Body(project: project, session_id: sessionId, name: name)))
    }

    func closeTerminal(id: String) async throws {
        _ = try await send(try request("v1/terminals/\(id)", method: "DELETE"))
    }

    struct Resolved: Decodable { let project: String; let path: String }

    /// Where a path Claude mentioned really is (it may be relative to a folder the shell moved into).
    func resolve(path: String, cwd: String?) async throws -> Resolved {
        var q = ["path": path]
        if let cwd { q["cwd"] = cwd }
        return try await get("v1/resolve", query: q)
    }

    func backgroundTasks(sessionId: String) async throws -> [BackgroundTask] {
        try await get("v1/sessions/\(sessionId)/tasks")
    }

    /// Stop one of Claude's background commands through Claude Code; the chat carries on.
    func stopTask(sessionId: String, taskId: String) async throws {
        _ = try await send(try request("v1/sessions/\(sessionId)/tasks/\(taskId)/stop", method: "POST"))
    }

    func taskOutput(sessionId: String, taskId: String, since: Int?) async throws -> TaskOutput {
        try await get("v1/sessions/\(sessionId)/tasks/\(taskId)/output",
                      query: since.map { ["since": String($0)] } ?? [:])
    }

    func published(project: String) async throws -> [PublishedPage] {
        try await get("v1/published", query: ["project": project])
    }

    func unpublish(project: String, id: String) async throws {
        _ = try await send(try request("v1/published", query: ["project": project, "id": id], method: "DELETE"))
    }

    /// The daemon's CA certificate (PEM), to trust its HTTPS previews.
    func previewCA() async throws -> Data {
        try await send(try request("v1/tls/ca.pem"))
    }

    /// Where Safari installs the CA as a profile.
    var caProfileURL: URL { endpoint.baseURL.appendingPathComponent("v1/tls/margin.mobileconfig") }

    func cancelQueued(sessionId: String, id: String) async throws {
        _ = try await send(try request("v1/sessions/\(sessionId)/queue/\(id)", method: "DELETE"))
    }

    func reportDisplay(sessionId: String, path: String, ok: Bool, detail: String?) async throws {
        struct Item: Encodable { let path: String; let ok: Bool; let detail: String? }
        struct Body: Encodable { let items: [Item] }
        try await post("v1/sessions/\(sessionId)/display", Body(items: [Item(path: path, ok: ok, detail: detail)]))
    }

    func proposals() async throws -> [Proposal] {
        try await get("v1/proposals")
    }

    func decideProposal(id: String, approve: Bool, feedback: String?) async throws -> Proposal {
        struct Body: Encodable { let decision: String; let feedback: String? }
        var req = try request("v1/proposals/\(id)", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Body(decision: approve ? "approve" : "revise", feedback: feedback))
        return try JSONDecoder.snake.decode(Proposal.self, from: try await send(req))
    }

    /// Upload a marked-up or pasted image into the session's project; returns its relative path.
    func uploadMarkup(sessionId: String, png: Data) async throws -> String {
        struct Resp: Decodable { let path: String }
        var req = try request("v1/sessions/\(sessionId)/markup", method: "POST")
        req.setValue("image/png", forHTTPHeaderField: "Content-Type")
        req.httpBody = png
        return try JSONDecoder.snake.decode(Resp.self, from: try await send(req)).path
    }

    /// A markup made outside a session (a code review), stored in the project.
    func uploadMarkup(project: String, png: Data) async throws -> String {
        struct Resp: Decodable { let path: String }
        var req = try request("v1/markup", query: ["project": project], method: "POST")
        req.setValue("image/png", forHTTPHeaderField: "Content-Type")
        req.httpBody = png
        return try JSONDecoder.snake.decode(Resp.self, from: try await send(req)).path
    }

    func registerDevice(token: String, name: String, environment: String) async throws {
        struct Body: Encodable { let token: String; let name: String; let environment: String }
        try await post("v1/devices", Body(token: token, name: name, environment: environment))
    }

    func eventsTask(since: Int) throws -> URLSessionWebSocketTask {
        var req = try request("v1/events", query: ["since": String(since)])
        var comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        req.url = comps.url
        return Self.session.webSocketTask(with: req)
    }
}

/// Lets `request(body:)` take any Encodable.
private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
