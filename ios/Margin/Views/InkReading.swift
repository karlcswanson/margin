import PencilKit
import SwiftUI

// What a Pencil mark is on, in words: beside the marked-up picture, Claude
// gets each stroke's shape and place, and the text, lines or elements under it.

/// Something the Pencil can land on, able to say what's under a part of it.
struct InkAnchor: Equatable {
    let id: String
    let frame: CGRect                               // in the marked view's own space
    let describe: (CGRect, CGSize) -> String?       // a rect inside `frame` (from its top left), and its size

    static func == (a: InkAnchor, b: InkAnchor) -> Bool { a.id == b.id && a.frame == b.frame }
}

struct InkAnchorKey: PreferenceKey {
    static var defaultValue: [InkAnchor] = []
    static func reduce(value: inout [InkAnchor], nextValue: () -> [InkAnchor]) { value += nextValue() }
}

enum InkSpace { static let name = "margin.ink" }

extension View {
    /// When the Pencil marks this view, `text` says what it is.
    func inkAnchor(_ id: String, _ text: String) -> some View {
        inkAnchor(id) { _, _ in text }
    }

    /// When the Pencil marks part of this view, `describe` says what's in that part.
    func inkAnchor(_ id: String, describe: @escaping (CGRect, CGSize) -> String?) -> some View {
        background {
            GeometryReader { g in
                Color.clear.preference(key: InkAnchorKey.self,
                                       value: [InkAnchor(id: id, frame: g.frame(in: .named(InkSpace.name)), describe: describe)])
            }
        }
    }
}

enum InkReading {
    /// One line per stroke (shape and place), followed by what it's on.
    @MainActor
    static func read(_ strokes: [PKStroke], offset: CGPoint, size: CGSize, anchors: [InkAnchor]) -> [String] {
        var out: [String] = []
        var said = Set<String>()
        for (i, s) in strokes.enumerated() {
            let pts = s.path.map(\.location)
            guard let first = pts.first, let last = pts.last else { continue }
            let box = pts.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            var line = "Stroke \(i + 1): \(shape(box, first: first, last: last, count: pts.count)) at \(place(box, in: size))"
            // In the view's own coordinates, a little wider than the ink so a circle takes in what it rings.
            let hit = box.offsetBy(dx: offset.x, dy: offset.y).insetBy(dx: -4, dy: -4)
            var on: [String] = []
            for a in anchors {
                let r = a.frame.intersection(hit)
                guard !r.isNull, r.width > 0 || r.height > 0 else { continue }
                if let d = a.describe(r.offsetBy(dx: -a.frame.minX, dy: -a.frame.minY), a.frame.size), !d.isEmpty, said.insert(d).inserted {
                    on.append(d)
                }
                if on.count >= 12 { break }
            }
            if !on.isEmpty { line += ", on:\n" + on.map { "    " + $0.replacingOccurrences(of: "\n", with: "\n    ") }.joined(separator: "\n") }
            out.append(line)
        }
        return out
    }

    private static func shape(_ b: CGRect, first: CGPoint, last: CGPoint, count: Int) -> String {
        let span = max(b.width, b.height)
        if span < 14 { return "a dot" }
        let gap = hypot(last.x - first.x, last.y - first.y)
        if count > 8, gap < span * 0.3, b.width > 12, b.height > 12 { return "a circle" }
        if b.height < b.width * 0.25 { return "a horizontal line (underline or strike-through)" }
        if b.width < b.height * 0.25 { return "a vertical line" }
        let dir = (last.x > first.x ? "right" : "left") + (abs(last.y - first.y) > span * 0.3 ? (last.y > first.y ? " and down" : " and up") : "")
        return "a line toward the \(dir) (maybe an arrow)"
    }

    private static func place(_ b: CGRect, in size: CGSize) -> String {
        guard size.width > 0, size.height > 0 else { return "" }
        func pct(_ v: CGFloat, _ of: CGFloat) -> Int { Int((v / of * 100).rounded()) }
        return "x \(pct(b.minX, size.width))–\(pct(b.maxX, size.width))%, y \(pct(b.minY, size.height))–\(pct(b.maxY, size.height))% of the picture"
    }
}

/// Elements of an SVG mockup that can be named: text and anything with an id,
/// with where they sit in the drawing's own coordinates.
struct SVGElements {
    struct Element { let label: String; let box: CGRect }
    let viewBox: CGRect
    let elements: [Element]

    init(_ svg: String) {
        let nums: (String) -> [Double] = { $0.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) } }
        func attr(_ tag: String, _ name: String) -> String? {
            guard let r = tag.range(of: #"\b\#(name)\s*=\s*["']([^"']*)["']"#, options: .regularExpression) else { return nil }
            let m = String(tag[r])
            return m.split(separator: m.contains("\"") ? "\"" : "'").dropFirst().first.map(String.init)
        }
        let open = svg.range(of: #"<svg\b[^>]*>"#, options: .regularExpression).map { String(svg[$0]) } ?? ""
        let vb = attr(open, "viewBox").map(nums) ?? []
        viewBox = vb.count == 4 ? CGRect(x: vb[0], y: vb[1], width: vb[2], height: vb[3])
            : CGRect(x: 0, y: 0, width: Double(attr(open, "width") ?? "") ?? 100, height: Double(attr(open, "height") ?? "") ?? 100)

        var found: [Element] = []
        let re = try! NSRegularExpression(pattern: #"<(text|rect|circle|ellipse|g|path|line|image|use)\b([^>]*)>(?:([^<]*)</text>)?"#)
        let ns = svg as NSString
        for m in re.matches(in: svg, range: NSRange(location: 0, length: ns.length)) {
            let kind = ns.substring(with: m.range(at: 1))
            let tag = ns.substring(with: m.range(at: 2))
            let text = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let id = attr(tag, "id")
            guard !text.isEmpty || id != nil else { continue }
            let d = { (k: String) in Double(attr(tag, k) ?? "") }
            var box: CGRect?
            if let x = d("x"), let y = d("y") {
                box = CGRect(x: x, y: kind == "text" ? y - 12 : y, width: d("width") ?? max(20, Double(text.count) * 7), height: d("height") ?? 16)
            } else if let cx = d("cx"), let cy = d("cy") {
                let rx = d("r") ?? d("rx") ?? 10, ry = d("r") ?? d("ry") ?? rx
                box = CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
            }
            guard let box else { continue }
            let label = [text.isEmpty ? nil : "“\(text.prefix(80))”", id.map { "#\($0)" }].compactMap { $0 }.joined(separator: " ")
            found.append(Element(label: "\(kind) \(label)", box: box))
        }
        elements = found
    }

    /// Elements under a part of the drawing shown at `shown` size.
    func under(_ r: CGRect, shown: CGSize) -> String? {
        guard shown.width > 0, shown.height > 0 else { return nil }
        let sx = viewBox.width / shown.width, sy = viewBox.height / shown.height
        let area = CGRect(x: viewBox.minX + r.minX * sx, y: viewBox.minY + r.minY * sy, width: r.width * sx, height: r.height * sy)
        let hits = elements.filter { $0.box.intersects(area) }.prefix(8).map(\.label)
        return hits.isEmpty ? nil : "mockup elements: " + hits.joined(separator: ", ")
    }
}
