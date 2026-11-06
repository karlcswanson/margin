import SwiftTerm
import SwiftUI
import UIKit

/// Colours and type for every terminal: a palette that follows light and
/// dark mode, and one text size (⌘+ / ⌘−) shared by all of them.
@MainActor
enum TerminalLook {
    static var fontSize: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: "terminal.fontSize") as? Double ?? 14) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "terminal.fontSize") }
    }

    static func font() -> UIFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }

    static func apply(to v: TerminalView) {
        let dark = v.traitCollection.userInterfaceStyle != .light
        v.nativeBackgroundColor = dark ? hex(0x1E2127) : hex(0xFAFAFA)
        v.nativeForegroundColor = dark ? hex(0xDCDFE4) : hex(0x383A42)
        v.caretColor = dark ? hex(0x61AFEF) : hex(0x4078F2)
        v.installColors((dark ? darkANSI : lightANSI).map(term))
        v.superview?.backgroundColor = v.nativeBackgroundColor
    }

    /// Reapply when the iPad switches between light and dark.
    static func follow(_ v: TerminalView) {
        apply(to: v)
        v.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TerminalView, _: UITraitCollection) in
            TerminalLook.apply(to: view)
        }
    }

    static func resize(by delta: CGFloat) {
        fontSize = min(28, max(9, fontSize + delta))
        for v in ShellLink.all.values.map(\.view) + TaskLink.all.values.map(\.view) { v.font = font() }
    }

    private static let darkANSI: [UInt32] = [0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xDCDFE4,
                                             0x5C6370, 0xFF7A85, 0xB5E890, 0xFFD68A, 0x7CC4FF, 0xDE8EF0, 0x6ED4E0, 0xFFFFFF]
    private static let lightANSI: [UInt32] = [0x383A42, 0xE45649, 0x50A14F, 0xC18401, 0x4078F2, 0xA626A4, 0x0184BC, 0x9A9BA1,
                                              0x696C77, 0xCA1243, 0x3E953A, 0x986801, 0x2F5FD0, 0x8A1F8A, 0x0B7A9E, 0x4F525D]

    private static func hex(_ c: UInt32) -> UIColor {
        UIColor(red: CGFloat((c >> 16) & 0xFF) / 255, green: CGFloat((c >> 8) & 0xFF) / 255, blue: CGFloat(c & 0xFF) / 255, alpha: 1)
    }

    private static func term(_ c: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16((c >> 16) & 0xFF) * 257, green: UInt16((c >> 8) & 0xFF) * 257, blue: UInt16(c & 0xFF) * 257)
    }
}

/// A shell on the host, as the daemon reports it. Ones left from before a
/// daemon restart (still running in screen) have no id until reattached.
struct ShellInfo: Codable, Hashable, Identifiable {
    var id: String?
    var project: String
    var cwd: String?
    var name: String
    var screen: Bool?
    var alive: Bool?
    var title: String?
    var detached: Bool?
    var key: String { id ?? name }
}

/// One shell's terminal and its connection, kept while the app runs so
/// switching tabs doesn't redraw it. Drops reconnect from the last byte seen.
@MainActor
final class ShellLink: NSObject, TerminalViewDelegate {
    let info: ShellInfo
    let ws: WorkspaceState
    let view: TerminalView
    private(set) var connected = false
    private(set) var ended = false
    var onChange: (() -> Void)?

    private var task: URLSessionWebSocketTask?
    private var offset: Int?
    private var retry = 0
    private var cols = 0, rows = 0

    /// Live shells by id, for every chat.
    static var all: [String: ShellLink] = [:]

    static func link(_ info: ShellInfo, ws: WorkspaceState) -> ShellLink? {
        guard let id = info.id else { return nil }
        if let l = all[id] { return l }
        let l = ShellLink(info: info, ws: ws)
        all[id] = l
        return l
    }

