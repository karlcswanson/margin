import SceneKit
import SwiftUI

// MARK: - STEP, converted on the host

/// A STEP assembly as the host sends it ("margin-parts/1"): one mesh per part
/// with its colour and transparency.
struct PartsFile: Decodable {
    struct Part: Decodable {
        let name: String
        let color: [Double]
        let positions: String
        let normals: String?
        let indices: String
        let groups: [Group]?        // ranges of `indices` per colour (KiCad: body, pins, pads)
    }
    struct Group: Decodable {
        let color: [Double]
        let start: Int
        let count: Int
    }
    let format: String
    let units: String?
    let parts: [Part]

    static func scene(from data: Data) throws -> SCNScene {
        let file = try JSONDecoder().decode(PartsFile.self, from: data)
        let scene = SCNScene()
        for part in file.parts {
            guard let pos = Data(base64Encoded: part.positions), let idx = Data(base64Encoded: part.indices),
                  pos.count >= 36, idx.count >= 12 else { continue }
            var sources = [SCNGeometrySource(data: pos, semantic: .vertex, vectorCount: pos.count / 12,
                                             usesFloatComponents: true, componentsPerVector: 3,
                                             bytesPerComponent: 4, dataOffset: 0, dataStride: 12)]
            if let n = part.normals.flatMap({ Data(base64Encoded: $0) }), n.count == pos.count {
                sources.append(SCNGeometrySource(data: n, semantic: .normal, vectorCount: n.count / 12,
                                                 usesFloatComponents: true, componentsPerVector: 3,
                                                 bytesPerComponent: 4, dataOffset: 0, dataStride: 12))
            }
            let total = idx.count / 4
            let ranges = (part.groups ?? []).filter { $0.start >= 0 && $0.count > 0 && $0.start + $0.count <= total }
            let pieces = ranges.isEmpty ? [Group(color: part.color, start: 0, count: total)] : ranges
            let elements = pieces.map { g in
                SCNGeometryElement(data: idx.subdata(in: g.start * 4 ..< (g.start + g.count) * 4),
                                   primitiveType: .triangles, primitiveCount: g.count / 3, bytesPerIndex: 4)
            }
            let geometry = SCNGeometry(sources: sources, elements: elements)
            geometry.materials = pieces.map { material($0.color) }
            let node = SCNNode(geometry: geometry)
            node.name = part.name
            scene.rootNode.addChildNode(node)
        }
        return scene
    }

    private static func material(_ color: [Double]) -> SCNMaterial {
        let c = color + [0.7, 0.7, 0.72, 1].dropFirst(color.count)
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(red: c[0], green: c[1], blue: c[2], alpha: 1)
        m.roughness.contents = 0.5
        if c[3] < 0.99 {
            // Clear plastic: see the parts inside.
            m.transparency = c[3]
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
        }
        return m
    }
}

// MARK: - OBJ companions

/// An OBJ's colours live in its .mtl file(s), and those can name textures.
/// SceneKit only finds them next to the OBJ, so fetch them alongside it.
enum ModelCompanions {
    /// Fetches what `data` (an OBJ) needs into the folder of `local`; returns
    /// what was loaded and what couldn't be found.
    static func fetch(objAt local: URL, data: Data,
                      get: (String) async throws -> Data) async -> (found: [String], missing: [String]) {
        var found: [String] = [], missing: [String] = []
        for lib in names(after: ["mtllib"], in: data) {
            guard let mtl = try? await get(lib) else { missing.append(lib); continue }
            write(mtl, as: lib, beside: local)
            found.append(lib)
            let maps = names(after: ["map_Kd", "map_Ka", "map_Ks", "map_d", "map_bump", "bump", "map_Bump", "norm"],
                             in: mtl, lastTokenOnly: true)
            for tex in maps where !found.contains(tex) {
                if let t = try? await get(tex) { write(t, as: tex, beside: local); found.append(tex) }
                else { missing.append(tex) }
            }
        }
        return (found, missing)
    }

