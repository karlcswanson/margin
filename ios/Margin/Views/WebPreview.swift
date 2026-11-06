import SwiftUI
import WebKit

/// A page served on the host's localhost (a dev server Claude started),
/// opened through the daemon's preview proxy.
struct WebTarget: Identifiable, Hashable {
    let port: Int
    var path: String = "/"
    var id: String { "\(port)\(path)" }

    /// localhost / 127.0.0.1 links: they mean the host, not this iPad.
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(host) else { return nil }
        port = url.port ?? (scheme == "https" ? 443 : 80)
        var p = url.path.isEmpty ? "/" : url.path
        if let q = url.query { p += "?" + q }
        if let f = url.fragment { p += "#" + f }
        path = p
    }

    init(port: Int, path: String = "/") {
        self.port = port
        self.path = path
    }
}

/// Lets toolbar buttons reach the web view (back, reload, snapshot).
@MainActor
final class WebHandle {
    weak var view: WKWebView?

    func snapshot() async -> UIImage? {
        guard let view else { return nil }
        return try? await view.takeSnapshot(configuration: nil)
    }
}

/// Try a web app on the iPad and mark it up right on the live page: the
/// Pencil draws into the page (marks scroll with it), fingers keep using it.
/// Each mark knows the element it circled; send them with a picture.
struct WebPreviewView: View {
    let ws: WorkspaceState
    let target: WebTarget
    /// Shown inside a chat's Preview tab rather than over everything.
    var embedded = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.reviewSessionId) private var reviewSessionId
    @State private var url: URL?
    @State private var error: String?
    @State private var handle = WebHandle()
    @State private var state = WebState()
    @State private var width: CGFloat? = nil
    @State private var markupImage: UIImage?
    @State private var showMarks = false
    @State private var sentToast = false
    @State private var ca: SecCertificate?
    @Environment(\.openURL) private var openURL

    var body: some View {
        if embedded {
            page
        } else {
            NavigationStack { page }
        }
    }

    private var page: some View {
            VStack(spacing: 0) {
                if let url {
                    GeometryReader { geo in
                        WebView(url: url, handle: handle, state: state, ca: ca)
                            .frame(width: min(width ?? geo.size.width, geo.size.width))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(width == nil ? Color.clear : Color(uiColor: .systemGray5))
                } else if let error {
                    ContentUnavailableView("Can't open the preview", systemImage: "globe",
                                           description: Text(error))
                } else {
                    ProgressView("Connecting to localhost:\(target.port)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(state.title.isEmpty ? "localhost:\(target.port)" : state.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { handle.view?.goBack() } label: { Image(systemName: "chevron.backward") }
                        .keyboardShortcut("[", modifiers: .command)
                        .disabled(!state.canGoBack)
                    Button { handle.view?.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .keyboardShortcut("r", modifiers: .command)
                    Menu {
                        Picker("Width", selection: $width) {
                            Text("Full width").tag(CGFloat?.none)
                            Text("Tablet · 820").tag(CGFloat?.some(820))
                            Text("Phone · 390").tag(CGFloat?.some(390))
                        }
                        if ws.info?.tls != nil {
                            Section(state.secure == true ? "Secure context" : "Not a secure context") {
                                Button { openURL(ws.api.caProfileURL) } label: {
                                    Label("Install HTTPS certificate on this iPad…", systemImage: "lock.shield")
                                }
                            }
                        }
                    } label: { Image(systemName: width == 390 ? "iphone" : width == 820 ? "ipad" : "rectangle") }
                    if reviewSessionId != nil {
                        Menu {
                            Button { Task { await markUp() } } label: {
                                Label("Draw on a snapshot", systemImage: "camera.viewfinder")
                            }
                        } label: {
                            Label("Snapshot", systemImage: "camera.viewfinder")
                        } primaryAction: { Task { await markUp() } }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    if let secure = state.secure {
                        Image(systemName: secure ? "lock.fill" : "lock.open")
                            .font(Theme.Fonts.caption).foregroundStyle(secure ? Color.green : Color.secondary)
                            .help(secure ? "Secure context: HTTPS-only web APIs work" : "Not a secure context")
                    }
                    Text("localhost:\(String(target.port))\(state.path)")
                        .font(Theme.Fonts.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if state.marks.isEmpty {
                        Label("Draw on the page with the Pencil", systemImage: "pencil.tip")
                            .font(Theme.Fonts.caption).foregroundStyle(.secondary)
                    } else {
                        Button { handle.view?.evaluateJavaScript("window.__marginInk && __marginInk.undo()") } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .accessibilityLabel("Undo mark")
                        Button { showMarks = true } label: {
                            Label("\(state.marks.count) mark\(state.marks.count == 1 ? "" : "s")", systemImage: "pencil.tip.crop.circle")
                                .font(Theme.Fonts.meta.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
            }
            .overlay(alignment: .top) {
                if sentToast {
                    Label("Marks added to your reply", systemImage: "checkmark.circle.fill")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule()).padding(.top, 8)
                        .task { try? await Task.sleep(for: .seconds(2.5)); sentToast = false }
                }
            }
            .sheet(isPresented: $showMarks) {
                MarksSheet(state: state, canSend: reviewSessionId != nil,
                           clear: { handle.view?.evaluateJavaScript("window.__marginInk && __marginInk.clear()") },
                           send: { overall in Task { await sendMarks(overall) } })
            }
            .sheet(isPresented: Binding(get: { markupImage != nil }, set: { if !$0 { markupImage = nil } })) {
                if let img = markupImage, let sid = reviewSessionId {
                    MarkupSheet(pages: [img], source: "web page localhost:\(target.port)\(state.path)") {
                        ws.draft(for: sid).markups.append($0)
                    }
                }
            }
            .task { await connect() }
    }

    private func markUp() async {
        if let img = await handle.snapshot() { markupImage = img }
    }

    /// The page as you see it (ink included) plus what each mark points at,
    /// so Claude knows the exact elements, not just a picture.
    private func sendMarks(_ overall: String) async {
        guard let sid = reviewSessionId, let img = await handle.snapshot() else { return }
        var source = "web page localhost:\(target.port)\(state.path), live markup. Marks:"
        for m in state.marks {
            source += "\n   \(m.n). <\(m.tag)> `\(m.selector)`"
            if !m.text.isEmpty { source += " “\(m.text)”" }
            if let href = m.href { source += " (links to \(href))" }
            if m.path != state.path { source += " on \(m.path)" }
            let note = m.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty { source += ": \(note)" }
        }
        ws.draft(for: sid).markups.append(Markup(image: img, note: overall, source: source))
        sentToast = true
    }

    private func connect() async {
        do {
            let p = try await ws.api.openPreview(port: target.port)
            if p.scheme == "https" { ca = await ws.previewCA() }
            let host = ws.endpoint.baseURL.host ?? "localhost"
            // The auth path sets the cookie, then lands on the page Claude linked.
            let next = target.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "/"
            let auth = p.authPath.replacingOccurrences(of: "next=/", with: "next=" + next)
            url = URL(string: "\(p.scheme ?? "http")://\(host.contains(":") ? "[\(host)]" : host):\(p.listenPort)\(auth)")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@Observable
final class WebState {
    var title = ""
    var path = "/"
    var canGoBack = false
    var marks: [WebMark] = []
    var secure: Bool?           // window.isSecureContext, as the page reports it
}

/// One Pencil mark on a live page and the element under it.
struct WebMark: Identifiable {
    let n: Int
    let selector: String
    let tag: String
    let text: String
    let href: String?
    let path: String
    var note = ""
    var id: Int { n }
}

/// The marks on the page, each with a note, then into your reply.
private struct MarksSheet: View {
    @Bindable var state: WebState
    let canSend: Bool
    let clear: () -> Void
    let send: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var overall = ""

    var body: some View {
        NavigationStack {
            Form {
                ForEach($state.marks) { $m in
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(m.text.isEmpty ? "<\(m.tag)>" : "“\(m.text)”").font(Theme.Fonts.body).lineLimit(2)
                            Text(m.selector).font(Theme.Fonts.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        WritingField(placeholder: "What should change here?", text: $m.note, maxLines: 5, voiceSize: 28)
                    } header: { Text("Mark \(m.n)") }
                }
                Section("Overall") {
                    WritingField(placeholder: "Anything else about this page", text: $overall, maxLines: 5)
                }
            }
            .navigationTitle("Marks on this page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear", role: .destructive) { clear(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to reply") { send(overall); dismiss() }.disabled(!canSend)
                }
            }
        }
    }
}

private struct WebView: UIViewRepresentable {
    let url: URL
    let handle: WebHandle
    let state: WebState
    let ca: SecCertificate?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()       // each preview starts clean
        if let js = Bundle.main.url(forResource: "ink", withExtension: "js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) {
            config.userContentController.addUserScript(
                WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            config.userContentController.add(InkMessages(state: state), name: "marginInk")
        }
        let v = WKWebView(frame: .zero, configuration: config)
        v.navigationDelegate = context.coordinator
        v.allowsBackForwardNavigationGestures = true
        v.isInspectable = true
        handle.view = v
        v.load(URLRequest(url: url))
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) { handle.view = v }

    func makeCoordinator() -> Coordinator { Coordinator(state: state, ca: ca) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let state: WebState
        let ca: SecCertificate?
        init(state: WebState, ca: SecCertificate?) {
            self.state = state
            self.ca = ca
        }

        /// HTTPS previews are signed by the daemon's own CA: trust it here,
        /// for this web view only (installing the profile trusts it everywhere).
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust, let ca else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, false)
            if SecTrustEvaluateWithError(trust, nil) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        /// A new page has no ink on it.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            state.marks = []
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.title = webView.title ?? ""
            state.path = webView.url.map { u in u.path + (u.query.map { "?" + $0 } ?? "") } ?? "/"
            state.canGoBack = webView.canGoBack
        }

        /// Links off the preview (docs, other sites) open in Safari.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if let u = action.request.url, action.targetFrame?.isMainFrame != false,
               u.host != webView.url?.host || u.port != webView.url?.port, webView.url != nil,
               ["http", "https"].contains(u.scheme ?? "") {
                UIApplication.shared.open(u)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

/// What's serving on the host right now, to open in the browser. Servers
/// started in one of the workspace's projects come first.
struct PreviewServersList: View {
    let ws: WorkspaceState
    let open: (WebTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var servers: [ListeningServer]?
    @State private var error: String?
    @State private var port = ""

    var body: some View {
        NavigationStack {
            List {
                if let servers {
                    if servers.isEmpty {
                        Text("Nothing is serving on the host. Ask Claude to start the dev server.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(servers) { s in
                        Button { pick(WebTarget(port: s.port)) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("localhost:\(String(s.port))").font(Theme.Fonts.body.monospaced())
                                Text([s.command, s.project ?? s.cwd].compactMap { $0 }.joined(separator: " · "))
                                    .font(Theme.Fonts.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
                Section("Another port") {
                    HStack {
                        TextField("5173", text: $port).keyboardType(.numberPad)
                        Button("Open") { if let p = Int(port) { pick(WebTarget(port: p)) } }
                            .disabled(Int(port) == nil)
                    }
                }
            }
            .navigationTitle("Web preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task { await load() }
        }
    }

    private func pick(_ t: WebTarget) {
        dismiss()
        open(t)
    }

    private func load() async {
        do { servers = try await ws.api.previewServers(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

/// Marks reported by ink.js. (A separate object: the content controller keeps it alive.)
private final class InkMessages: NSObject, WKScriptMessageHandler {
    let state: WebState
    init(state: WebState) { self.state = state }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "mark":
            state.marks.append(WebMark(n: m["n"] as? Int ?? state.marks.count + 1,
                                       selector: m["selector"] as? String ?? "",
                                       tag: m["tag"] as? String ?? "",
                                       text: m["text"] as? String ?? "",
                                       href: m["href"] as? String,
                                       path: m["path"] as? String ?? "/"))
        case "context": state.secure = m["secure"] as? Bool
        case "undo": if !state.marks.isEmpty { state.marks.removeLast() }
        case "clear": state.marks = []
        default: break
        }
    }
}
