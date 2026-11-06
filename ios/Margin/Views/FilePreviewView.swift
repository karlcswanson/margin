import ModelIO
import PDFKit
import QuickLook
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import WebKit

/// Previews a file from a workspace host: images, PDFs, SVGs, STL/OBJ/USDZ
/// models, Markdown and source text. Anything else opens in Quick Look.
struct FilePreviewView: View {
    let ws: WorkspaceState
    let project: String
    let entry: FileEntry
    /// Lines Claude pointed at: shown first, with the whole file below.
    var focusLines: ClosedRange<Int>? = nil

    @State private var data: Data?
    @State private var localURL: URL?
    @State private var error: String?
    @State private var quickLook: URL?
    @State private var showSource = false
    #if DEBUG
    // Simulator checks: SIMCTL_CHILD_MARGIN_EDIT=1 (with MARGIN_FILE) opens the editor.
    @State private var editing = ProcessInfo.processInfo.environment["MARGIN_EDIT"] != nil
    #else
    @State private var editing = false
    #endif
    @State private var shot = SceneSnapshot()
    @State private var kicadShown: (view: String, data: Data)?
    @State private var markupPages: [UIImage]?
    @State private var finished: Markup?
    @State private var addedTo: String?
    @State private var changes: DiffFile?          // uncommitted changes to this file, if any
    @State private var showChanges = false
    @State private var before: (data: Data, url: URL)?
    @State private var beforeError: String?
    @Environment(AppModel.self) private var model
    @Environment(\.reviewSessionId) private var reviewSessionId

    private var isModel: Bool { ["model", "cad"].contains(entry.kind) }

    private func received(_ m: Markup) {
        if let sid = reviewSessionId { attach(m, to: sid, open: false) } else { finished = m }
    }