    private init(info: ShellInfo, ws: WorkspaceState) {
        self.info = info
        self.ws = ws
        view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), font: TerminalLook.font())
        super.init()
        TerminalLook.follow(view)
        view.terminalDelegate = self
        view.optionAsMetaKey = true
        connect()
    }

    func connect() {
        guard !ended, let id = info.id else { return }
        task?.cancel(with: .goingAway, reason: nil)
        var comps = URLComponents(url: ws.api.endpoint.baseURL.appendingPathComponent("v1/terminals/\(id)/stream"),
                                  resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        if let offset { comps.queryItems = [URLQueryItem(name: "since", value: String(offset))] }
        var req = URLRequest(url: comps.url!)
        if let token = ws.api.endpoint.token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let t = URLSession.shared.webSocketTask(with: req)
        task = t
        t.resume()
        receive(t)
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .success(let msg):
                    self.handle(msg)
                    self.receive(t)
                case .failure:
                    self.dropped()
                }
            }
        }
    }

    private func handle(_ msg: URLSessionWebSocketTask.Message) {
        switch msg {
        case .data(let d):
            view.feed(byteArray: ArraySlice(d))
            offset = (offset ?? 0) + d.count
        case .string(let s):
            guard let m = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return }
            if m["type"] as? String == "start" {
                if m["reset"] as? Bool == true { view.getTerminal().resetToInitialState() }
                offset = m["offset"] as? Int
                connected = true
                retry = 0
                if cols > 0 { sendResize() }
                onChange?()
            } else if m["type"] as? String == "exit" {
                ended = true
                connected = false
                view.feed(text: "\r\n[shell ended]\r\n")
                onChange?()
            }
        @unknown default: break
        }
    }

    private func dropped() {
        connected = false
        onChange?()
        guard !ended else { return }
        retry += 1
        let delay = min(10.0, 0.5 * pow(2, Double(min(retry, 5))))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if !self.ended, !self.connected { self.connect() }
        }
    }

    private func sendResize() {
        let m = ["type": "resize", "cols": cols, "rows": rows] as [String: Any]
        if let d = try? JSONSerialization.data(withJSONObject: m) {
            task?.send(.string(String(decoding: d, as: UTF8.self))) { _ in }
        }
    }

    func type(_ text: String) {
        task?.send(.data(Data(text.utf8))) { _ in }
    }

    // MARK: TerminalViewDelegate

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let d = Data(data)
        Task { @MainActor in self.task?.send(.data(d)) { _ in } }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in
            self.cols = newCols
            self.rows = newRows
            self.sendResize()
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let u = URL(string: link) { Task { @MainActor in UIApplication.shared.open(u) } }
    }
    nonisolated func bell(source: TerminalView) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { Task { @MainActor in UIPasteboard.general.string = s } }
    }
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private struct TerminalHost: UIViewRepresentable {
    let link: ShellLink

    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.backgroundColor = link.view.nativeBackgroundColor
        attach(to: box)
        return box
    }

    func updateUIView(_ box: UIView, context: Context) {
        if link.view.superview !== box { attach(to: box) }
    }

    private func attach(to box: UIView) {
        link.view.removeFromSuperview()
        link.view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(link.view)
        NSLayoutConstraint.activate([
            link.view.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            link.view.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            link.view.topAnchor.constraint(equalTo: box.topAnchor),
            link.view.bottomAnchor.constraint(equalTo: box.keyboardLayoutGuide.topAnchor),
        ])
        DispatchQueue.main.async { _ = link.view.becomeFirstResponder() }
    }
}

/// One of Claude's background commands, read-only: its output file as it
/// grows, in a terminal so colours and progress bars show as they would.
@MainActor
final class TaskLink {
    let sessionId: String
    let taskId: String
    let ws: WorkspaceState
    let view: TerminalView
    private var offset: Int?
    private var polling: Task<Void, Never>?

    static var all: [String: TaskLink] = [:]

