// Traces Kalam's glyphs into pen strokes for Maple Hand (Maple/hand.json): render each glyph large, thin it to its
// centreline (Zhang–Suen), follow the centreline into polylines, prune spurs, smooth, simplify, and write them in Hershey
// units (capitals from y -12 to the baseline at 9).
//   swiftc -O tools/trace-hand.swift -o /tmp/trace-hand && /tmp/trace-hand Maple/Kalam-Regular.ttf Maple/hand.json
import CoreGraphics
import CoreText
import Foundation

let args = CommandLine.arguments
let data = try Data(contentsOf: URL(fileURLWithPath: args[1])) as CFData
let cgFont = CGFont(CGDataProvider(data: data)!)!
let font = CTFontCreateWithGraphicsFont(cgFont, 1000, nil, nil)
// The font's own metrics can miss its capitals (Kalam's stand a little above its baseline), so measure an H: its foot is
// the baseline and its top the cap height.
let (foot, cap): (CGFloat, CGFloat) = {
    var h = UniChar(72), g = CGGlyph()
    CTFontGetGlyphsForCharacters(font, &h, &g, 1)
    let box = CTFontCreatePathForGlyph(font, g, nil)!.boundingBoxOfPath
    return (box.minY, box.maxY - box.minY)
}()
let k = 21 / cap  // font units to Hershey units
let px: CGFloat = 320 / cap  // font units to raster pixels: capitals 320 px tall

struct P: Hashable { var x, y: Int }

func raster(_ path: CGPath) -> (grid: [[Bool]], ox: CGFloat, oy: CGFloat)? {
    let box = path.boundingBoxOfPath
    guard !box.isNull, box.width > 0 || box.height > 0 else { return nil }
    let pad: CGFloat = 8
    let w = Int((box.width * px).rounded(.up) + 2 * pad), h = Int((box.height * px).rounded(.up) + 2 * pad)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.translateBy(x: pad - box.minX * px, y: pad - box.minY * px)
    ctx.scaleBy(x: px, y: px)
    ctx.addPath(path)
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fillPath()
    let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var grid = Array(repeating: Array(repeating: false, count: w), count: h)
    for y in 0..<h { for x in 0..<w { grid[y][x] = bytes[y * w + x] > 127 } }  // bitmap memory starts at the top row
    // Font units of pixel (x, row): x / px + box.minX - pad / px; y = (h - 1 - row) / px + box.minY - pad / px
    return (grid, box.minX - pad / px, box.minY - pad / px)
}

func thin(_ g: inout [[Bool]]) {
    let h = g.count, w = g[0].count
    func n(_ y: Int, _ x: Int) -> [Bool] {  // P2..P9 clockwise from north
        [g[y-1][x], g[y-1][x+1], g[y][x+1], g[y+1][x+1], g[y+1][x], g[y+1][x-1], g[y][x-1], g[y-1][x-1]]
    }
    var changed = true
    while changed {
        changed = false
        for step in 0..<2 {
            var kill: [P] = []
            for y in 1..<(h - 1) { for x in 1..<(w - 1) where g[y][x] {
                let p = n(y, x), b = p.filter { $0 }.count
                guard (2...6).contains(b) else { continue }
                let a = (0..<8).filter { !p[$0] && p[($0 + 1) % 8] }.count
                guard a == 1 else { continue }
                if step == 0 { guard !(p[0] && p[2] && p[4]), !(p[2] && p[4] && p[6]) else { continue } }
                else { guard !(p[0] && p[2] && p[6]), !(p[0] && p[4] && p[6]) else { continue } }
                kill.append(P(x: x, y: y))
            } }
            for q in kill { g[q.y][q.x] = false }
            changed = changed || !kill.isEmpty
        }
    }
}

/// Mixed adjacency: a diagonal neighbour counts only when no side neighbour already links the two, so a staircase in
/// the skeleton is a line, not a run of junctions.
func neighbours(_ g: [[Bool]], _ p: P) -> [P] {
    func on(_ x: Int, _ y: Int) -> Bool { y >= 0 && y < g.count && x >= 0 && x < g[0].count && g[y][x] }
    var out: [P] = []
    for (dx, dy) in [(0, -1), (1, 0), (0, 1), (-1, 0)] where on(p.x + dx, p.y + dy) { out.append(P(x: p.x + dx, y: p.y + dy)) }
    for (dx, dy) in [(1, -1), (1, 1), (-1, 1), (-1, -1)] where on(p.x + dx, p.y + dy) && !on(p.x + dx, p.y) && !on(p.x, p.y + dy) {
        out.append(P(x: p.x + dx, y: p.y + dy))
    }
    return out
}