    private var canMarkUp: Bool { ["image", "pdf", "svg", "model", "cad", "kicad"].contains(entry.kind) && !showSource }

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let data, let localURL {
                if showChanges, let changes {
                    changesView(changes, data: data, url: localURL)
                } else {
                    // Models orbit under your fingers; the Pencil takes the angle you left them at to a sheet.
                    content(data: data, url: localURL)
                        .inkable(enabled: canMarkUp && !isModel, gestures: true, source: entry.name) { received($0) }
                        .onPencil(enabled: canMarkUp && isModel, gestures: true) { Task { await startMarkup() } }
                }
            } else {
                ProgressView("Loading \(entry.name)…")
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if changes != nil {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $showChanges) {
                        Text("File").tag(false)
                        Text("Changes").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 220)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                WorkspaceBadge(ws: ws)
                if ["text", "markdown", "csv"].contains(entry.kind) {
                    Button { editing = true } label: { Label("Edit", systemImage: "square.and.pencil") }
                }
                if canMarkUp, data != nil {
                    Button { Task { await startMarkup() } } label: {
                        Label("Mark up", systemImage: "pencil.tip.crop.circle")
                    }
                }
                if let localURL {
                    Button { quickLook = localURL } label: { Image(systemName: "eye") }
                    ShareLink(item: localURL)
                }
            }
        }
        .quickLookPreview($quickLook)
        .sheet(isPresented: Binding(get: { markupPages != nil }, set: { if !$0 { markupPages = nil } })) {
            MarkupSheet(pages: markupPages ?? [], source: entry.name) { received($0) }
        }
        .confirmationDialog("Send this markup to…", isPresented: Binding(
            get: { finished != nil }, set: { if !$0 { finished = nil } }), titleVisibility: .visible) {
            ForEach(recentSessions) { s in
                Button(s.title) { if let m = finished { attach(m, to: s.sessionId, open: true) } }
            }
        } message: {
            Text(recentSessions.isEmpty
                 ? "There are no sessions in \(project) yet. Start one, then mark this up again."
                 : "It's added to your reply there, ready to send with a note.")
        }
        .overlay(alignment: .bottom) {
            if let addedTo {
                Label("Markup added to your reply in “\(addedTo)”", systemImage: "checkmark.circle.fill")
                    .font(Theme.Fonts.meta).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule()).padding()
                    .task { try? await Task.sleep(for: .seconds(3)); self.addedTo = nil }
            }
        }
        .fullScreenCover(isPresented: $editing, onDismiss: { Task { await load() } }) {
            EditorView(ws: ws, project: project, path: entry.path)
        }
        .task { await load() }
        .task(id: showChanges) { if showChanges { await loadBefore() } }
    }

    // MARK: changes since the last commit

    private var isText: Bool { ["text", "markdown", "csv"].contains(entry.kind) }

    @ViewBuilder
    private func changesView(_ file: DiffFile, data: Data, url: URL) -> some View {
        let isNew = file.status == "added" || file.status == "new"
        if isText || (entry.kind == "kicad" && showSource) || (entry.kind == "other" && !file.binary) {
            FileDiffView(file: file)
        } else if entry.kind == "kicad", let root = ws.projects.first(where: { $0.name == project })?.path {
            let abs = (root as NSString).appendingPathComponent(entry.path)
            BeforeAfter(isNew: isNew) {
                KiCadView(ws: ws, path: abs, cwd: nil, ref: "HEAD")
            } after: {
                KiCadView(ws: ws, path: abs, cwd: nil)
            }
        } else {
            BeforeAfter(isNew: isNew) {
                if let b = before { viewer(data: b.data, url: b.url, snapshot: nil) }
                else if let beforeError { Text(beforeError).font(Theme.Fonts.caption).foregroundStyle(.secondary).padding() }
                else { ProgressView() }
            } after: {
                viewer(data: data, url: url, snapshot: shot)
            }
        }
    }

    /// The file's media viewer, for either side of a comparison.
    @ViewBuilder
    private func viewer(data: Data, url: URL, snapshot: SceneSnapshot?) -> some View {
        switch entry.kind {
        case "image":
            if let img = UIImage(data: data) { ZoomableImage(image: img) } else { fallback(url) }
        case "pdf": PDFKitView(data: data)
        case "svg": SVGView(data: data)
        case "model", "cad": ModelView(url: url, snapshot: snapshot, controls: true)
        default: fallback(url)
        }
    }

    /// Whether this file differs from the last commit (quietly nothing outside git).
    private func loadChanges() async {
        guard let d = try? await ws.api.gitDiff(project: project, base: "", path: entry.path),
              !d.diff.isEmpty else { changes = nil; return }
        changes = UnifiedDiff.parse(d.diff).first
    }

    private func loadBefore() async {
        guard before == nil, !isText, entry.kind != "kicad",
              changes.map({ $0.status != "added" && $0.status != "new" }) ?? false else { return }
        do {
            let root = ws.projects.first(where: { $0.name == project })?.path ?? ""
            let d = entry.kind == "cad"
                ? try await ws.api.render(path: (root as NSString).appendingPathComponent(entry.path),
                                          cwd: nil, view: "parts", ref: "HEAD")
                : try await ws.api.gitFile(project: project, path: entry.path)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("margin-before/\(UInt(bitPattern: entry.path.hashValue))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(entry.kind == "cad" ? entry.name + ".parts.json" : entry.name)
            try d.write(to: url, options: .atomic)
            before = (d, url)
        } catch {
            beforeError = "Couldn't load the last committed version: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func content(data: Data, url: URL) -> some View {
        switch entry.kind {
        case "image":
            if let img = UIImage(data: data) {
                ZoomableImage(image: img)
            } else { fallback(url) }
        case "pdf":
            PDFKitView(data: data)
        case "svg":
            SVGView(data: data)
        case "model", "cad":
            ModelView(url: url, snapshot: shot, controls: true)
        case "markdown":
            ScrollView {
                excerpt(data)
                MarkdownText(text: String(decoding: data, as: UTF8.self))
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding()
            }
        case "kicad":
            VStack(spacing: 0) {
                Picker("", selection: $showSource) {
                    Text("Rendered").tag(false)
                    Text("Source").tag(true)
                }
                .pickerStyle(.segmented).frame(maxWidth: 240).padding(.top, 8)
                if showSource {
                    ScrollView {
                        CodeBlock(code: String(decoding: data.prefix(400_000), as: UTF8.self),
                                  language: "kicad", title: entry.path, lineNumbers: true)
                            .padding()
                    }
                } else if let root = ws.projects.first(where: { $0.name == project })?.path {
                    KiCadView(ws: ws, path: (root as NSString).appendingPathComponent(entry.path), cwd: nil) {
                        kicadShown = ($0, $1)
                    }
                }
            }
        case "text", "csv":
            ScrollView {
                excerpt(data)
                CodeBlock(code: String(decoding: data.prefix(400_000), as: UTF8.self),
                          language: Highlighter.language(forPath: entry.name),
                          title: entry.path, lineNumbers: true)
                    .padding()
            }
        default:
            fallback(url)
        }
    }

    @ViewBuilder private func excerpt(_ data: Data) -> some View {
        if let r = focusLines {
            let lines = String(decoding: data.prefix(400_000), as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false)
            let from = max(1, r.lowerBound - 2), to = min(lines.count, r.upperBound + 2)
            if from <= to {
                VStack(alignment: .leading, spacing: 6) {
                    Label(r.count == 1 ? "Line \(r.lowerBound)" : "Lines \(r.lowerBound)–\(r.upperBound)",
                          systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(Theme.Fonts.caption.weight(.semibold)).foregroundStyle(.tint)
                    CodeBlock(code: lines[(from - 1)..<to].joined(separator: "\n"),
                              language: Highlighter.language(forPath: entry.name), lineNumbers: true, startLine: from)
                }
                .padding(.horizontal).padding(.top)
            }
        }
    }

    private func fallback(_ url: URL) -> some View {
        ContentUnavailableView {
            Label(entry.name, systemImage: "doc")
        } actions: {
            Button("Open in Quick Look") { quickLook = url }.buttonStyle(.borderedProminent)
        }
    }

    private var recentSessions: [SessionRow] {
        Array(ws.sessions.filter { $0.project == project }
            .sorted { ($0.lastModified ?? 0) > ($1.lastModified ?? 0) }.prefix(6))
    }

    /// What's on screen as images to draw on: the model at the angle you've
    /// turned it to, the KiCad view you picked, every page of a PDF.
    private func startMarkup() async {
        guard let data else { return }
        var pages: [UIImage] = []
        switch entry.kind {
        case "image": pages = UIImage(data: data).map { [$0] } ?? []
        case "pdf": pages = Rasterize.pdfPages(data)
        case "svg": pages = await Rasterize.svg(data).map { [$0] } ?? []
        case "model", "cad":
            if let img = shot.image() { pages = [img] }
        case "kicad":
            if let k = kicadShown {
                pages = await Rasterize.kicad(k.data, view: k.view, isBoard: entry.name.hasSuffix(".kicad_pcb"))
            }
        default: break
        }
        if !pages.isEmpty { markupPages = pages }
    }

    private func attach(_ m: Markup, to sessionId: String, open: Bool) {
        ws.draft(for: sessionId).markups.append(m)
        finished = nil
        addedTo = ws.session(sessionId)?.title ?? "this session"
        if open, let slug = ws.endpoint.slug { model.open(slug: slug, proposalId: nil, sessionId: sessionId) }
    }

    private func load() async {
        do {
            let step = entry.kind == "cad"
            let root = ws.projects.first(where: { $0.name == project })?.path ?? ""
            let d = step
                ? try await ws.api.render(path: (root as NSString).appendingPathComponent(entry.path), cwd: nil, view: "parts")
                : try await ws.api.fileData(project: project, path: entry.path)
            // Each file gets its own folder so an OBJ's .mtl and textures sit beside it.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("margin", isDirectory: true)
                .appendingPathComponent(ws.endpoint.slug ?? ws.id.uuidString, isDirectory: true)
                .appendingPathComponent(String(UInt(bitPattern: entry.path.hashValue)), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(step ? entry.name + ".parts.json" : entry.name)
            try d.write(to: url, options: .atomic)
            if entry.name.lowercased().hasSuffix(".obj") {
                let folder = (entry.path as NSString).deletingLastPathComponent
                _ = await ModelCompanions.fetch(objAt: url, data: d) { name in
                    try await ws.api.fileData(project: project, path: (folder as NSString).appendingPathComponent(name))
                }
            }
            data = d
            localURL = url
            before = nil
            await loadChanges()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Viewers

struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width * scale)
            }
        }
        .gesture(MagnificationGesture()
            .onChanged { scale = max(1, min(8, base * $0)) }
            .onEnded { _ in base = scale })
        .onTapGesture(count: 2) { withAnimation { scale = 1; base = 1 } }
    }
}

/// A PDF; the Pencil reads the page text under its marks (part references and nets on a schematic).
struct PDFKitView: View {
    let data: Data
    @State private var holder = PDFHolder()

    var body: some View {
        PDFRep(data: data, holder: holder)
            .inkAnchor("pdf-\(data.count)") { [holder] r, _ in holder.text(under: r) }
    }
}

@MainActor
final class PDFHolder {
    weak var view: PDFView?

    func text(under r: CGRect) -> String? {
        guard let v = view, let page = v.page(for: CGPoint(x: r.midX, y: r.midY), nearest: true) else { return nil }
        let words = page.selection(for: v.convert(r, to: page))?.string?
            .split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        let n = (v.document?.index(for: page)).map { $0 + 1 } ?? 0
        return words.isEmpty ? "page \(n)" : "page \(n), text “\(words.prefix(300))”"
    }
}

private struct PDFRep: UIViewRepresentable {
    let data: Data
    let holder: PDFHolder
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.document = PDFDocument(data: data)
        holder.view = v
        return v
    }
    func updateUIView(_ uiView: PDFView, context: Context) { holder.view = uiView }
}

