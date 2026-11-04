import CoreGraphics
import Foundation
import ImageIO
import simd

/// Line art Muse Image painted, traced into what Maple's pencil draws: each black line once, down its middle, and the
/// flat colour between the lines as fills in Maple's coloured pencils. It takes the place of an ink drawing's freehand
/// strokes, so a map has its real coastline and a bicycle its real spokes.
nonisolated enum Trace {
    // Calibration knobs, tuned on six paintings of different kinds (4 Nov): a map, an apple, a bicycle, a cat, a
    // wireframe and a diagram.
    static let side = 512  // pixels a painting is traced at, along its longer side
    static let ink = 0.42  // luminance under which a pixel is line
    static let shortest = 6  // pixels a line needs to be kept
    static let smallestFill = 1.0 / 600  // of the picture, for a coloured region to be kept
    static let mostStrokes = 200, mostFills = 40, mostPoints = 9_000  // inside Drawing's own caps of 256 and 12000
    static let margin: CGFloat = 0.06  // of the box, on each side, as the drawing instructions keep

    /// The parts of a drawing for a box of `size`, in box points: one for the lines, smoothed along the pixels they were
    /// traced from and drawn without a hand's lifts at corners, then one for each coloured region, biggest first,
    /// coloured in without an outline of its own. `palette` is the fills by name, with "paper" for none.
    /// Nil when there's no line art to trace, as when the painting failed or came back blank.
    static func parts(_ painting: Data, in size: CGSize, palette: [String: SIMD3<Double>]) -> [Drawing.Part]? {
        guard let picture = Picture(painting), size.width > 0, size.height > 0 else { return nil }
        let w = picture.w, h = picture.h
        let dark = picture.rgb.map { 0.299 * $0.x + 0.587 * $0.y + 0.114 * $0.z < ink }
        let raw = lines(skeleton(dark, w, h), w, h).sorted { $0.count > $1.count }.prefix(mostStrokes)  // big shapes first, as a hand sketches
        guard !raw.isEmpty else { return nil }
        let colours = ["paper"] + palette.keys.filter { $0 != "paper" }.sorted()
        let regions = Array(fills(picture, lines: dark, colours: colours.map { palette[$0] ?? [1, 1, 1] }).sorted { $0.area > $1.area }.prefix(mostFills))
        // Fit into the box inside its margins, centred, at one scale across and up.
        let scale = min(size.width * (1 - 2 * margin) / CGFloat(w), size.height * (1 - 2 * margin) / CGFloat(h))
        let dx = (size.width - CGFloat(w) * scale) / 2, dy = (size.height - CGFloat(h) * scale) / 2
        func place(_ points: [CGPoint]) -> [[Double]] { points.map { [Double(dx + $0.x * scale), Double(dy + $0.y * scale)].map { ($0 * 10).rounded() / 10 } } }
        var tolerance: CGFloat = 0.9, strokes: [[CGPoint]] = []
        repeat {  // simplify harder until the points fit
            strokes = raw.map { smooth(simplify(averaged($0), tolerance)) }
            tolerance *= 1.6
        } while strokes.reduce(0, { $0 + $1.count }) + regions.reduce(0, { $0 + $1.outline.count }) > mostPoints && tolerance < 8
        return [Drawing.Part(name: "drawing", strokes: strokes.map(place), labels: [], role: "traced")]
            + regions.map { Drawing.Part(name: "\(colours[$0.colour]) area", strokes: [place($0.outline)], labels: [], fill: colours[$0.colour], role: "fill") }
    }

    /// The painting as colours, `side` pixels along its longer side.
    struct Picture {
        var w = 0, h = 0, rgb: [SIMD3<Double>] = []
        init?(_ data: Data) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width > 2, image.height > 2 else { return nil }
            let scale = Double(side) / Double(max(image.width, image.height))
            w = max(3, Int(Double(image.width) * scale)); h = max(3, Int(Double(image.height) * scale))
            var bytes = [UInt8](repeating: 255, count: w * h * 4)
            guard let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            rgb = (0..<(w * h)).map { i in SIMD3(Double(bytes[i * 4]), Double(bytes[i * 4 + 1]), Double(bytes[i * 4 + 2])) / 255 }
        }
    }

    /// The line pixels thinned to one pixel down their middles (Zhang–Suen), then a pass that drops any pixel whose
    /// neighbours stay joined without it, so corners don't leave little triangles that break a line in two.
    static func skeleton(_ mask: [Bool], _ w: Int, _ h: Int) -> [Bool] {
        var m = mask
        func at(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && m[y * w + x] }
        var changed = true
        while changed {
            changed = false
            for step in 0..<2 {
                var drop: [Int] = []
                for y in 1..<(h - 1) {
                    for x in 1..<(w - 1) where m[y * w + x] {
                        let p = [at(x, y - 1), at(x + 1, y - 1), at(x + 1, y), at(x + 1, y + 1), at(x, y + 1), at(x - 1, y + 1), at(x - 1, y), at(x - 1, y - 1)]
                        let neighbours = p.filter { $0 }.count, rises = (0..<8).filter { !p[$0] && p[($0 + 1) % 8] }.count
                        guard (2...6).contains(neighbours), rises == 1 else { continue }
                        let (n, e, s, west) = (p[0], p[2], p[4], p[6])
                        if step == 0 ? !(n && e && s) && !(e && s && west) : !(n && e && west) && !(n && s && west) { drop.append(y * w + x) }
                    }
                }
                drop.forEach { m[$0] = false }
                changed = changed || !drop.isEmpty
            }
        }
        let around = [(-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0)]
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) where m[y * w + x] {
                let n = around.filter { at(x + $0.0, y + $0.1) }
                guard n.count >= 2 else { continue }
                var joined = [0], queue = [0]
                while let k = queue.popLast() {
                    for j in n.indices where !joined.contains(j) && abs(n[j].0 - n[k].0) <= 1 && abs(n[j].1 - n[k].1) <= 1 { joined.append(j); queue.append(j) }
                }
                if joined.count == n.count { m[y * w + x] = false }
            }
        }
        return m
    }

    /// The skeleton as lines of pixels, broken at ends and where lines meet; a loop with neither is traced whole.
    static func lines(_ m: [Bool], _ w: Int, _ h: Int) -> [[CGPoint]] {
        let steps = [(0, -1), (1, 0), (0, 1), (-1, 0), (1, -1), (1, 1), (-1, 1), (-1, -1)]  // straight on before diagonal
        func neighbours(_ i: Int) -> [Int] {
            let x = i % w, y = i / w
            return steps.compactMap { dx, dy in
                let nx = x + dx, ny = y + dy
                return nx >= 0 && ny >= 0 && nx < w && ny < h && m[ny * w + nx] ? ny * w + nx : nil
            }
        }
        var used = Set<Int>(), walked = Set<[Int]>(), out: [[CGPoint]] = []
        func walk(from start: Int, to first: Int) -> [Int] {
            var path = [start, first], previous = start, current = first
            while neighbours(current).count == 2 {
                used.insert(current)
                guard let next = neighbours(current).first(where: { $0 != previous }), !used.contains(next) || neighbours(next).count != 2 else { break }
                if next == start { path.append(next); break }
                (previous, current) = (current, next)
                path.append(current)
            }
            used.insert(current)
            return path
        }
        let pixels = (0..<(w * h)).filter { m[$0] }
        for i in pixels where neighbours(i).count != 2 {
            for n in neighbours(i) where !walked.contains([i, n]) {
                let path = walk(from: i, to: n)
                walked.insert([i, n])
                walked.insert([path[path.count - 1], path[path.count - 2]])
                out.append(path.map { CGPoint(x: $0 % w, y: $0 / w) })
            }
        }
        for i in pixels where !used.contains(i) && neighbours(i).count == 2 {
            out.append(walk(from: i, to: neighbours(i)[0]).map { CGPoint(x: $0 % w, y: $0 / w) })
        }
        return out.filter { $0.count >= shortest }
    }

    /// Each region of one fill colour, a pixel clear of the lines, as its outline (holes ignored) and its area in
    /// pixels. `colours[0]` is the paper, which is never a region.
    static func fills(_ picture: Picture, lines: [Bool], colours: [SIMD3<Double>]) -> [(colour: Int, outline: [CGPoint], area: Int)] {
        let w = picture.w, h = picture.h, sides = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        var near = lines
        for y in 0..<h {
            for x in 0..<w where lines[y * w + x] {
                for (dx, dy) in sides where x + dx >= 0 && x + dx < w && y + dy >= 0 && y + dy < h { near[(y + dy) * w + x + dx] = true }
            }
        }
        let colour = (0..<(w * h)).map { i -> Int in
            near[i] ? -1 : colours.indices.min { simd_distance(colours[$0], picture.rgb[i]) < simd_distance(colours[$1], picture.rgb[i]) }!
        }
        var seen = [Bool](repeating: false, count: w * h), out: [(Int, [CGPoint], Int)] = []
        for start in 0..<(w * h) where !seen[start] && colour[start] > 0 {
            var stack = [start], region: [Int] = []
            seen[start] = true
            while let i = stack.popLast() {
                region.append(i)
                for (dx, dy) in sides {
                    let x = i % w + dx, y = i / w + dy, j = y * w + x
                    if x >= 0, y >= 0, x < w, y < h, !seen[j], colour[j] == colour[start] { seen[j] = true; stack.append(j) }
                }
            }
            guard Double(region.count) >= Double(w * h) * smallestFill else { continue }
            // Round its edge from its top-left pixel, each step trying the neighbours clockwise from behind the last.
            let inside = Set(region), first = region.min()!
            let ring = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
            var outline = [CGPoint(x: first % w, y: first / w)], current = first, heading = 6, steps = 0
            repeat {
                guard let d = (0..<8).lazy.map({ (heading + 6 + $0) % 8 }).first(where: { d in
                    let x = current % w + ring[d].0, y = current / w + ring[d].1
                    return x >= 0 && y >= 0 && x < w && y < h && inside.contains(y * w + x)
                }) else { break }
                current = (current / w + ring[d].1) * w + current % w + ring[d].0
                heading = d
                outline.append(CGPoint(x: current % w, y: current / w))
                steps += 1
            } while current != first && steps < 4 * (w + h) * 4
            out.append((colour[start], simplify(outline, 1.2), region.count))
        }
        return out
    }

    /// Ramer–Douglas–Peucker. A closed loop is split at its point farthest from where it starts first, since a line
    /// from a point to itself measures nothing and the loop would fold to a dot.
    static func simplify(_ p: [CGPoint], _ tolerance: CGFloat) -> [CGPoint] {
        guard p.count > 3, hypot(p[0].x - p.last!.x, p[0].y - p.last!.y) < 1.5 else { return open(p, tolerance) }
        let far = p.indices.max { hypot(p[$0].x - p[0].x, p[$0].y - p[0].y) < hypot(p[$1].x - p[0].x, p[$1].y - p[0].y) }!
        guard far > 0, far < p.count - 1 else { return p }
        return Array(open(Array(p[...far]), tolerance).dropLast()) + open(Array(p[far...]), tolerance)
    }

    static func open(_ p: [CGPoint], _ tolerance: CGFloat) -> [CGPoint] {
        guard p.count > 2, let a = p.first, let b = p.last else { return p }
        let dx = b.x - a.x, dy = b.y - a.y, length = max(hypot(dx, dy), 0.0001)
        var farthest = 0, distance: CGFloat = 0
        for i in 1..<(p.count - 1) {
            let d = abs(dy * p[i].x - dx * p[i].y + b.x * a.y - b.y * a.x) / length
            if d > distance { (farthest, distance) = (i, d) }
        }
        guard distance > tolerance else { return [a, b] }
        return Array(open(Array(p[...farthest]), tolerance).dropLast()) + open(Array(p[farthest...]), tolerance)
    }

    /// Each point the average of those up to `reach` either side of it, ends kept: a line of pixels steps in stairs, and
    /// this takes the steps out before the line is simplified.
    static func averaged(_ p: [CGPoint], reach: Int = 2) -> [CGPoint] {
        guard p.count > 2 * reach + 1 else { return p }
        return p.indices.map { i in
            guard i >= reach, i < p.count - reach else { return p[i] }
            let near = p[(i - reach)...(i + reach)]
            return CGPoint(x: near.map(\.x).reduce(0, +) / CGFloat(near.count), y: near.map(\.y).reduce(0, +) / CGFloat(near.count))
        }
    }

    /// One round of Chaikin's corner cutting, ends kept, so a traced line curves like a drawn one.
    static func smooth(_ p: [CGPoint]) -> [CGPoint] {
        guard p.count > 2 else { return p }
        var out = [p[0]]
        for (a, b) in zip(p, p.dropFirst()) {
            out += [CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y), CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y)]
        }
        return out + [p[p.count - 1]]
    }
}
