import PencilKit
import SwiftUI

/// Ink right on what you're looking at. The Pencil's first stroke already
/// draws: the view is held still under the ink (fingers elsewhere keep
/// scrolling, and the ink moves with it), and a small bar takes a note and
/// adds it to your reply. No sheet, no screenshot step.
extension View {
    func inkable(enabled: Bool = true, gestures: Bool = false, source: String,
                 done: @escaping (Markup) -> Void) -> some View {
        modifier(Inkable(enabled: enabled, gestures: gestures, source: source, done: done))
    }
}

@MainActor
@Observable
final class InkSession {
    let image: UIImage
    let rect: CGRect
    var live: [CGPoint] = []              // the stroke being drawn as the ink starts
    var note = ""
    var strokes = 0
    @ObservationIgnored let canvas = PKCanvasView()
    @ObservationIgnored private var times: [TimeInterval] = []
    @ObservationIgnored private let t0 = Date()

    init(_ s: InkStart) {
        image = s.image
        rect = s.rect
        if let p = s.point { add(p) }
    }

    func add(_ p: CGPoint) {
        live.append(CGPoint(x: p.x - rect.minX, y: p.y - rect.minY))
        times.append(Date().timeIntervalSince(t0))
    }

    /// The first stroke becomes a real one on the canvas.
    func finishLive() {
        guard let first = times.first else { return }
        var points = zip(live, times).map { p, t in
            PKStrokePoint(location: p, timeOffset: t - first, size: CGSize(width: 4, height: 4),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        if points.count == 1 { points.append(points[0]) }      // a dot
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        canvas.drawing.strokes.append(PKStroke(ink: PKInk(.pen, color: Theme.inkUIColor), path: path))
        live = []
        times = []
        strokes = canvas.drawing.strokes.count
    }

    func undo() {
        guard !canvas.drawing.strokes.isEmpty else { return }
        canvas.drawing.strokes.removeLast()
        strokes = canvas.drawing.strokes.count
    }

    /// What was on screen with the ink on top, at screen resolution.
    func flatten() -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: fmt).image { _ in
            image.draw(at: .zero)
            canvas.drawing.image(from: CGRect(origin: .zero, size: image.size), scale: image.scale).draw(at: .zero)
        }
    }
}

private struct Inkable: ViewModifier {
    let enabled: Bool
    let gestures: Bool
    let source: String
    let done: (Markup) -> Void
    @State private var ink: InkSession?
    @State private var anchors: [InkAnchor] = []

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: InkSpace.name)
            .onPreferenceChange(InkAnchorKey.self) { anchors = $0 }
            .onPencilInk(enabled: enabled, gestures: gestures, armed: ink == nil,
                         began: { ink = InkSession($0) },
                         moved: { ink?.add($0) },
                         ended: { ink?.finishLive() })
            .overlay(alignment: .topLeading) {
                if let ink {
                    InkLayer(ink: ink, add: {
                        let context = InkReading.read(ink.canvas.drawing.strokes, offset: ink.rect.origin,
                                                      size: ink.image.size, anchors: anchors)
                        done(Markup(image: ink.flatten(), note: ink.note, source: source, context: context))
                        self.ink = nil
                    }, cancel: { self.ink = nil })
                }
            }
    }
}

private struct InkLayer: View {
    @Bindable var ink: InkSession
    let add: () -> Void
    let cancel: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(uiImage: ink.image).resizable()
            InkCanvas(ink: ink)
            Path { p in
                guard let f = ink.live.first else { return }
                p.move(to: f)
                for q in ink.live.dropFirst() { p.addLine(to: q) }
            }
            .stroke(Theme.ink, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            .allowsHitTesting(false)
        }
        .frame(width: ink.rect.width, height: ink.rect.height)
        .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor.opacity(0.7), lineWidth: 2) }
        // On a tall view the bar sits inside it at the bottom; on a short one
        // (a line of code, a message) it hangs below so it doesn't cover the ink.
        .overlay(alignment: .bottom) {
            bar.alignmentGuide(.bottom) { ink.rect.height > 320 ? $0[.bottom] : $0[.top] }
        }
        .offset(x: ink.rect.minX, y: ink.rect.minY)
        .zIndex(1)
    }

    private var bar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            WritingField(placeholder: "Note (optional)", text: $ink.note, maxLines: 3, voiceSize: 24)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 10))
            Button { ink.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(ink.strokes == 0)
                .accessibilityLabel("Undo stroke")
            Button("Cancel", role: .cancel, action: cancel)
            Button("Add to reply", action: add).buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 620)
        .padding(8)
    }
}

private struct InkCanvas: UIViewRepresentable {
    let ink: InkSession

    func makeUIView(context: Context) -> PKCanvasView {
        let c = ink.canvas
        c.drawingPolicy = .pencilOnly          // fingers and palms don't leave marks
        c.backgroundColor = .clear
        c.isOpaque = false
        c.isScrollEnabled = false
        c.tool = PKInkingTool(.pen, color: Theme.inkUIColor, width: 4)
        c.delegate = context.coordinator
        return c
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(ink: ink) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let ink: InkSession
        init(ink: InkSession) { self.ink = ink }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            MainActor.assumeIsolated { ink.strokes = canvasView.drawing.strokes.count }
        }
    }
}