/// SVGs render through an <img> tag so any embedded script never runs.
struct SVGView: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.isOpaque = false
        v.backgroundColor = .clear
        let b64 = data.base64EncodedString()
        let html = """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=8">
        <style>body{margin:0;background:#fff;display:flex;justify-content:center}img{width:100%;height:auto}</style>
        </head><body><img src="data:image/svg+xml;base64,\(b64)"></body></html>
        """
        v.loadHTMLString(html, baseURL: nil)
        return v
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// STL / OBJ / PLY via ModelIO, USDZ via SceneKit, STEP as parts converted
/// on the host (.parts.json). Orbit, pan and pinch to zoom; with `controls`,
/// hide, ghost and explode the parts of an assembly.
struct ModelView: View {
    let url: URL
    var snapshot: SceneSnapshot? = nil
    var controls = false
    @State private var scene: SCNScene?
    @State private var parts: [ModelPart] = []

    var body: some View {
        Group {
            if let scene {
                SceneCanvas(scene: scene, snapshot: snapshot)
                    .overlay(alignment: .bottom) {
                        if controls, !parts.isEmpty { PartsPanel(parts: parts) }
                    }
            } else {
                ProgressView()
            }
        }
        .task {
            let u = url
            let s = await Task.detached(priority: .userInitiated) { Self.load(u) }.value
            scene = s
            if controls { parts = ModelPart.parts(of: s) }
        }
    }

