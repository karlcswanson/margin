import SwiftUI
import UIKit

/// Apple Pencil as the way into markup: touch anything markable with the
/// Pencil (or double-tap / squeeze it) and you're drawing on it. Fingers keep
/// scrolling, orbiting and zooming.
enum Pencil {
    /// Set once a Pencil has touched the screen; from then on only the Pencil
    /// draws in markups, so a resting hand or a finger never leaves ink.
    @MainActor static var seen = false
}

extension View {
    /// Runs `action` when the Pencil touches this view. With `gestures`, a
    /// Pencil double-tap or squeeze does it too (for a full-screen viewer, not
    /// for each thumbnail in a list).
    func onPencil(enabled: Bool = true, gestures: Bool = false, perform action: @escaping () -> Void) -> some View {
        overlay { if enabled { PencilTrigger(gestures: gestures, action: { _ in action() }, captures: false) } }
    }

    /// A Pencil double-tap while this screen is frontmost (no sheet over it).
    func onPencilDoubleTap(enabled: Bool = true, perform action: @escaping () -> Void) -> some View {
        background { if enabled { PencilDoubleTap(action: action) } }
    }

    /// The Pencil's touch as live ink: `began` gets what this view shows on
    /// screen and where the Pencil came down (nil for a double-tap or
    /// squeeze), then the stroke follows. Not `armed`: ignores new touches.
    func onPencilInk(enabled: Bool = true, gestures: Bool = false, armed: Bool,
                     began: @escaping (InkStart) -> Void, moved: @escaping (CGPoint) -> Void,
                     ended: @escaping () -> Void) -> some View {
        overlay {
            if enabled {
                PencilTrigger(gestures: gestures, action: { _ in }, captures: true,
                              ink: .init(armed: armed, began: began, moved: moved, ended: ended))
            }
        }
    }
}

/// Where live ink starts: what was on screen (held still under the ink),
/// the part of the view it covers, and where the Pencil came down.
struct InkStart {
    let image: UIImage
    let rect: CGRect
    let point: CGPoint?
}

struct InkHandlers {
    var armed: Bool
    var began: (InkStart) -> Void
    var moved: (CGPoint) -> Void
    var ended: () -> Void
}

private struct PencilTrigger: UIViewRepresentable {
    let gestures: Bool
    let action: (UIImage?) -> Void
    let captures: Bool
    var ink: InkHandlers? = nil

    func makeUIView(context: Context) -> TriggerView {
        let v = TriggerView(gestures: gestures)
        v.action = action
        v.captures = captures
        v.ink = ink
        return v
    }

    func updateUIView(_ v: TriggerView, context: Context) {
        v.action = action
        v.ink = ink
    }

    /// Invisible to touches (everything passes through to the view below); a
    /// Pencil-only recognizer on the window notices Pencil touches inside it.
    final class TriggerView: UIView, UIGestureRecognizerDelegate, PencilTapHandler {
        var action: ((UIImage?) -> Void)?
        var captures = false
        var ink: InkHandlers?
        private var inking = false
        private var recognizer: UILongPressGestureRecognizer?
        private weak var host: UIWindow?
        private var lastFired = Date.distantPast

        private let gestures: Bool

