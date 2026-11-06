import Foundation

/// An idea change waiting to reach the computer: the idea as it should now
/// be, or its removal. Each is safe to send twice.
struct IdeaChange: Codable, Hashable {
    var project: String
    var ideaId: String
    var idea: Idea?             // nil: remove it
}

/// Ideas on their way into a chat's message box.
struct IdeaInsert: Hashable {
    var text: String
    var ids: [String]
}

/// What a workspace keeps on the device so it can be read while its computer
/// is out of reach: the chat list, the chats you opened most recently, plans,
/// ideas and any idea changes not yet sent.
private struct WorkspaceCache: Codable {
    var info: WorkspaceInfo?
    var sessions: [SessionRow]
    var transcripts: [String: [TranscriptItem]]
    var viewed: [String]
    var proposals: [String: Proposal]
    var ideas: [String: [Idea]]
    var outbox: [IdeaChange]
    var lastOnline: Date?
}

extension WorkspaceState {
    /// How many opened chats are kept for reading offline.
    private static let keptChats = 25

    private var cacheURL: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("offline", isDirectory: true).appendingPathComponent("\(id.uuidString).json")
    }

    func restoreCache() {
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(WorkspaceCache.self, from: data) else { return }
        info = c.info
        // Whether a chat is working or ready is only known live: until the computer answers, none are.
        sessions = c.sessions.map { var r = $0; r.status = "stored"; r.pendingPermissions = nil; return r }
        transcripts = c.transcripts
        viewed = c.viewed
        proposals = c.proposals
        ideas = c.ideas
        outbox = c.outbox
        lastOnline = c.lastOnline
    }

    /// Written a moment after things settle, not on every streamed line.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        guard let url = cacheURL else { return }
        let kept = viewed.filter { transcripts[$0] != nil }.prefix(Self.keptChats)
        let c = WorkspaceCache(info: info, sessions: sessions,
                               transcripts: Dictionary(uniqueKeysWithValues: kept.map { ($0, transcripts[$0] ?? []) }),
                               viewed: Array(kept), proposals: proposals, ideas: ideas, outbox: outbox,
                               lastOnline: lastOnline)
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Code and chats: unreadable while the device is locked, and not in backups.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        var u = url
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    func dropCache() {
        saveTask?.cancel()
        if let url = cacheURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: ideas

    func openIdeas(_ project: String) -> [Idea] {
        (ideas[project] ?? []).filter { !$0.isUsed }.sorted { $0.createdAt > $1.createdAt }
    }

    func usedIdeas(_ project: String) -> [Idea] {
        (ideas[project] ?? []).filter(\.isUsed).sorted { ($0.usedAt ?? 0) > ($1.usedAt ?? 0) }
    }

    /// Projects with ideas waiting, for the sidebar to list even without chats.
    var projectsWithIdeas: [String] { ideas.keys.filter { !openIdeas($0).isEmpty } }

    func isUnsent(_ ideaId: String) -> Bool { outbox.contains { $0.ideaId == ideaId } }

    @discardableResult
    func addIdea(_ text: String, project: String) -> Idea? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let idea = Idea(id: UUID().uuidString.lowercased(), text: t, createdAt: Date().timeIntervalSince1970)
        change(project, idea.id, idea)
        return idea
    }

    func editIdea(_ idea: Idea, text: String, project: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var i = idea
        i.text = t
        change(project, i.id, i)
    }

    /// They went into a chat (nil: back on the list).
    func markIdeas(_ ids: [String], usedIn sessionId: String?, project: String) {
        for id in ids {
            guard var i = ideas[project]?.first(where: { $0.id == id }) else { continue }
            i.usedIn = sessionId
            i.usedAt = sessionId == nil ? nil : Date().timeIntervalSince1970
            change(project, id, i)
        }
    }

    func deleteIdea(_ idea: Idea, project: String) {
        change(project, idea.id, nil)
    }

    private func change(_ project: String, _ ideaId: String, _ idea: Idea?) {
        var list = ideas[project] ?? []
        list.removeAll { $0.id == ideaId }
        if let idea { list.append(idea) }
        ideas[project] = list
        outbox.removeAll { $0.project == project && $0.ideaId == ideaId }    // only the latest matters
        outbox.append(IdeaChange(project: project, ideaId: ideaId, idea: idea))
        scheduleSave()
        Task { await flushOutbox() }
    }

    /// The computer's list with the changes it hasn't had yet laid over it.
    func withOutbox(_ list: [Idea], project: String) -> [Idea] {
        var out = list
        for c in outbox where c.project == project {
            out.removeAll { $0.id == c.ideaId }
            if let i = c.idea { out.append(i) }
        }
        return out
    }

    /// Sends what's waiting, oldest first; stops at the first that can't get through.
    func flushOutbox() async {
        guard !flushing, case .online = connection else { return }
        flushing = true
        defer { flushing = false }
        while let c = outbox.first {
            do {
                if let i = c.idea { try await api.putIdea(project: c.project, i) }
                else { try await api.deleteIdea(project: c.project, id: c.ideaId) }
            } catch APIError.http(let code, _) where (400..<500).contains(code) && code != 401 && code != 408 {
                // The computer won't take it (the project's gone): sending again won't help.
            } catch {
                return
            }
            if outbox.first == c { outbox.removeFirst() }
        }
        scheduleSave()
    }
}