    nonisolated static func load(_ url: URL) -> SCNScene {
        let scene: SCNScene
        if url.pathExtension.lowercased() == "json", let d = try? Data(contentsOf: url),
           let s = try? PartsFile.scene(from: d) {
            Self.frame(s)
            return s
        } else if url.pathExtension.lowercased() == "usdz", let s = try? SCNScene(url: url) {
            scene = s
        } else {
            let asset = MDLAsset(url: url)
            scene = SCNScene(mdlAsset: asset)
        }
        // Neutral material so plain STL meshes don't render black.
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(white: 0.75, alpha: 1)
        mat.lightingModel = .physicallyBased
        mat.roughness.contents = 0.6
        scene.rootNode.enumerateChildNodes { node, _ in
            if let g = node.geometry, g.firstMaterial?.diffuse.contents == nil || url.pathExtension.lowercased() == "stl" {
                g.materials = [mat]
            }
        }
        Self.frame(scene)
        return scene
    }

    /// Point a camera at the model's bounding box (STLs are often in mm, far from the default camera).
    nonisolated private static func frame(_ scene: SCNScene) {
        let (minV, maxV) = scene.rootNode.boundingBox
        let center = SCNVector3((minV.x + maxV.x) / 2, (minV.y + maxV.y) / 2, (minV.z + maxV.z) / 2)
        let size = max(maxV.x - minV.x, maxV.y - minV.y, maxV.z - minV.z)
        guard size.isFinite, size > 0 else { return }
        let cam = SCNCamera()
        cam.zNear = Double(size) / 100
        cam.zFar = Double(size) * 100
        let node = SCNNode()
        node.camera = cam
        node.position = SCNVector3(center.x + size, center.y + size * 0.8, center.z + size * 1.4)
        node.look(at: center)
        scene.rootNode.addChildNode(node)
    }
}

/// Captures what a 3D view shows right now, after you've orbited and zoomed,
/// so a markup is of the angle you're looking at.
final class SceneSnapshot {
    weak var view: SCNView?
    @MainActor func image() -> UIImage? { view?.snapshot() }
}

private struct SceneCanvas: UIViewRepresentable {
    let scene: SCNScene
    let snapshot: SceneSnapshot?

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = scene
        v.pointOfView = scene.rootNode.childNodes.last(where: { $0.camera != nil })
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.antialiasingMode = .multisampling4X
        v.backgroundColor = UIColor(white: 0.92, alpha: 1)
        snapshot?.view = v
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) { snapshot?.view = v }
}
