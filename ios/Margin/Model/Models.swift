import UIKit
import Foundation

// MARK: - JSON helper

/// Arbitrary JSON (tool inputs vary by tool).
enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var pretty: String {
        guard let data = try? JSONEncoder.pretty.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

extension JSONDecoder {
    static let snake: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

// MARK: - API types (mirror docs/protocol.md)

struct ProjectInfo: Codable, Hashable, Identifiable {
    var name: String
    var path: String
    var id: String { name }
}

struct WorkspaceInfo: Codable, Hashable {
    var workspace: String
    var slug: String
    var color: String
    var host: String
    var machine: String?
    var version: String
    var projects: [ProjectInfo]
    var defaultPermissionMode: String
    var push: Bool
    var seq: Int
    var boot: String?
    var tls: TLSInfo?

    /// The daemon's own certificate authority for HTTPS previews.
    struct TLSInfo: Codable, Hashable {
        var caSha256: String
    }
}

struct SessionRow: Codable, Hashable, Identifiable {
    var sessionId: String
    var project: String?
    var title: String
    var firstPrompt: String?
    var gitBranch: String?
    var cwd: String?
    var lastModified: Double?
    var createdAt: Double?
    var status: String
    var pendingPermissions: Int?

    var id: String { sessionId }
    var date: Date? { lastModified.map { Date(timeIntervalSince1970: $0) } }
    var isLive: Bool { ["starting", "running", "waiting", "idle"].contains(status) }
}

struct TranscriptItem: Codable, Hashable, Identifiable {
    var kind: String            // user_text | text | thinking | tool_use | tool_result
    var text: String?
    var toolId: String?         // tool_use id ("id" on the wire)
    var name: String?           // tool name
    var input: JSONValue?
    var toolUseId: String?      // on tool_result: which tool_use it answers
    var isError: Bool?
    var parentToolUseId: String?
    var error: Bool?
    var media: [String]?        // host paths of images to show inline (fetched via /v1/media)
    var images: [InlineImage]?  // small images carried inline (tool-result screenshots)

    /// Local identity for SwiftUI lists (not sent by the server).
    var id = UUID()

    enum CodingKeys: String, CodingKey {
        case kind, text, toolId = "id", name, input, toolUseId, isError, parentToolUseId, error, media, images
    }
}

struct InlineImage: Codable, Hashable {
    var mediaType: String
    var data: String            // base64
}

struct PermissionRequest: Codable, Hashable, Identifiable {
    var requestId: String
    var sessionId: String
    var toolName: String
    var input: JSONValue?
    var title: String?
    var description: String?
    var createdAt: Double?
    var canAlwaysAllow: Bool?
    var id: String { requestId }

    /// One-line summary of what the tool wants to do.
    var summary: String {
        if let t = title, !t.isEmpty { return t }
        for k in ["command", "file_path", "filePath", "path", "url", "pattern", "description"] {
            if let v = input?[k]?.stringValue { return v }
        }
        return toolName
    }
}

struct SessionResult: Codable, Hashable {
    var sessionId: String
    var project: String?
    var isError: Bool
    var subtype: String?
    var numTurns: Int?
    var durationMs: Int?
    var costUsd: Double?
    var result: String?
}

struct FileEntry: Codable, Hashable, Identifiable {
    var name: String
    var path: String
    var dir: Bool
    var size: Int?
    var modified: Double?
    var kind: String
    var id: String { path }

    /// Same mapping as the daemon's files.kind_for, for paths the app builds itself.
    static func kind(for name: String) -> String {
        let ext = (name.lowercased() as NSString).pathExtension
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "image"
        case "svg": return "svg"
        case "pdf": return "pdf"
        case "stl", "obj", "usdz", "ply": return "model"
        case "step", "stp": return "cad"
        case "kicad_sch", "kicad_pcb": return "kicad"
        case "md", "markdown": return "markdown"
        case "csv": return "csv"
        default: return "text"
        }
    }
}

/// A server listening on the host (a dev server to preview).
/// A button Claude set up for a project, shown above the message box.
struct ActionButton: Codable, Hashable, Identifiable {
    var label: String
    var kind: String            // run | prompt | open
    var command: String?
    var cwd: String?
    var prompt: String?
    var url: String?
    var description: String?
    var icon: String?
    var fingerprint: String
    var id: String { label }

    var symbol: String {
        if let icon, !icon.isEmpty, UIImage(systemName: icon) != nil { return icon }
        switch kind {
        case "run": return "play.fill"
        case "prompt": return "text.bubble"
        default: return "globe"
        }
    }
}

/// Something you jotted down for a project, to bring into a chat later.
struct Idea: Codable, Hashable, Identifiable {
    var id: String
    var text: String
    var createdAt: Double
    var usedIn: String?         // the chat it went into
    var usedAt: Double?
    var created: Date { Date(timeIntervalSince1970: createdAt) }
    var isUsed: Bool { usedIn != nil }
}

struct ActionResult: Codable {
    var kind: String
    var terminal: ShellInfo?
    var url: String?
}

/// A page or service Claude published for a project (its Preview tab).
struct PublishedPage: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var kind: String
    var port: Int
    var path: String
    var description: String?
    var sessionId: String?
    var alive: Bool?
}

/// A command Claude Code is running in the background (Bash run_in_background).
struct BackgroundTask: Codable, Hashable, Identifiable {
    var id: String
    var command: String
    var description: String
    var status: String          // running, completed, failed, killed, stopped
    var summary: String?
    var startedAt: Double?
    var size: Int?
    var running: Bool { status == "running" }
}

struct TaskOutput: Codable {
    var start: Int
    var size: Int
    var text: String
    var reset: Bool
}