/// Follows the skeleton into paths that run between endpoints and junctions; closed loops come out as rings.
func trace(_ g: [[Bool]]) -> [[P]] {
    var pixels: [P] = []
    for y in 0..<g.count { for x in 0..<g[0].count where g[y][x] { pixels.append(P(x: x, y: y)) } }
    let degree = Dictionary(uniqueKeysWithValues: pixels.map { ($0, neighbours(g, $0).count) })
    struct E: Hashable { var a, b: P }
    var used = Set<E>()
    func mark(_ a: P, _ b: P) { used.insert(E(a: a, b: b)); used.insert(E(a: b, b: a)) }
    var paths: [[P]] = []
    func walk(_ start: P, _ first: P) -> [P] {
        var path = [start, first]
        mark(start, first)
        var current = first
        while degree[current] == 2 {
            guard let next = neighbours(g, current).first(where: { !used.contains(E(a: current, b: $0)) }) else { break }
            mark(current, next)
            path.append(next)
            current = next
        }
        return path
    }
    let nodes = pixels.filter { degree[$0] != 2 }
    for node in nodes { for q in neighbours(g, node) where !used.contains(E(a: node, b: q)) { paths.append(walk(node, q)) } }
    for p in pixels where degree[p] == 2 {  // rings with no node on them
        if let q = neighbours(g, p).first(where: { !used.contains(E(a: p, b: $0)) }) { paths.append(walk(p, q)) }
    }
    return paths
}

func length(_ path: [CGPoint]) -> CGFloat { zip(path, path.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } }

func simplify(_ pts: [CGPoint], _ eps: CGFloat) -> [CGPoint] {
    guard pts.count > 2 else { return pts }
    let a = pts.first!, b = pts.last!
    var best = 0, far: CGFloat = 0
    for i in 1..<(pts.count - 1) {
        let p = pts[i], dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
        let d = len < 1e-6 ? hypot(p.x - a.x, p.y - a.y) : abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len  // a loop: from its start
        if d > far { far = d; best = i }
    }
    return far > eps ? Array(simplify(Array(pts[...best]), eps).dropLast()) + simplify(Array(pts[best...]), eps) : [a, b]
}

func smooth(_ pts: [CGPoint]) -> [CGPoint] {
    guard pts.count > 4 else { return pts }
    var out = pts
    for _ in 0..<3 {
        let copy = out
        for i in 1..<(out.count - 1) { out[i] = CGPoint(x: (copy[i-1].x + 2 * copy[i].x + copy[i+1].x) / 4, y: (copy[i-1].y + 2 * copy[i].y + copy[i+1].y) / 4) }
    }
    return out
}