        init(gestures: Bool) {
            self.gestures = gestures
            super.init(frame: .zero)
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if gestures { PencilTaps.shared.update(self) }
            if let r = recognizer { host?.removeGestureRecognizer(r) }
            recognizer = nil
            guard let window else { return }
            let r = UILongPressGestureRecognizer(target: self, action: #selector(touched(_:)))
            r.minimumPressDuration = 0
            r.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            r.cancelsTouchesInView = true      // on markable things the Pencil draws; it doesn't also tap
            r.delaysTouchesBegan = false
            r.delegate = self
            window.addGestureRecognizer(r)
            recognizer = r
            host = window
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let window, !isHidden, alpha > 0 else { return false }
            Pencil.seen = true
            if let ink, !ink.armed { return false }
            let p = touch.location(in: self)
            guard bounds.contains(p) else { return false }
            // Only when this screen is frontmost: not through a sheet, toolbar or menu above it.
            let hit = window.hitTest(touch.location(in: window), with: nil)
            return hit.map { Self.controller(of: $0) === Self.controller(of: self) } ?? false
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func touched(_ g: UILongPressGestureRecognizer) {
            guard let ink else {
                if g.state == .began { fire() }
                return
            }
            switch g.state {
            case .began:
                guard let c = capture() else { return }
                inking = true
                ink.began(InkStart(image: c.0, rect: c.1, point: g.location(in: self)))
            case .changed:
                if inking { ink.moved(g.location(in: self)) }
            case .ended, .cancelled, .failed:
                if inking { ink.ended() }
                inking = false
            default: break
            }
        }

        func pencilTap() { fire() }
        func pencilSqueeze() { fire() }

        private func fire() {
            if let ink {
                guard ink.armed, let c = capture() else { return }
                ink.began(InkStart(image: c.0, rect: c.1, point: nil))
                ink.ended()
                return
            }
            // One markup per gesture, however many touches it took.
            guard Date().timeIntervalSince(lastFired) > 1 else { return }
            lastFired = Date()
            action?(captures ? snapshot() : nil)
        }

        private func snapshot() -> UIImage? { capture()?.0 }

        /// What's on screen under this view, at screen resolution, and which
        /// part of the view that is (the rest may be scrolled off).
        private func capture() -> (UIImage, CGRect)? {
            guard let window else { return nil }
            let frame = convert(bounds, to: window).intersection(window.bounds)
            guard frame.width > 4, frame.height > 4 else { return nil }
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = window.screen.scale
            let img = UIGraphicsImageRenderer(size: frame.size, format: fmt).image { _ in
                window.drawHierarchy(in: CGRect(origin: CGPoint(x: -frame.minX, y: -frame.minY), size: window.bounds.size),
                                     afterScreenUpdates: false)
            }
            return (img, window.convert(frame, to: self))
        }

        private static func controller(of view: UIView) -> UIViewController? {
            var r: UIResponder? = view
            while let next = r?.next {
                if let vc = next as? UIViewController { return vc }
                r = next
            }
            return nil
        }
    }
}

/// Whether `view` is on the topmost presented screen (nothing presented over it).
@MainActor
func isFrontmost(_ view: UIView) -> Bool {
    guard let window = view.window, !view.isHidden else { return false }
    var top = window.rootViewController
    while let p = top?.presentedViewController, !p.isBeingDismissed { top = p }
    return top.map { view.isDescendant(of: $0.view) } ?? false
}

private struct PencilDoubleTap: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> TapView {
        let v = TapView()
        v.action = action
        return v
    }

    func updateUIView(_ v: TapView, context: Context) { v.action = action }

    final class TapView: UIView, PencilTapHandler {
        var action: (() -> Void)?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            PencilTaps.shared.update(self)
        }

        func pencilTap() { action?() }
    }
}

@MainActor
protocol PencilTapHandler: UIView {
    func pencilTap()
    func pencilSqueeze()
}

extension PencilTapHandler {
    func pencilSqueeze() {}
}

/// One Pencil interaction per window, handing double-taps and squeezes to the
/// frontmost screen that wants them (newest first). A per-view interaction
/// on a SwiftUI background view never heard from the system.
@MainActor
final class PencilTaps: NSObject, UIPencilInteractionDelegate {
    static let shared = PencilTaps()

    private struct Entry { weak var view: (any PencilTapHandler)? }
    private var handlers: [Entry] = []
    private var windows = NSHashTable<UIWindow>.weakObjects()

    func update(_ view: any PencilTapHandler) {
        handlers.removeAll { $0.view == nil || $0.view === view }
        guard let window = view.window else { return }
        handlers.append(Entry(view: view))
        if !windows.contains(window) {
            let pencil = UIPencilInteraction()
            pencil.delegate = self
            window.addInteraction(pencil)
            windows.add(window)
        }
    }

    private func target() -> (any PencilTapHandler)? {
        handlers.reversed().compactMap(\.view).first { isFrontmost($0) }
    }

    private func tap() {
        if let t = target() {
            t.pencilTap()
        } else {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()   // heard, nothing here to do
        }
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) { tap() }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        self.tap()
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        if squeeze.phase == .ended { target()?.pencilSqueeze() }
    }
}