    static func link(sessionId: String, taskId: String, ws: WorkspaceState) -> TaskLink {
        if let l = all[taskId] { return l }
        let l = TaskLink(sessionId: sessionId, taskId: taskId, ws: ws)
        all[taskId] = l
        return l
    }

    private init(sessionId: String, taskId: String, ws: WorkspaceState) {
        self.sessionId = sessionId
        self.taskId = taskId
        self.ws = ws
        view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), font: TerminalLook.font())
        TerminalLook.follow(view)
    }

    /// Follow the output while it's on screen (once more after it ends).
    func follow(running: @escaping () -> Bool) {
        polling?.cancel()
        polling = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.fetch()
                if !running() { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() { polling?.cancel() }

    private func fetch() async {
        guard let o = try? await ws.api.taskOutput(sessionId: sessionId, taskId: taskId, since: offset) else { return }
        if o.reset { view.getTerminal().resetToInitialState() }
        if !o.text.isEmpty {
            // A file, not a terminal: lines end in \n alone.
            view.feed(text: o.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n"))
        }
        offset = o.size
    }
}

private struct TaskHost: UIViewRepresentable {
    let link: TaskLink

    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.backgroundColor = link.view.nativeBackgroundColor
        attach(to: box)
        return box
    }

    func updateUIView(_ box: UIView, context: Context) {
        if link.view.superview !== box { attach(to: box) }
    }

    private func attach(to box: UIView) {
        link.view.removeFromSuperview()
        link.view.frame = box.bounds
        link.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        box.addSubview(link.view)
    }
}

/// A chat's shells: tabs for each, a new one in the chat's folder, and
/// screen sessions left from before a daemon restart to pick up again.
struct ChatShellView: View {
    let ws: WorkspaceState
    let project: String
    let sessionId: String

    @State private var shells: [ShellInfo] = []
    @State private var tasks: [BackgroundTask] = []
    @Binding var selected: String?          // a shell id, or "task:<id>" for one of Claude's
    @State private var error: String?
    @State private var loaded = false
    @State private var tick = 0          // redraw on connection changes

    private var live: [ShellInfo] { shells.filter { $0.id != nil } }
    private var detached: [ShellInfo] { shells.filter { $0.id == nil } }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Divider()
            if let t = selectedTask {
                taskPane(t)
            } else if let s = live.first(where: { $0.id == selected }), let link = ShellLink.link(s, ws: ws) {
                let _ = tick                 // read so a change to the link redraws the badge
                TerminalHost(link: link)
                    .id(s.id)
                    .overlay(alignment: .topTrailing) {
                        if !link.connected && !link.ended {
                            Label("Reconnecting…", systemImage: "antenna.radiowaves.left.and.right")
                                .font(Theme.Fonts.caption).padding(8).background(.thinMaterial, in: Capsule()).padding(8)
                        }
                    }
                    // It may have connected before this view was listening.
                    .onAppear { link.onChange = { tick += 1 }; tick += 1 }
            } else {
                emptyState
            }
        }
        .background {
            Group {
                Button("Larger text") { TerminalLook.resize(by: 1) }.keyboardShortcut("+", modifiers: .command)
                Button("Larger text") { TerminalLook.resize(by: 1) }.keyboardShortcut("=", modifiers: .command)
                Button("Smaller text") { TerminalLook.resize(by: -1) }.keyboardShortcut("-", modifiers: .command)
            }
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .task { await load() }
        .task {
            // Claude's background commands come and go; keep the list fresh while this is on screen.
            while !Task.isCancelled {
                await loadTasks()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .task(id: selected) {
            // a button just started one: fetch it
            if let selected, !selected.hasPrefix("task:"), !live.contains(where: { $0.id == selected }) { await load() }
        }
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(live, id: \.key) { s in
                    let on = s.id == selected
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                        Text(label(s)).lineLimit(1)
                        if on {
                            Button { Task { await close(s) } } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel("End this shell")
                        }
                    }
                    .font(Theme.Fonts.meta)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(on ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { selected = s.id }
                }
                ForEach(tasks) { t in
                    let on = selected == "task:\(t.id)"
                    HStack(spacing: 6) {
                        Image(systemName: "sparkle").foregroundStyle(Color.accentColor)
                        Text(t.description.isEmpty ? t.command : t.description).lineLimit(1).frame(maxWidth: 220)
                        Circle().fill(color(t)).frame(width: 7, height: 7)
                    }
                    .font(Theme.Fonts.meta)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(on ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { selected = "task:\(t.id)" }
                    .help("Claude: \(t.command)")
                }
                Button { Task { await open(name: nil) } } label: { Label("New shell", systemImage: "plus") }
                    .font(Theme.Fonts.meta).padding(.horizontal, 6)
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                if !detached.isEmpty {
                    Menu {
                        ForEach(detached, id: \.key) { s in
                            Button("Reattach \(s.name)") { Task { await open(name: s.name) } }
                        }
                    } label: {
                        Label("\(detached.count) kept", systemImage: "rectangle.stack")
                    }
                    .font(Theme.Fonts.meta)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(.bar)
    }

    @ViewBuilder private var emptyState: some View {
        if let error {
            ContentUnavailableView("Can't open a shell", systemImage: "terminal", description: Text(error))
        } else if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No shell open", systemImage: "terminal")
            } description: {
                Text("A shell on the host in \(project). It keeps running when you leave"
                     + (detached.isEmpty ? "." : "; shells kept from before are in the bar above."))
            } actions: {
                Button("Open a shell") { Task { await open(name: nil) } }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var selectedTask: BackgroundTask? {
        guard let selected, selected.hasPrefix("task:") else { return nil }
        return tasks.first { "task:\($0.id)" == selected }
    }

    private func color(_ t: BackgroundTask) -> SwiftUI.Color {
        switch t.status {
        case "running": SwiftUI.Color.green
        case "completed": SwiftUI.Color.secondary
        default: SwiftUI.Color.orange
        }
    }

    private func taskPane(_ t: BackgroundTask) -> some View {
        let link = TaskLink.link(sessionId: sessionId, taskId: t.id, ws: ws)
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("$ \(t.command)").font(Theme.Fonts.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                Spacer()
                Text(t.running ? "Claude is running this" : (t.summary?.isEmpty == false ? t.summary! : t.status))
                    .font(Theme.Fonts.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            TaskHost(link: link)
                .id(t.id)
                .onAppear { link.follow { [weak ws] in ws != nil && (tasks.first { $0.id == t.id }?.running ?? false) } }
                .onDisappear { link.stop() }
        }
    }

    private func loadTasks() async {
        guard let list = try? await ws.api.backgroundTasks(sessionId: sessionId) else { return }
        // Running ones, and ones that ended in the last hour.
        let recent = Date().timeIntervalSince1970 - 3600
        tasks = list.filter { $0.running || ($0.startedAt ?? 0) > recent }
        if selected == nil, let first = tasks.first(where: \.running) { selected = "task:\(first.id)" }
    }

    private func label(_ s: ShellInfo) -> String {
        let n = s.name.split(separator: "-").last.map(String.init) ?? s.name
        return "\(project) \(n)"
    }

    private func load() async {
        do {
            shells = try await ws.api.terminals(project: project)
            if selected == nil || !(selected!.hasPrefix("task:") || live.contains(where: { $0.id == selected })) {
                selected = live.first?.id
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func open(name: String?) async {
        do {
            let s = try await ws.api.openTerminal(project: project, sessionId: sessionId, name: name)
            await load()
            selected = s.id
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func close(_ s: ShellInfo) async {
        if let id = s.id {
            ShellLink.all[id]?.disconnect()
            ShellLink.all[id] = nil
            try? await ws.api.closeTerminal(id: id)
        }
        await load()
    }
}
