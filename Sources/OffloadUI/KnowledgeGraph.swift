import Foundation
import SwiftUI

/// The knowledge base as a graph: notes are nodes, `[[wikilinks]]` are edges. It is derived from the
/// notes every time (there is no separate hidden store), so it can never disagree with them.
public struct KnowledgeGraph: Sendable {
    public struct Node: Identifiable, Sendable, Equatable {
        public var id: String          // vault-relative path
        public var title: String
        public var domain: String      // top-level folder ("" for the overview)
        public var domainIndex: Int
        public var degree: Int
    }
    public var nodes: [Node]
    public var edges: [(Int, Int)]
    public var domains: [String]

    public static let overviewPath = "README.md"
    static let link = try! NSRegularExpression(pattern: #"\[\[([^\[\]|#\n]+)(?:#[^\]|\n]*)?(?:\|[^\]\n]*)?\]\]"#)

    public static func build(notes: [(path: String, title: String, body: String)]) -> KnowledgeGraph {
        let sorted = notes.sorted { $0.path < $1.path }
        func domain(_ path: String) -> String { path == overviewPath ? "" : String(path.split(separator: "/").first ?? "") }
        let domains = Array(Set(sorted.map { domain($0.path) }.filter { !$0.isEmpty })).sorted()
        var nodes = sorted.map { n in
            Node(id: n.path, title: n.title, domain: domain(n.path), domainIndex: domains.firstIndex(of: domain(n.path)) ?? -1, degree: 0)
        }
        // Titles and file names both resolve a link, case-insensitively; the first note wins a tie.
        var index: [String: Int] = [:]
        for (i, n) in sorted.enumerated() {
            for key in [n.title.lowercased(), ((n.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()] where index[key] == nil { index[key] = i }
        }
        var seen = Set<Int>()
        var edges: [(Int, Int)] = []
        for (i, n) in sorted.enumerated() {
            let ns = n.body as NSString
            for m in link.matches(in: n.body, range: NSRange(location: 0, length: ns.length)) {
                let target = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces).lowercased()
                guard let j = index[target], j != i else { continue }
                let (a, b) = (min(i, j), max(i, j))
                if seen.insert(a * 100_000 + b).inserted { edges.append((a, b)) }
            }
        }
        for (a, b) in edges { nodes[a].degree += 1; nodes[b].degree += 1 }
        return KnowledgeGraph(nodes: nodes, edges: edges, domains: domains)
    }
}

/// A deterministic force-directed layout: links pull, everything repels, and each folder is drawn
/// toward its own region so related notes form constellations. Same input, same picture.
public enum GraphLayout {
    /// Positions in the unit square [-1, 1]², one per node.
    public static func positions(for graph: KnowledgeGraph, iterations: Int = 260) -> [CGPoint] {
        let n = graph.nodes.count
        guard n > 0 else { return [] }
        if n == 1 { return [.zero] }
        var rng = SeededRandom(seed: UInt64(n) &* 0x9E3779B97F4A7C15 &+ UInt64(graph.edges.count))
        let k = Double(graph.domains.count)
        // Where each folder's gravity well sits: evenly spaced on a ring.
        func anchor(_ domain: Int) -> (Double, Double) {
            guard domain >= 0, k > 0 else { return (0, 0) }
            let a = 2 * Double.pi * Double(domain) / k - Double.pi / 2
            return (0.55 * cos(a), 0.55 * sin(a))
        }
        var x = [Double](repeating: 0, count: n), y = x, vx = x, vy = x
        for i in 0..<n {
            let (ax, ay) = anchor(graph.nodes[i].domainIndex)
            x[i] = ax + (rng.next() - 0.5) * 0.5; y[i] = ay + (rng.next() - 0.5) * 0.5
        }
        let ideal = max(0.12, 0.9 / Double(n).squareRoot())
        for step in 0..<iterations {
            let cooling = 1 - Double(step) / Double(iterations)
            var fx = [Double](repeating: 0, count: n), fy = fx
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var dx = x[i] - x[j], dy = y[i] - y[j]
                    var d2 = dx * dx + dy * dy
                    if d2 < 1e-6 { dx = (rng.next() - 0.5) * 1e-2; dy = (rng.next() - 0.5) * 1e-2; d2 = dx * dx + dy * dy + 1e-6 }
                    let f = (ideal * ideal) / d2 * 0.02
                    fx[i] += dx * f; fy[i] += dy * f; fx[j] -= dx * f; fy[j] -= dy * f
                }
            }
            for (a, b) in graph.edges {
                let dx = x[b] - x[a], dy = y[b] - y[a]
                let d = max((dx * dx + dy * dy).squareRoot(), 1e-4)
                let f = (d - ideal) * 0.35 / d
                fx[a] += dx * f; fy[a] += dy * f; fx[b] -= dx * f; fy[b] -= dy * f
            }
            for i in 0..<n {
                let (ax, ay) = anchor(graph.nodes[i].domainIndex)
                let pull = graph.nodes[i].domainIndex < 0 ? 0.9 : 0.35   // the overview sits in the middle
                fx[i] += (ax - x[i]) * pull * 0.2; fy[i] += (ay - y[i]) * pull * 0.2
                vx[i] = (vx[i] + fx[i]) * 0.6; vy[i] = (vy[i] + fy[i]) * 0.6
                let speed = (vx[i] * vx[i] + vy[i] * vy[i]).squareRoot(), cap = 0.06 * cooling + 0.002
                if speed > cap { vx[i] *= cap / speed; vy[i] *= cap / speed }
                x[i] += vx[i]; y[i] += vy[i]
            }
        }
        // Fit into [-1, 1] keeping the aspect ratio.
        let minX = x.min()!, maxX = x.max()!, minY = y.min()!, maxY = y.max()!
        let span = max(maxX - minX, maxY - minY, 1e-6)
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        return (0..<n).map { CGPoint(x: (x[$0] - cx) / span * 1.9, y: (y[$0] - cy) / span * 1.9) }
    }