struct ListeningServer: Codable, Hashable, Identifiable {
    var port: Int
    var pid: Int
    var command: String
    var cwd: String?
    var project: String?
    var claudeSession: String?       // started by Claude in the background, in this chat
    var claudeCommand: String?
    var claudeTask: String?
    var claudeDescription: String?
    var id: Int { port }
}

/// The host's proxy for one of those, reachable from the iPad.
struct PreviewInfo: Codable {
    var targetPort: Int
    var listenPort: Int
    var authPath: String
    var scheme: String?
}

/// A message waiting to go to Claude when it finishes what it's doing.
/// A chat's permission mode, model and effort, and what can be chosen.
struct SessionSettings: Codable, Hashable {
    var permissionMode: String
    var model: String?
    var effort: String?
    var models: [ModelChoice]
    var modes: [String]

    struct ModelChoice: Codable, Hashable, Identifiable {
        var value: String
        var displayName: String?
        var description: String?
        var supportedEffortLevels: [String]?
        var id: String { value }
    }

    static func modeName(_ m: String) -> String {
        switch m {
        case "default": "Ask before acting"
        case "auto": "Auto"
        case "acceptEdits": "Accept edits"
        case "plan": "Plan first"
        case "bypassPermissions": "Bypass permissions"
        case "dontAsk": "Don't ask (deny)"
        default: m
        }
    }

    static func modeIcon(_ m: String) -> String {
        switch m {
        case "auto": "bolt.circle"
        case "acceptEdits": "pencil.circle"
        case "plan": "list.bullet.clipboard"
        case "bypassPermissions": "exclamationmark.shield"
        default: "hand.raised.circle"
        }
    }
}

struct QueuedMessage: Codable, Hashable, Identifiable {
    var id: String
    var text: String
}

/// Something Claude wants to put in front of you in a chat (its `show` tool).
struct ShowItem: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var note: String?
    var kind: String            // page | file | changes
    var port: Int?
    var path: String?
    var line: Int?
    var endLine: Int?

    var icon: String {
        switch kind {
        case "page": "globe"
        case "changes": "arrow.triangle.branch"
        default: line != nil ? "text.line.first.and.arrowtriangle.forward" : "doc.richtext"
        }
    }
}

/// What Claude is doing in the turn under way, like Claude Code's spinner line.
struct Activity: Codable, Hashable {
    var startedAt: Double
    var tokens: Int
    var doing: String
    var detail: String?
}

struct HistoryResponse: Codable {
    var sessionId: String
    var items: [TranscriptItem]
    var queued: [QueuedMessage]?
    var shows: [ShowItem]?
    var replies: [String]?
    var activity: Activity?
    var status: String
    var seq: Int
}

/// Every event on /v1/events. Fields are optional because each type uses a subset.
/// A plan Claude presented for review (one version of it).
struct Proposal: Codable, Hashable, Identifiable {
    var id: String
    var sessionId: String
    var project: String?
    var version: Int
    var plan: String
    var createdAt: Double
    var status: String          // pending | approved | revise | superseded | done
    var feedback: String?
    var decidedAt: Double?
    var outcome: String?
    var outcomeError: Bool?
    var title: String
    var commands: [String]?
    var live: Bool?

    var created: Date { Date(timeIntervalSince1970: createdAt) }
    var updated: Date { Date(timeIntervalSince1970: decidedAt ?? createdAt) }
    var isPending: Bool { status == "pending" }
}

struct ServerEvent: Decodable {
    var seq: Int?
    var type: String
    var ts: Double?
    var sessionId: String?
    var project: String?
    var status: String?
    var items: [TranscriptItem]?
    var message: String?
    // permission.request
    var requestId: String?
    var toolName: String?
    var input: JSONValue?
    var title: String?
    var description: String?
    var createdAt: Double?
    var canAlwaysAllow: Bool?
    // session.result
    var isError: Bool?
    var subtype: String?
    var numTurns: Int?
    var durationMs: Int?
    var costUsd: Double?
    var result: String?
    // proposal
    var proposal: Proposal?
    // session.queue
    var queued: [QueuedMessage]?
    // session.settings
    var settings: SessionSettings?
    // published
    var pages: [PublishedPage]?
    // actions
    var actions: [ActionButton]?
    // session.activity
    var activity: Activity?
    // ideas
    var ideas: [Idea]?
    // session.show, session.replies
    var shows: [ShowItem]?
    var replies: [String]?

    var permission: PermissionRequest? {
        guard type == "permission.request", let r = requestId, let s = sessionId, let t = toolName else { return nil }
        return PermissionRequest(requestId: r, sessionId: s, toolName: t, input: input, title: title,
                                 description: description, createdAt: createdAt, canAlwaysAllow: canAlwaysAllow)
    }

    var sessionResult: SessionResult? {
        guard type == "session.result", let s = sessionId else { return nil }
        return SessionResult(sessionId: s, project: project, isError: isError ?? false, subtype: subtype,
                             numTurns: numTurns, durationMs: durationMs, costUsd: costUsd, result: result)
    }
}

enum PermissionMode: String, CaseIterable, Identifiable {
    case `default`, acceptEdits, plan, auto, bypassPermissions
    var id: String { rawValue }
    var label: String {
        switch self {
        case .default: return "Ask before acting"
        case .acceptEdits: return "Auto-accept edits"
        case .plan: return "Propose a plan first"
        case .auto: return "Auto"
        case .bypassPermissions: return "Don't ask (careful)"
        }
    }
}

struct GitRefs: Codable {
    struct Commit: Codable, Hashable { var sha: String; var subject: String; var when: String }
    var branch: String
    var branches: [String]
    var commits: [Commit]
}

struct GitDiffResponse: Codable {
    var base: String
    var diff: String
    var truncated: Bool
}
