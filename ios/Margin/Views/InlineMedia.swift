import SwiftUI
import UIKit

/// An image, 3D model or PDF Claude wrote, read or referenced, fetched from
/// the host and shown in the transcript at a fixed height (so loading doesn't
/// shift the scroll position). Tap for full screen, where models orbit and
/// zoom and PDFs page.
struct MediaThumb: View {
    let ws: WorkspaceState
    let path: String
    let cwd: String?
    var hideIfMissing = false

    @State private var data: Data?
    @State private var localURL: URL?
    @State private var error: String?
    @State private var fullScreen = false
    @State private var markupPages: [UIImage]?
    @State private var preparing = false
    @State private var inlineShot = SceneSnapshot()
    @State private var fullShot = SceneSnapshot()
    @State private var kicadShown: (view: String, data: Data)?
    @Environment(\.reviewSessionId) private var reviewSessionId

    private enum Kind { case image, svg, model, pdf, schematic, board }
    private var kind: Kind {
        switch (path as NSString).pathExtension.lowercased() {
        case "svg": return .svg
        case "stl", "obj", "ply", "usdz", "step", "stp": return .model
        case "pdf": return .pdf
        case "kicad_sch": return .schematic
        case "kicad_pcb": return .board
        default: return .image
        }
    }
    private var name: String { (path as NSString).lastPathComponent }
    private var isStep: Bool { ["step", "stp"].contains((path as NSString).pathExtension.lowercased()) }
    private var height: CGFloat { kind == .image || kind == .svg ? 260 : 340 }

    var body: some View {
        if hideIfMissing, error != nil {
            EmptyView()
        } else {
            thumb
        }
    }

    private var thumb: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let data {
                    viewer(data: data).allowsHitTesting(false)
                } else if let error {
                    unavailable(error)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: 560, minHeight: height, maxHeight: height)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                if data != nil, kind != .image, kind != .svg {
                    Label(kind == .model ? "Tap to rotate and explode" : kind == .board ? "Tap for 2D / 3D" : "Tap to read",
                          systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(Theme.Fonts.small).padding(6)
                        .background(.thinMaterial, in: Capsule()).padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if data != nil, reviewSessionId != nil {
                    Button { Task { await startMarkup(fullScreen: false) } } label: {
                        Group {
                            if preparing { ProgressView().controlSize(.small) }
                            else { Label("Mark up", systemImage: "pencil.tip.crop.circle") }
                        }
                        .font(Theme.Fonts.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if data != nil { fullScreen = true } }
            .onPencil(enabled: data != nil && reviewSessionId != nil) { Task { await startMarkup(fullScreen: false) } }

            Text(name).font(Theme.Fonts.caption).foregroundStyle(.secondary)
        }
        .task(id: path) { await load() }
        .sheet(isPresented: markingUp(fullScreen: false)) { markupSheet }
        .fullScreenCover(isPresented: $fullScreen) {
            NavigationStack {
                Group {
                    if kind == .schematic || kind == .board {
                        KiCadView(ws: ws, path: path, cwd: cwd) { kicadShown = ($0, $1) }
                    } else if let data {
                        viewer(data: data, interactive: true)
                    }
                }
                    .inkable(enabled: reviewSessionId != nil && kind != .model, gestures: true, source: name) { m in
                        if let sid = reviewSessionId { ws.draft(for: sid).markups.append(m) }
                    }
                    .onPencil(enabled: reviewSessionId != nil && kind == .model, gestures: true) {
                        Task { await startMarkup(fullScreen: true) }
                    }
                    .navigationTitle(name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { fullScreen = false } }
                        if reviewSessionId != nil {
                            ToolbarItem(placement: .primaryAction) {
                                Button { Task { await startMarkup(fullScreen: true) } } label: {
                                    Label("Mark up", systemImage: "pencil.tip.crop.circle")
                                }
                                .disabled(preparing)
                            }
                        }
                        if let localURL {
                            ToolbarItem(placement: .primaryAction) { ShareLink(item: localURL) }
                        }
                    }
                    .sheet(isPresented: markingUp(fullScreen: true)) { markupSheet }
            }
        }
    }

    @ViewBuilder
    private func viewer(data: Data, interactive: Bool = false) -> some View {
        switch kind {
        case .svg:
            SVGView(data: data)
        case .pdf, .schematic:
            PDFKitView(data: data)
        case .board:
            SVGView(data: data)
        case .model:
            if let localURL { ModelView(url: localURL, snapshot: interactive ? fullShot : inlineShot, controls: interactive) }
            else { unavailable("Couldn't open model") }
        case .image:
            if let img = UIImage(data: data) {
                if interactive { ZoomableImage(image: img) } else { Image(uiImage: img).resizable().scaledToFit() }
            } else {
                unavailable("Not an image")
            }
        }
    }

    private func unavailable(_ why: String) -> some View {
        Label(why, systemImage: "photo.badge.exclamationmark")
            .font(Theme.Fonts.caption).foregroundStyle(.secondary).padding()
    }

    private var markupSheet: some View {
        MarkupSheet(pages: markupPages ?? [], source: name) { m in
            if let sid = reviewSessionId { ws.draft(for: sid).markups.append(m) }
        }
    }

    /// The markup sheet shows over whichever is frontmost: the transcript or the full-screen viewer.
    private func markingUp(fullScreen: Bool) -> Binding<Bool> {
        Binding(get: { markupPages != nil && self.fullScreen == fullScreen },
                set: { if !$0 { markupPages = nil } })
    }

    /// Turn what you're looking at into images you can draw on: the model at
    /// the angle you've turned it to, the KiCad view you picked.
    private func startMarkup(fullScreen: Bool) async {
        guard let data else { return }
        preparing = true
        defer { preparing = false }
        var pages: [UIImage] = []
        switch kind {
        case .image: pages = UIImage(data: data).map { [$0] } ?? []
        case .svg: pages = await Rasterize.svg(data).map { [$0] } ?? []
        case .pdf: pages = Rasterize.pdfPages(data)
        case .schematic, .board:
            let shown = fullScreen ? kicadShown ?? ("2d", data) : ("2d", data)
            pages = await Rasterize.kicad(shown.1, view: shown.0, isBoard: kind == .board)
        case .model:
            if let img = (fullScreen ? fullShot : inlineShot).image() {
                pages = [img]
            } else if let localURL {
                let url = localURL
                pages = await Task.detached { Rasterize.model(at: url) }.value.map { [$0] } ?? []
            }
        }
        if !pages.isEmpty { markupPages = pages }
    }

    private func load() async {
        do {
            let d = kind == .schematic || kind == .board
                ? try await ws.api.render(path: path, cwd: cwd, view: "2d")
                : isStep ? try await ws.api.render(path: path, cwd: cwd, view: "parts")
                : try await ws.api.media(path: path, cwd: cwd)
            // ModelIO/SceneKit load from files, and Share needs one too.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("margin-media/\(UInt(bitPattern: path.hashValue))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(isStep ? name + ".parts.json" : name)
            try d.write(to: url, options: .atomic)
            var detail = describe(d)
            if name.lowercased().hasSuffix(".obj") {
                let folder = (path as NSString).deletingLastPathComponent
                let (found, missing) = await ModelCompanions.fetch(objAt: url, data: d) { [ws, cwd] n in
                    try await ws.api.media(path: (folder as NSString).appendingPathComponent(n), cwd: cwd)
                }
                detail = missing.isEmpty
                    ? (found.isEmpty ? "no mtllib, so no colours; shown grey" : "with " + found.joined(separator: ", "))
                    : "couldn't fetch \(missing.joined(separator: ", ")) (keep them next to the OBJ, paths relative to it); colours may be missing"
            }
            localURL = url
            data = d
            report(ok: true, detail)
        } catch {
            self.error = kind == .schematic || kind == .board || isStep
                ? "Couldn't render \(name): \(error.localizedDescription)"
                : "Couldn't load \(name)"
            report(ok: false, error.localizedDescription)
        }
    }

    /// Tell Claude (with its next prompt) whether this showed, so a bad path
    /// or format gets fixed without you having to say so.
    private func report(ok: Bool, _ detail: String?) {
        guard let sid = reviewSessionId else { return }
        ws.reportDisplay(sessionId: sid, path: path, ok: ok, detail: detail)
    }

    private func describe(_ d: Data) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "stl", "ply": return "geometry only, shown grey (use STEP or USDZ for colours)"
        case "step", "stp":
            let n = (try? JSONDecoder().decode(PartsFile.self, from: d))?.parts.count
            return n.map { "\($0) part\($0 == 1 ? "" : "s"), with colours" }
        default: return nil
        }
    }
}