    private static func names(after keys: [String], in data: Data, lastTokenOnly: Bool = false) -> [String] {
        var out: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
            guard let key = parts.first, keys.contains(String(key)), parts.count > 1 else { continue }
            let rest = parts.dropFirst().map(String.init)
            // "mtllib a.mtl b.mtl"; "map_Kd -s 1 1 1 tex/wood.png"
            for n in lastTokenOnly ? [rest.last!] : rest where !n.hasPrefix("-") && !out.contains(n) { out.append(n) }
        }
        return out
    }

    private static func write(_ data: Data, as name: String, beside local: URL) {
        let url = local.deletingLastPathComponent().appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Parts: hide, ghost, explode

/// Each mesh in a model, with where it sits and which way it moves when the
/// assembly is exploded (away from the middle).
struct ModelPart: Identifiable {
    enum Look: CaseIterable { case shown, ghost, hidden }
    let id: Int
    let name: String
    let node: SCNNode
    let home: SCNVector3
    let push: SCNVector3          // in the node's parent space, at explode = 1

    static func parts(of scene: SCNScene) -> [ModelPart] {
        var nodes: [SCNNode] = []
        scene.rootNode.enumerateHierarchy { n, _ in if n.geometry != nil { nodes.append(n) } }
        guard nodes.count > 1, nodes.count <= 400 else { return [] }
        let (lo, hi) = scene.rootNode.boundingBox
        let mid = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        let size = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
        var names: [String: Int] = [:]
        return nodes.enumerated().map { i, n in
            let (a, b) = n.boundingBox
            let c = n.convertPosition(SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2), to: nil)
            var d = SCNVector3(c.x - mid.x, c.y - mid.y, c.z - mid.z)
            if abs(d.x) + abs(d.y) + abs(d.z) < size * 0.01 { d = SCNVector3(0, size * 0.3, 0) }   // the core part rises
            let push = n.parent?.convertVector(d, from: nil) ?? d
            var name = n.name ?? n.geometry?.name ?? "Part \(i + 1)"
            if name.isEmpty || name.hasPrefix("_") { name = "Part \(i + 1)" }
            names[name, default: 0] += 1
            if names[name]! > 1 { name += " \(names[name]!)" }
            return ModelPart(id: i, name: name, node: n, home: n.position, push: push)
        }
    }

    func apply(look: Look, explode: Float) {
        node.isHidden = look == .hidden
        node.opacity = look == .ghost ? 0.2 : 1
        node.position = SCNVector3(home.x + push.x * explode, home.y + push.y * explode, home.z + push.z * explode)
    }
}

/// Parts list and explode slider over a full-screen model.
struct PartsPanel: View {
    let parts: [ModelPart]
    @State private var looks: [Int: ModelPart.Look] = [:]
    @State private var explode: Double = 0
    @State private var showList = false

    var body: some View {
        HStack(spacing: 12) {
            Button { showList.toggle() } label: {
                Label("\(parts.count) parts", systemImage: "square.3.layers.3d")
            }
            .popover(isPresented: $showList) { list.frame(minWidth: 300, minHeight: 360) }
            Image(systemName: "arrow.down.right.and.arrow.up.left").foregroundStyle(.secondary)
            Slider(value: $explode, in: 0...1.5).frame(maxWidth: 220)
            Image(systemName: "arrow.up.left.and.arrow.down.right").foregroundStyle(.secondary)
        }
        .font(Theme.Fonts.meta)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding()
        .onChange(of: explode) { applyAll() }
    }

    private var list: some View {
        NavigationStack {
            List(parts) { p in
                Button { cycle(p) } label: {
                    HStack {
                        Image(systemName: icon(looks[p.id] ?? .shown))
                            .foregroundStyle(looks[p.id] == .hidden ? Color.secondary : Color.accentColor)
                            .frame(width: 24)
                        Text(p.name).foregroundStyle(looks[p.id] == .hidden ? .secondary : .primary)
                    }
                }
            }
            .navigationTitle("Parts").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Show all") { looks = [:]; applyAll() }
                }
            }
        }
    }

    private func icon(_ look: ModelPart.Look) -> String {
        switch look { case .shown: "eye"; case .ghost: "circle.dotted"; case .hidden: "eye.slash" }
    }

    /// shown → see-through → hidden → shown
    private func cycle(_ p: ModelPart) {
        let all = ModelPart.Look.allCases
        let now = looks[p.id] ?? .shown
        looks[p.id] = all[(all.firstIndex(of: now)! + 1) % all.count]
        p.apply(look: looks[p.id]!, explode: Float(explode))
    }

    private func applyAll() {
        for p in parts { p.apply(look: looks[p.id] ?? .shown, explode: Float(explode)) }
    }
}