    struct SeededRandom {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x1234_5678 : seed }
        mutating func next() -> Double {   // xorshift64*
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return Double((state &* 0x2545F4914F6CDD1D) >> 11) / Double(1 << 53)
        }
    }
}

/// The constellation: stars sized by how connected they are, shaded by folder, joined by faint
/// threads; pan, zoom, hover for a name, click to open.
public struct GraphView: View {
    let graph: KnowledgeGraph
    let points: [CGPoint]
    var selection: String?
    var onSelect: (String) -> Void
    @State private var hovered: Int?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var gesturePan: CGSize = .zero
    @GestureState private var gestureZoom: CGFloat = 1

    public init(graph: KnowledgeGraph, points: [CGPoint], selection: String? = nil, onSelect: @escaping (String) -> Void) {
        self.graph = graph; self.points = points; self.selection = selection; self.onSelect = onSelect
    }

    /// One gray per folder (brightness is the only thing that tells them apart), all light enough to read on black.
    public static let palette: [Color] = [Color(hex: 0xD6D6D6), Color(hex: 0x9C9C9C), Color(hex: 0xEFEFEF), Color(hex: 0x7C7C7C), Color(hex: 0xBFBFBF), Color(hex: 0x8A8A8A), Color(hex: 0xE2E2E2)]
    static func color(_ n: KnowledgeGraph.Node) -> Color { n.domainIndex < 0 ? .white : palette[n.domainIndex % palette.count] }

    public var body: some View {
        GeometryReader { geo in
            let transform = Transform(size: geo.size, zoom: zoom * gestureZoom, pan: CGSize(width: pan.width + gesturePan.width, height: pan.height + gesturePan.height))
            MotionClock(minimumInterval: 1 / 24) { t in
                Canvas { ctx, size in
                    for (a, b) in graph.edges {
                        var p = Path(); p.move(to: transform.map(points[a])); p.addLine(to: transform.map(points[b]))
                        let hot = hovered == a || hovered == b
                        ctx.stroke(p, with: .color(.white.opacity(hot ? 0.5 : 0.13)), lineWidth: hot ? 1.2 : 0.7)
                    }
                    for (i, n) in graph.nodes.enumerated() {
                        let c = transform.map(points[i])
                        let r = 3.5 + min(9, Double(n.degree) * 0.9) + (n.domainIndex < 0 ? 5 : 0)
                        let twinkle = 0.82 + 0.18 * sin(t * 1.3 + Double(i) * 1.7)
                        let isSel = n.id == selection || hovered == i
                        let color = Self.color(n)
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 2.6, y: c.y - r * 2.6, width: r * 5.2, height: r * 5.2)),
                                 with: .radialGradient(Gradient(colors: [color.opacity(0.45 * twinkle), .clear]), center: c, startRadius: 0, endRadius: r * 2.6))
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color.opacity(isSel ? 1 : 0.9 * twinkle)))
                        if isSel { ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r - 3, y: c.y - r - 3, width: r * 2 + 6, height: r * 2 + 6)), with: .color(.white.opacity(0.8)), lineWidth: 1.2) }
                        if isSel || (n.degree >= 4 && transform.zoom > 0.9) {
                            ctx.draw(Text(n.title).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(isSel ? 1 : 0.65)), at: CGPoint(x: c.x, y: c.y + r + 10))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = nearest(to: p, transform: transform)
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { if let i = nearest(to: $0.location, transform: transform) { onSelect(graph.nodes[i].id) } })
            .gesture(DragGesture().updating($gesturePan) { v, s, _ in s = v.translation }.onEnded { pan.width += $0.translation.width; pan.height += $0.translation.height })
            .gesture(MagnifyGesture().updating($gestureZoom) { v, s, _ in s = v.magnification }.onEnded { zoom = min(4, max(0.4, zoom * $0.magnification)) })
        }
        .accessibilityLabel("Knowledge graph with \(graph.nodes.count) notes")
    }

    private func nearest(to point: CGPoint, transform: Transform) -> Int? {
        var best: (Int, CGFloat)?
        for i in graph.nodes.indices {
            let c = transform.map(points[i]), d = hypot(c.x - point.x, c.y - point.y)
            if d < 18, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    struct Transform {
        let size: CGSize, zoom: CGFloat, pan: CGSize
        func map(_ p: CGPoint) -> CGPoint {
            let scale = min(size.width, size.height) / 2 * 0.86 * zoom
            return CGPoint(x: size.width / 2 + p.x * scale + pan.width, y: size.height / 2 + p.y * scale + pan.height)
        }
    }
}