/// A KiCad schematic (PDF, every sheet) or board (2D layers / 3D render),
/// rendered on the host by kicad-cli.
struct KiCadView: View {
    let ws: WorkspaceState
    let path: String
    let cwd: String?
    /// Called with the view ("2d"/"3d") and render on screen, for marking it up.
    var onShow: ((String, Data) -> Void)? = nil
    /// Render the file as it was at this commit instead of now.
    var ref: String? = nil

    @State private var view = "2d"
    @State private var renders: [String: Data] = [:]
    @State private var error: String?

    private var isBoard: Bool { path.lowercased().hasSuffix(".kicad_pcb") }

    var body: some View {
        VStack(spacing: 0) {
            if isBoard {
                Picker("View", selection: $view) {
                    Text("2D layers").tag("2d")
                    Text("3D").tag("3d")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .padding(8)
            }
            Group {
                if let data = renders[view] {
                    if !isBoard { PDFKitView(data: data) }
                    else if view == "2d" { SVGView(data: data) }
                    else if let img = UIImage(data: data) { ZoomableImage(image: img) }
                } else if let error {
                    ContentUnavailableView("Couldn't render", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    ProgressView(view == "3d" ? "Rendering 3D view on the host…" : "Rendering…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: view) {
            if renders[view] == nil {
                error = nil
                do { renders[view] = try await ws.api.render(path: path, cwd: cwd, view: view, ref: ref) }
                catch { self.error = error.localizedDescription }
            }
            if let d = renders[view] { onShow?(view, d) }
        }
    }
}

/// A small image carried inside a tool result (e.g. a screenshot).
struct InlineImageView: View {
    let image: InlineImage
    @State private var fullScreen = false

    var body: some View {
        if let d = Data(base64Encoded: image.data), let img = UIImage(data: d) {
            Image(uiImage: img).resizable().scaledToFit()
                .frame(maxWidth: 520, maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture { fullScreen = true }
                .fullScreenCover(isPresented: $fullScreen) {
                    NavigationStack {
                        ZoomableImage(image: img)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) { Button("Done") { fullScreen = false } }
                            }
                    }
                }
        }
    }
}
