import Observation
import PDFKit
import PencilKit
import SceneKit
import SwiftUI
import WebKit

// MARK: - Review draft

/// A marked-up (or pasted) image waiting to be sent, with your note.
struct Markup: Identifiable {
    let id = UUID()
    var image: UIImage
    var note: String
    var source: String          // what was marked up, e.g. "v4_board.png" or "Pasted image"
    var context: [String] = []  // what the strokes are on, in words (lines, text, elements)

    /// The strokes in words, indented under the picture's line in a message.
    var contextMarkdown: String {
        context.isEmpty ? "" : context.map { "   - " + $0.replacingOccurrences(of: "\n", with: "\n     ") }.joined(separator: "\n") + "\n"
    }
}

/// What you're writing back on one session: per-section comments on its
/// proposal, an overall note, and markups/attachments. Sent as Markdown with
/// the images uploaded into the project for Claude to Read.
@MainActor
@Observable
final class ReviewDraft {
    var sectionNotes: [String: String] = [:]
    var overall = ""
    var markups: [Markup] = []
    var choices: [String: String] = [:]     // question → the option you picked (when not Claude's recommendation)
    var leftOut: Set<String> = []           // sections to drop from the plan

    var hasNotes: Bool {
        !overall.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !choices.isEmpty || !leftOut.isEmpty
            || sectionNotes.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !markups.isEmpty
    }

    func clear() {
        sectionNotes = [:]
        overall = ""
        markups = []
        choices = [:]
        leftOut = []
    }

    func compose(ws: WorkspaceState, sessionId: String, sections: [String], heading: String) async throws -> String? {
        guard hasNotes else { return nil }
        var out = "## \(heading)\n"
        let dropped = sections.filter { leftOut.contains($0) }
        if !dropped.isEmpty {
            out += "\n### Leave these out (don't do them)\n" + dropped.map { "- \($0)\n" }.joined()
        }
        if !choices.isEmpty {
            out += "\n### My choices\n" + choices.sorted { $0.key < $1.key }.map { "- \($0.key) → \($0.value)\n" }.joined()
        }
        for title in sections {
            if let note = sectionNotes[title]?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                out += "\n### On “\(title)”\n\(note)\n"
            }
        }
        if !markups.isEmpty {
            out += try await composeImages(ws: ws, sessionId: sessionId)
        }
        let o = overall.trimmingCharacters(in: .whitespacesAndNewlines)
        if !o.isEmpty { out += "\n### Overall\n\(o)\n" }
        return out
    }

    /// Uploads the images and returns a Markdown list referencing them.
    func composeImages(ws: WorkspaceState, sessionId: String) async throws -> String {
        var out = "\n### Marked-up images (Read each one; the drawing shows what I mean)\n"
        for (i, m) in markups.enumerated() {
            guard let png = m.image.pngData() else { continue }
            let path = try await ws.api.uploadMarkup(sessionId: sessionId, png: png)
            let note = m.note.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "\(i + 1). \(m.source): ![markup \(i + 1)](\(path))" + (note.isEmpty ? "" : " — \(note)") + "\n"
            out += m.contextMarkdown
        }
        return out
    }
}

// MARK: - Markup sheet

/// Draw on an image (Apple Pencil or finger) and add a note. Multi-page
/// sources (schematic PDFs) get a page stepper.
struct MarkupSheet: View {
    let pages: [UIImage]
    let source: String
    var initialNote = ""
    let onDone: (Markup) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var canvas = PKCanvasView()
    @State private var note = ""
    @State private var imageRect: CGRect = .zero

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let rect = fitted(pages[page].size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: pages[page]).resizable().scaledToFit()
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                        CanvasView(canvas: canvas)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                    .onAppear { imageRect = rect }
                    .onChange(of: geo.size) { imageRect = fitted(pages[page].size, in: geo.size) }
                    .onChange(of: page) { imageRect = fitted(pages[page].size, in: geo.size) }
                }
                .background(Color(uiColor: .systemGray6))

                VStack(spacing: 10) {
                    if pages.count > 1 {
                        Stepper("Page \(page + 1) of \(pages.count)", value: $page, in: 0...(pages.count - 1))
                            .onChange(of: page) { canvas.drawing = PKDrawing() }
                    }
                    // Speak the note: the same transcription as voice notes in the reply box.
                    WritingField(placeholder: "What should change here? Tap the waveform to speak it.",
                                 text: $note, maxLines: 5, voiceSize: 30)
                }
                .padding()
            }
            .navigationTitle("Mark up \(source)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { canvas.drawing = PKDrawing() } label: { Image(systemName: "eraser") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to review") {
                        onDone(Markup(image: flatten(), note: note,
                                      source: pages.count > 1 ? "\(source) (page \(page + 1))" : source))
                        dismiss()
                    }
                    .disabled(canvas.drawing.strokes.isEmpty && note.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { note = initialNote }
        }
    }

    private func fitted(_ size: CGSize, in box: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let s = min(box.width / size.width, box.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    /// The page at full resolution with the drawing scaled on top.
    private func flatten() -> UIImage {
        let base = pages[page]
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: base.size, format: fmt).image { _ in
            base.draw(in: CGRect(origin: .zero, size: base.size))
            guard imageRect.width > 0 else { return }
            let scale = base.size.width / imageRect.width
            let ink = canvas.drawing.image(from: CGRect(origin: .zero, size: imageRect.size), scale: scale)
            ink.draw(in: CGRect(origin: .zero, size: base.size))
        }
    }
}

