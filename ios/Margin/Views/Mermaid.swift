import SwiftUI
import WebKit

/// Mermaid diagrams (```mermaid) drawn on the iPad with the bundled
/// mermaid.js, then shown like an inline SVG mockup: full screen on tap,
/// markable with the Pencil.
struct MermaidView: View {
    let source: String
    @State private var svg: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let svg {
                InlineSVG(source: svg)
            } else if let error {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Couldn't draw this diagram: \(error)", systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.caption).foregroundStyle(.secondary)
                    CodeBlock(code: source, language: "mermaid", collapsedLines: 20)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: source) {
            do { svg = try await Mermaid.shared.render(source) }
            catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor
final class Mermaid: NSObject, WKNavigationDelegate {
    static let shared = Mermaid()

    private var web: WKWebView?
    private var loaded: [CheckedContinuation<Void, Never>] = []
    private var isLoaded = false
    private var cache: [String: String] = [:]
    private var counter = 0

    func render(_ source: String) async throws -> String {
        if let hit = cache[source] { return hit }
        let web = try await ready()
        counter += 1
        let result = try await web.callAsyncJavaScript(
            "const r = await mermaid.render(id, src); return r.svg;",
            arguments: ["id": "margin-mermaid-\(counter)", "src": source], contentWorld: .page)
        guard let svg = result as? String, svg.contains("<svg") else {
            throw NSError(domain: "Margin", code: 3, userInfo: [NSLocalizedDescriptionKey: "no drawing came back"])
        }
        cache[source] = svg
        return svg
    }

    private func ready() async throws -> WKWebView {
        if let web, isLoaded { return web }
        if web == nil {
            guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
                  let js = try? String(contentsOf: url, encoding: .utf8) else {
                throw NSError(domain: "Margin", code: 4, userInfo: [NSLocalizedDescriptionKey: "mermaid.js is missing"])
            }
            let cfg = WKWebViewConfiguration()
            cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            // Plain SVG text (no HTML labels) so the drawing renders as an image and its words can be read.
            cfg.userContentController.addUserScript(WKUserScript(source: """
                mermaid.initialize({startOnLoad: false, securityLevel: "strict", theme: "default",
                  htmlLabels: false, flowchart: {htmlLabels: false}});
                """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            let v = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 900), configuration: cfg)
            v.navigationDelegate = self
            v.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
            web = v
        }
        if !isLoaded { await withCheckedContinuation { loaded.append($0) } }
        return web!
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            isLoaded = true
            loaded.forEach { $0.resume() }
            loaded = []
        }
    }
}
