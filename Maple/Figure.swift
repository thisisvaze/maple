import CoreGraphics
import Foundation

/// A diagram whose angles and lengths have to be true. Muse gives each point's coordinates as expressions in real units,
/// y upward; the app works them out with Plot's grammar, scales the whole figure evenly into the box, and measures every
/// length and angle it labels from those points, so a label can't disagree with the ink. A stated length or angle the
/// points don't meet fails the figure.
nonisolated struct Figure: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable {
        var name, x, y: String  // later points can use earlier ones: B's coordinates are bx and by
        var label: Bool
    }

    struct Circle: Codable, Equatable, Sendable { var center, radius: String }
    struct Length: Codable, Equatable, Sendable { var from, to, expected, unit: String }
    struct Angle: Codable, Equatable, Sendable { var vertex, from, to, expected: String }  // degrees; expected may be empty

    var points: [Point] = []
    var lines: [[String]] = []  // each runs through named points
    var circles: [Circle] = []
    var lengths: [Length] = []
    var angles: [Angle] = []

    static let tolerance = 0.002  // calibration knob: how far a measure may miss what was stated, as a share of it

    typealias XY = SIMD2<Double>

    /// Every point, worked out in order. Throws for a name used twice, or that nothing defines.
    func solved() throws -> [String: XY] {
        guard (1...64).contains(points.count), lines.count <= 64, circles.count <= 16, lengths.count + angles.count <= 24 else { throw Plot.Failure("Too much in one figure") }
        var at: [String: XY] = [:], names: [String] = [], values: [Double] = []
        for point in points {
            let name = point.name.lowercased()
            guard !name.isEmpty, at[name] == nil else { throw Plot.Failure("Point \(point.name) is defined twice") }
            let x = try Plot.expression(point.x, variables: names)(values), y = try Plot.expression(point.y, variables: names)(values)
            guard x.isFinite, y.isFinite else { throw Plot.Failure("Point \(point.name) has no value") }
            at[name] = XY(x, y)
            names += [name + "x", name + "y"]
            values += [x, y]
        }
        return at
    }

    static func point(_ name: String, _ at: [String: XY]) throws -> XY {
        guard let p = at[name.lowercased()] else { throw Plot.Failure("There's no point \(name)") }
        return p
    }

    static func length(_ v: XY) -> Double { (v * v).sum().squareRoot() }

    /// The angle between the rays from `vertex` to `from` and `to`, in degrees, from 0 to 180.
    static func angle(_ a: Angle, _ at: [String: XY]) throws -> Double {
        let v = try point(a.vertex, at), p = try point(a.from, at) - v, q = try point(a.to, at) - v
        guard length(p) > 0, length(q) > 0 else { throw Plot.Failure("Angle at \(a.vertex) has no ray") }
        return abs(atan2(p.x * q.y - p.y * q.x, p.x * q.x + p.y * q.y)) * 180 / .pi
    }

    static func measure(_ l: Length, _ at: [String: XY]) throws -> Double { length(try point(l.to, at) - point(l.from, at)) }

    /// Throws, saying what's off, unless every stated length and angle is what the points measure.
    func check() throws {
        let at = try solved()
        func test(_ what: String, _ measured: Double, _ expected: String) throws {
            guard !expected.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let want = try Plot.expression(expected, variables: [])([])
            guard want.isFinite, abs(measured - want) <= Self.tolerance * max(abs(want), 1e-9) else {
                throw Plot.Failure("\(what) measures \(String(format: "%.4g", measured)), not \(String(format: "%.4g", want))")
            }
        }
        for l in lengths { try test("\(l.from)\(l.to)", try Self.measure(l, at), l.expected) }
        for a in angles { try test("The angle at \(a.vertex)", try Self.angle(a, at), a.expected) }
    }

    /// The figure's pen lines in a box of `size`, scaled evenly about its centre, with room left for labels.
    func lines(in size: CGSize, font: Hershey) throws -> [[CGPoint]] {
        try check()
        let at = try solved()
        var low = XY(repeating: .infinity), high = XY(repeating: -.infinity), rings: [(center: XY, radius: Double)] = []
        for circle in circles {
            let center = try Self.point(circle.center, at), radius = try Plot.expression(circle.radius, variables: [])([])
            guard radius.isFinite, radius > 0 else { throw Plot.Failure("A circle has no radius") }
            rings.append((center, radius))
            low = pointwiseMin(low, center - radius)
            high = pointwiseMax(high, center + radius)
        }
        for p in at.values {
            low = pointwiseMin(low, p)
            high = pointwiseMax(high, p)
        }
        let spread = high - low, margin = min(size.width, size.height) * 0.14
        guard spread.max() > 0 else { throw Plot.Failure("The figure has no size") }
        let scale = min(spread.x > 0 ? (size.width - 2 * margin) / spread.x : .infinity, spread.y > 0 ? (size.height - 2 * margin) / spread.y : .infinity)
        let middle = (low + high) / 2, centre = at.values.reduce(XY.zero, +) / Double(at.count)
        func place(_ p: XY) -> CGPoint { CGPoint(x: size.width / 2 + (p.x - middle.x) * scale, y: size.height / 2 - (p.y - middle.y) * scale) }
        let text = min(max(min(size.width, size.height) * 0.055, 6), 14)
        func away(_ p: XY, _ gap: Double) -> CGPoint {  // beside `p`, on the side away from the figure
            let d = p - centre, n = Self.length(d)
            return place(p + (n > 0 ? d / n : XY(0, 1)) * gap / scale)
        }
        var out: [[CGPoint]] = [], taken: [CGRect] = []
        // A label beside `p`, pushed further out until it clears the labels already written: collinear lengths, like a
        // wall and the units along it, share a side and nearly a midpoint.
        // ponytail: stacks clashing labels outward without leader lines; add leaders if stacked labels get ambiguous.
        func label(_ words: String, beside p: XY, gap: Double, degree: Bool) -> [[CGPoint]] {
            var gap = gap, at = away(p, gap)
            for _ in 0..<4 {
                let width = font.width(words, height: text) + (degree ? text * 0.6 : 0)
                let room = CGRect(x: at.x - width / 2, y: at.y - text / 2, width: width, height: text).insetBy(dx: -text * 0.25, dy: -text * 0.2)
                if !taken.contains(where: { $0.intersects(room) }) { taken.append(room); break }
                gap += text * 1.35
                at = away(p, gap)
            }
            return Self.write(words, at: at, height: text, degree: degree, font: font)
        }
        for line in lines.prefix(64) where line.count > 1 {
            for (a, b) in zip(line, line.dropFirst()) { out.append([place(try Self.point(a, at)), place(try Self.point(b, at))]) }
        }
        for ring in rings {
            out.append((0...180).map { place(ring.center + ring.radius * XY(cos(Double($0) * .pi / 90), sin(Double($0) * .pi / 90))) })
        }
        for angle in angles {
            let v = try Self.point(angle.vertex, at), p = try Self.point(angle.from, at) - v, q = try Self.point(angle.to, at) - v
            let degrees = try Self.angle(angle, at), reach = min(max(min(Self.length(p), Self.length(q)) * scale * 0.24, text * 1.5), text * 3.5) / scale
            let start = atan2(p.y, p.x), turn = atan2(p.x * q.y - p.y * q.x, p.x * q.x + p.y * q.y)
            func ray(_ t: Double, _ r: Double) -> XY { v + r * XY(cos(start + t), sin(start + t)) }
            if abs(degrees - 90) < 0.05 {
                let u = p / Self.length(p) * reach * 0.7, w = q / Self.length(q) * reach * 0.7
                out.append([place(v + u), place(v + u + w), place(v + w)])
            } else {
                out.append((0...24).map { place(ray(turn * Double($0) / 24, reach)) })
            }
            let words = String(format: "%.4g", degrees), at = place(ray(turn / 2, reach + 1.3 * text / scale))
            let width = font.width(words, height: text) + text * 0.6
            taken.append(CGRect(x: at.x - width / 2, y: at.y - text / 2, width: width, height: text))
            out += Self.write(words, at: at, height: text, degree: true, font: font)
        }
        for length in lengths {
            let a = try Self.point(length.from, at), b = try Self.point(length.to, at)
            let words = [String(format: "%.4g", try Self.measure(length, at)), length.unit].filter { !$0.isEmpty }.joined(separator: " ")
            out += label(words, beside: (a + b) / 2, gap: text * 1.2, degree: false)
        }
        for point in points where point.label {
            out += label(point.name, beside: try Self.point(point.name, at), gap: text * 1.1, degree: false)
        }
        return out
    }

    /// `text` centred on `middle`, with a small ring after it for a degree sign, which the font lacks.
    static func write(_ text: String, at middle: CGPoint, height: CGFloat, degree: Bool, font: Hershey) -> [[CGPoint]] {
        let width = font.width(text, height: height), right = middle.x + width / 2, r = height * 0.16
        var out = font.lines(text, at: CGPoint(x: middle.x - width / 2, y: middle.y - height / 2), height: height)
        if degree {
            out.append((0...12).map { CGPoint(x: right + r * 1.6 + r * cos(Double($0) * .pi / 6), y: middle.y - height / 2 + r + r * sin(Double($0) * .pi / 6)) })
        }
        return out
    }
}