private struct CanvasView: UIViewRepresentable {
    let canvas: PKCanvasView

    func makeUIView(context: Context) -> PKCanvasView {
        // Once you've used a Pencil, only it draws: fingers and palms don't leave marks.
        canvas.drawingPolicy = Pencil.seen ? .pencilOnly : .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.tool = PKInkingTool(.pen, color: Theme.inkUIColor, width: 4)
        context.coordinator.picker.setVisible(true, forFirstResponder: canvas)
        context.coordinator.picker.addObserver(canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { let picker = PKToolPicker() }
}

// MARK: - Rasterizing things to mark up

enum Rasterize {
    static func pdfPages(_ data: Data, maxPages: Int = 30) -> [UIImage] {
        guard let doc = PDFDocument(data: data) else { return [] }
        return (0..<min(doc.pageCount, maxPages)).compactMap { i in
            guard let p = doc.page(at: i) else { return nil }
            let b = p.bounds(for: .mediaBox)
            let scale = 2400 / max(b.width, b.height)
            return p.thumbnail(of: CGSize(width: b.width * scale, height: b.height * scale), for: .mediaBox)
        }
    }

    static func model(at url: URL) -> UIImage? {
        let scene = ModelView.load(url)
        let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        r.scene = scene
        r.autoenablesDefaultLighting = true
        r.pointOfView = scene.rootNode.childNodes.last(where: { $0.camera != nil })
        return r.snapshot(atTime: 0, with: CGSize(width: 1600, height: 1200), antialiasingMode: .multisampling4X)
    }

    /// A KiCad render as fetched from the host: schematic PDF, board SVG or 3D PNG.
    @MainActor
    static func kicad(_ data: Data, view: String, isBoard: Bool) async -> [UIImage] {
        if !isBoard { return pdfPages(data) }
        if view == "3d" { return UIImage(data: data).map { [$0] } ?? [] }
        return await svg(data).map { [$0] } ?? []
    }

    /// SVGs are drawn by WebKit; snapshot an offscreen web view.
    @MainActor
    static func svg(_ data: Data, size: CGSize = CGSize(width: 1600, height: 1200)) async -> UIImage? {
        let web = WKWebView(frame: CGRect(origin: .zero, size: size))
        let loader = Loader()
        web.navigationDelegate = loader
        let b64 = data.base64EncodedString()
        web.loadHTMLString("""
            <html><head><meta name="viewport" content="width=\(Int(size.width))"><style>
            html,body{margin:0;background:#fff;height:100%}body{display:flex;align-items:center;justify-content:center}
            img{max-width:100%;max-height:100%}</style></head>
            <body><img src="data:image/svg+xml;base64,\(b64)"></body></html>
            """, baseURL: nil)
        await loader.wait()
        try? await Task.sleep(for: .milliseconds(150))
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(origin: .zero, size: size)
        return try? await web.takeSnapshot(configuration: cfg)
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        private var cont: CheckedContinuation<Void, Never>?
        private var done = false
        func wait() async {
            if done { return }
            await withCheckedContinuation { cont = $0 }
        }
        private func finish() {
            done = true
            cont?.resume()
            cont = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    }
}

// MARK: - Environment

/// Which session markups made inside a view are attached to.
private struct ReviewSessionKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var reviewSessionId: String? {
        get { self[ReviewSessionKey.self] }
        set { self[ReviewSessionKey.self] = newValue }
    }
}