var glyphs: [String: [String: Any]] = [:]
var widths: [CGFloat] = []
for code in 32...126 {
    var ch = UniChar(code), glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1) else { continue }
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
    var lines: [[[Double]]] = []
    if let path = CTFontCreatePathForGlyph(font, glyph, nil), let shape = raster(path) {
        var grid = shape.grid
        let (ox, oy) = (shape.ox, shape.oy)
        let h = grid.count
        let ink = grid.joined().filter { $0 }.count
        thin(&grid)
        let skeleton = grid.joined().filter { $0 }.count
        let stroke = CGFloat(ink) / CGFloat(max(skeleton, 1))  // stroke width in pixels, roughly
        func unit(_ p: P) -> CGPoint {  // pixel → Hershey units
            let fx = CGFloat(p.x) / px + ox, fy = CGFloat(h - 1 - p.y) / px + oy
            return CGPoint(x: fx * k, y: 9 - (fy - foot) * k)
        }
        let traced = trace(grid)
        var paths = traced.map { $0.map(unit) }
        // Spurs: short branches off a junction, left by thinning round ends and corners. Under 1.2 strokes long it also
        // took the foot of Kalam's n, m and h stems, below where the arch leaves them; 0.9 keeps those and still drops spurs.
        let spur = stroke * 0.9 / px * k
        // Only a branch off a junction is a spur: a short stroke standing on its own (a tick, a dot) is ink.
        let ends = traced.flatMap { [$0.first!, $0.last!] }
        let attached = traced.map { path in [path.first!, path.last!].contains { end in ends.filter { $0 == end }.count > 1 } }
        paths = paths.indices.filter { length(paths[$0]) > spur || !attached[$0] }.map { paths[$0] }
        // Thinning eats half the stroke at each free end; give it back. A glyph that's only dots has almost no centreline, so
        // its estimate runs away: cap it at Kalam's usual stroke, 2.4 units.
        let half = min(stroke / 2 / px * k, 1.2)
        lines = paths.map { path -> [[Double]] in
            var pts = simplify(smooth(path), 0.06)
            if pts.count >= 2 {
                func extend(_ end: CGPoint, _ from: CGPoint) -> CGPoint {
                    let d = hypot(end.x - from.x, end.y - from.y)
                    return d > 0 ? CGPoint(x: end.x + (end.x - from.x) / d * half * 0.6, y: end.y + (end.y - from.y) / d * half * 0.6) : end
                }
                let closed = hypot(pts.first!.x - pts.last!.x, pts.first!.y - pts.last!.y) < half
                if !closed { pts[0] = extend(pts[0], pts[1]); pts[pts.count - 1] = extend(pts[pts.count - 1], pts[pts.count - 2]) }
            }
            return pts.map { [Double(($0.x * 100).rounded() / 100), Double(($0.y * 100).rounded() / 100)] }
        }.filter { $0.count > 1 }
        // A dot thins to a speck: write each piece of ink no line came from as a short dab at its middle.
        var seen = Set<P>(), dabs: [[[Double]]] = []
        for y in 0..<h { for x in 0..<grid[0].count where grid[y][x] && !seen.contains(P(x: x, y: y)) {
            var piece = [P(x: x, y: y)], i = 0
            seen.insert(piece[0])
            while i < piece.count {
                for dy in -1...1 { for dx in -1...1 {
                    let q = P(x: piece[i].x + dx, y: piece[i].y + dy)
                    if q.y >= 0, q.y < h, q.x >= 0, q.x < grid[0].count, grid[q.y][q.x], seen.insert(q).inserted { piece.append(q) }
                } }
                i += 1
            }
            let points = piece.map(unit), mid = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
            let covered = lines.contains { line in line.contains { hypot($0[0] - mid.x, $0[1] - mid.y) < Double(half * 3) } }
            let span = (points.map(\.x).max()! - points.map(\.x).min()!) + (points.map(\.y).max()! - points.map(\.y).min()!)
            if !covered, span < half * 4 {
                let r = half * 0.45  // a small ring: with the pen's width it fills to the dot's size
                dabs.append((0...6).map { i -> [Double] in
                    let a = Double(i) * .pi / 3
                    return [Double(mid.x) + Double(r) * cos(a), Double(mid.y) + Double(r) * sin(a)].map { ($0 * 100).rounded() / 100 }
                })
            }
        } }
        lines += dabs
        // A line no longer than the stroke is wide is a dot too: the ring, so it fills round and sits where the dot does.
        lines = lines.map { line in
            let xs = line.map { $0[0] }, ys = line.map { $0[1] }
            guard (xs.max()! - xs.min()!) + (ys.max()! - ys.min()!) < Double(half * 2.2), line.count < 7 else { return line }
            let mx = (xs.max()! + xs.min()!) / 2, my = (ys.max()! + ys.min()!) / 2, r = Double(half) * 0.45
            return (0...6).map { i in [mx + r * cos(Double(i) * .pi / 3), my + r * sin(Double(i) * .pi / 3)].map { ($0 * 100).rounded() / 100 } }
        }
        widths.append(stroke / px * k)
    }
    glyphs[String(UnicodeScalar(UInt8(code)))] = ["right": Double((advance.width * k * 100).rounded() / 100), "lines": lines]
}
let out: [String: Any] = ["name": "Maple Hand", "source": "Traced from Kalam by the Indian Type Foundry (SIL Open Font License 1.1); see Hand-LICENSE.txt",
                          "glyphs": glyphs]
try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]).write(to: URL(fileURLWithPath: args[2]))
let sorted = widths.sorted()
print("glyphs \(glyphs.count), stroke width median \(sorted[sorted.count / 2]) units (cap 21)")
