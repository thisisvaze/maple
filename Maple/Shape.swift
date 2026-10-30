import CoreGraphics
import Foundation

/// What a hand-drawn stroke was meant to be, as Procreate's QuickShape reads it: a line, an arc, an ellipse, or a polygon
/// open or closed. Pure geometry, so `checks/shape-check.swift` can run it on the Mac. Points are page points; `level` is
/// the angle the page lies at on screen, so right angles and fifteen-degree steps go by the screen, not the page.
nonisolated enum Shape: Equatable, Sendable {
    case line(CGPoint, CGPoint)
    case arc(center: CGPoint, radius: CGFloat, start: CGFloat, sweep: CGFloat)
    case ellipse(center: CGPoint, radii: CGSize, angle: CGFloat)
    case polygon([CGPoint], closed: Bool)

    // Calibration knobs: shares of the stroke's size, tuned on wobbly test strokes. Tighter leaves more strokes as drawn.
    static let samples = 128  // points a stroke is evened out to
    static let straightness: CGFloat = 0.07  // how far a line may stray from its chord
    static let closing: CGFloat = 0.22  // how near the ends come for the stroke to be closed
    static let cornerSharp: CGFloat = 0.06  // how far from the stroke's chord a point stands out as a corner
    static let flat: CGFloat = 28 * .pi / 180  // a turn gentler than this isn't a corner
    static let fit: CGFloat = 0.05  // how far on average the stroke may stray from a shape, and still be it
    static let rightAngle: CGFloat = 16 * .pi / 180  // how far a corner may be from square for a rectangle
    static let level: CGFloat = 7 * .pi / 180  // a rectangle this near the screen's axes lies along them
    static let round: CGFloat = 0.93  // an ellipse this near round is a circle
    static let step: CGFloat = .pi / 12  // fifteen degrees, Procreate's

    /// What `stroke` was meant to be, or nil when it doesn't clearly match a shape, as handwriting doesn't.
    static func recognize(_ stroke: [CGPoint], level: CGFloat = 0) -> Shape? {
        let points = even(stroke, count: samples), size = box(points), diagonal = hypot(size.width, size.height)
        guard points.count == samples, diagonal > 0 else { return nil }
        let (first, last) = (points[0], points[samples - 1]), chord = distance(first, last), length = Self.length(points)
        if chord > 0, length / chord < 1.15, points.map({ away($0, first, last) }).max()! <= straightness * chord { return .line(first, last) }
        if chord <= closing * diagonal, length > 2 * diagonal { return closed(points, diagonal, level) }
        return open(points, diagonal)
    }

    static func closed(_ points: [CGPoint], _ diagonal: CGFloat, _ level: CGFloat) -> Shape? {
        var corners = Self.corners(points + [points[0]], tolerance: cornerSharp * diagonal, closed: true)
        let round = ellipse(points), roundly = stray(points, from: round) / diagonal
        var polygon = corners + (corners.first.map { [$0] } ?? [])
        let straightly = corners.count >= 3 ? meanDistance(points, polygon) / diagonal : .infinity
        if corners.count == 4, straightly < roundly || straightly < fit / 2, let rectangle = rectangle(corners, level: level) {
            corners = rectangle
            polygon = corners + [corners[0]]
        }
        if (3...8).contains(corners.count), straightly < roundly, straightly <= fit { return .polygon(corners, closed: true) }
        return roundly <= fit ? round : nil
    }

    /// An open stroke is whichever of a polyline and an arc fits it better, if either fits it well.
    static func open(_ points: [CGPoint], _ diagonal: CGFloat) -> Shape? {
        let corners = Self.corners(points, tolerance: cornerSharp * diagonal, closed: false)
        let straightly = (3...9).contains(corners.count) ? meanDistance(points, corners) / diagonal : .infinity
        var curved = CGFloat.infinity, arc: Shape?
        if let circle = circle(points) {
            let start = atan2(points[0].y - circle.center.y, points[0].x - circle.center.x)
            var sweep: CGFloat = 0, previous = start
            for point in points.dropFirst() {
                let angle = atan2(point.y - circle.center.y, point.x - circle.center.x)
                sweep += (angle - previous).remainder(dividingBy: 2 * .pi)
                previous = angle
            }
            let off = points.reduce(CGFloat(0)) { $0 + abs(distance($1, circle.center) - circle.radius) } / CGFloat(points.count)
            if abs(sweep) > .pi / 6, off <= fit * circle.radius {
                curved = off / diagonal
                arc = .arc(center: circle.center, radius: circle.radius, start: start, sweep: sweep)
            }
        }
        // Each side has to be straight for its own length, which a wave isn't, and loopy writing runs far longer than a zigzag.
        let side = length(corners) / CGFloat(max(corners.count - 1, 1))
        if straightly * diagonal <= fit * side, straightly < curved, length(points) <= length(corners) * 1.12 { return .polygon(corners, closed: false) }
        return arc
    }

    /// `stroke` as `count` points evenly spaced along it.
    static func even(_ stroke: [CGPoint], count: Int) -> [CGPoint] {
        let total = length(stroke)
        guard stroke.count > 1, total > 0 else { return [] }
        var out = [stroke[0]], walked: CGFloat = 0, next = total / CGFloat(count - 1)
        for (a, b) in zip(stroke, stroke.dropFirst()) {
            let span = distance(a, b)
            while span > 0, walked + span >= next, out.count < count - 1 {
                let t = (next - walked) / span
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                next += total / CGFloat(count - 1)
            }
            walked += span
        }
        return out + [stroke[stroke.count - 1]]
    }

    /// The stroke's corners by Ramer–Douglas–Peucker, in order, without the ones it barely turns at. A closed stroke's
    /// `points` end where they began, and that seam isn't a corner unless the stroke turns there.
    static func corners(_ points: [CGPoint], tolerance: CGFloat, closed: Bool) -> [CGPoint] {
        var kept = [0, points.count - 1]
        if closed, let far = points.indices.max(by: { distance(points[$0], points[0]) < distance(points[$1], points[0]) }) { kept = [0, far, points.count - 1] }
        func split(_ a: Int, _ b: Int) {
            guard b > a + 1, let i = ((a + 1)..<b).max(by: { away(points[$0], points[a], points[b]) < away(points[$1], points[a], points[b]) }),
                  away(points[i], points[a], points[b]) > tolerance else { return }
            kept.append(i)
            split(a, i)
            split(i, b)
        }
        let seeds = kept.sorted()
        for (a, b) in zip(seeds, seeds.dropFirst()) { split(a, b) }
        var out = kept.sorted().map { points[$0] }
        if closed { out.removeLast() }
        var changed = true
        while changed, out.count > 2 {
            changed = false
            for i in out.indices where closed || (i > 0 && i < out.count - 1) {
                let a = out[(i + out.count - 1) % out.count], b = out[i], c = out[(i + 1) % out.count]
                if turn(a, b, c) < flat {
                    out.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return out
    }

    /// The ellipse along the stroke's principal axis, reaching as far as the stroke does each way.
    static func ellipse(_ points: [CGPoint]) -> Shape {
        let n = CGFloat(points.count), mx = points.reduce(0) { $0 + $1.x } / n, my = points.reduce(0) { $0 + $1.y } / n
        let xx = points.reduce(0) { $0 + ($1.x - mx) * ($1.x - mx) }, yy = points.reduce(0) { $0 + ($1.y - my) * ($1.y - my) }
        let xy = points.reduce(0) { $0 + ($1.x - mx) * ($1.y - my) }, angle = atan2(2 * xy, xx - yy) / 2
        let frame = points.map { $0.applying(CGAffineTransform(rotationAngle: -angle)) }, spread = box(frame)
        var radii = CGSize(width: spread.width / 2, height: spread.height / 2)
        if min(radii.width, radii.height) >= Self.round * max(radii.width, radii.height) {
            let r = (radii.width + radii.height) / 2
            radii = CGSize(width: r, height: r)
        }
        let center = CGPoint(x: spread.midX, y: spread.midY).applying(CGAffineTransform(rotationAngle: angle))
        return .ellipse(center: center, radii: radii, angle: radii.width == radii.height ? 0 : angle)
    }

    /// How far on average `points` lie from an ellipse.
    static func stray(_ points: [CGPoint], from shape: Shape) -> CGFloat {
        guard case let .ellipse(center, radii, angle) = shape, radii.width > 0, radii.height > 0 else { return .infinity }
        let to = CGAffineTransform(rotationAngle: -angle)
        return points.reduce(CGFloat(0)) { sum, point in
            let p = CGPoint(x: point.x - center.x, y: point.y - center.y).applying(to)
            let r = hypot(p.x / radii.width, p.y / radii.height)
            return sum + (r > 0 ? abs(r - 1) * hypot(p.x, p.y) / r : 0)
        } / CGFloat(points.count)
    }

    /// The rectangle four corners were meant to be, level with the screen if it's nearly so. Nil if they aren't square.
    static func rectangle(_ corners: [CGPoint], level: CGFloat) -> [CGPoint]? {
        let n = corners.count
        guard n == 4, corners.indices.allSatisfy({ abs(turn(corners[($0 + n - 1) % n], corners[$0], corners[($0 + 1) % n]) - .pi / 2) <= rightAngle }) else { return nil }
        // The sides' common direction, each read four-fold so that sides at right angles agree.
        var x: CGFloat = 0, y: CGFloat = 0
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % n], angle = atan2(b.y - a.y, b.x - a.x), weight = distance(a, b)
            x += cos(4 * angle) * weight
            y += sin(4 * angle) * weight
        }
        var angle = atan2(y, x) / 4
        let screen = ((angle + level) / (.pi / 2)).rounded() * .pi / 2 - level
        if abs(angle - screen) <= Self.level { angle = screen }
        let to = CGAffineTransform(rotationAngle: -angle), back = CGAffineTransform(rotationAngle: angle), spread = box(corners.map { $0.applying(to) })
        return [CGPoint(x: spread.minX, y: spread.minY), CGPoint(x: spread.maxX, y: spread.minY), CGPoint(x: spread.maxX, y: spread.maxY), CGPoint(x: spread.minX, y: spread.maxY)].map { $0.applying(back) }
    }

    /// The circle nearest `points`, by Kåsa's least squares.
    static func circle(_ points: [CGPoint]) -> (center: CGPoint, radius: CGFloat)? {
        var (a, b, c, d, e, f, g, h, i) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        for p in points {
            let z = p.x * p.x + p.y * p.y
            a += p.x * p.x; b += p.x * p.y; c += p.x; d += p.y * p.y; e += p.y; f += z * p.x; g += z * p.y; h += z; i += 1
        }
        let det = a * (d * i - e * e) - b * (b * i - e * c) + c * (b * e - d * c)
        guard abs(det) > 1e-6 else { return nil }
        let u = (f * (d * i - e * e) - b * (g * i - e * h) + c * (g * e - d * h)) / det
        let v = (a * (g * i - e * h) - f * (b * i - e * c) + c * (b * h - g * c)) / det
        let w = (a * (d * h - e * g) - b * (b * h - g * c) + f * (b * e - d * c)) / det
        let center = CGPoint(x: u / 2, y: v / 2), squared = w + center.x * center.x + center.y * center.y
        return squared > 0 ? (center, squared.squareRoot()) : nil
    }

    /// The point this turns and scales about: the middle of a closed shape, or the start of an open one.
    var pivot: CGPoint {
        switch self {
        case let .line(a, _): a
        case let .arc(center, radius, start, _): CGPoint(x: center.x + radius * cos(start), y: center.y + radius * sin(start))
        case let .ellipse(center, _, _): center
        case let .polygon(points, closed): closed ? Self.middle(points) : points[0]
        }
    }

    /// As the pen drags it from `hold` to `pen`: turned and scaled about its pivot, which is how a line's end follows the
    /// pen. `regular`, a finger down, is Procreate's: a circle, square or equilateral triangle, and the turn in fifteen
    /// degree steps by the screen.
    func dragged(from hold: CGPoint, to pen: CGPoint, regular: Bool, level: CGFloat) -> Shape {
        let base = regular ? regularized : self, pivot = base.pivot
        let reach = Self.distance(hold, pivot), far = Self.distance(pen, pivot)
        guard reach > 0, far > 0 else { return base }
        var angle = atan2(pen.y - pivot.y, pen.x - pivot.x)
        if regular { angle = ((angle + level) / Self.step).rounded() * Self.step - level }
        return base.turned(angle - atan2(hold.y - pivot.y, hold.x - pivot.x), scaled: far / reach, about: pivot)
    }

    /// The even form of a shape that has one.
    var regularized: Shape {
        switch self {
        case let .ellipse(center, radii, _):
            let r = (radii.width + radii.height) / 2
            return .ellipse(center: center, radii: CGSize(width: r, height: r), angle: 0)
        case let .polygon(points, true) where points.count == 3:
            let c = Self.middle(points), r = points.reduce(0) { $0 + Self.distance($1, c) } / 3
            let start = atan2(points[0].y - c.y, points[0].x - c.x), way: CGFloat = Self.length(points + [points[0]]) > 0 && Self.signedArea(points) < 0 ? -1 : 1
            return .polygon((0..<3).map { i in
                let a = start + way * CGFloat(i) * 2 * .pi / 3
                return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            }, closed: true)
        case let .polygon(points, true) where points.count == 4 && Self.rectangle(points, level: 0) != nil:
            let c = Self.middle(points), side = (Self.distance(points[0], points[1]) + Self.distance(points[1], points[2])) / 2
            let along = atan2(points[1].y - points[0].y, points[1].x - points[0].x), back = CGAffineTransform(rotationAngle: along)
            return .polygon([(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)].map { x, y in
                let p = CGPoint(x: x * side / 2, y: y * side / 2).applying(back)
                return CGPoint(x: c.x + p.x, y: c.y + p.y)
            }, closed: true)
        default: return self
        }
    }

    func turned(_ angle: CGFloat, scaled scale: CGFloat, about pivot: CGPoint) -> Shape {
        func move(_ p: CGPoint) -> CGPoint {
            let d = CGPoint(x: p.x - pivot.x, y: p.y - pivot.y).applying(CGAffineTransform(rotationAngle: angle))
            return CGPoint(x: pivot.x + d.x * scale, y: pivot.y + d.y * scale)
        }
        switch self {
        case let .line(a, b): return .line(move(a), move(b))
        case let .arc(center, radius, start, sweep): return .arc(center: move(center), radius: radius * scale, start: start + angle, sweep: sweep)
        case let .ellipse(center, radii, tilt): return .ellipse(center: move(center), radii: CGSize(width: radii.width * scale, height: radii.height * scale), angle: tilt + angle)
        case let .polygon(points, closed): return .polygon(points.map(move), closed: closed)
        }
    }

    /// The shape as one pen line. An ellipse and an arc get a point about every `spacing`, enough to look smooth.
    func outline(spacing: CGFloat) -> [CGPoint] {
        switch self {
        case let .line(a, b): return [a, b]
        case let .polygon(points, closed): return closed ? points + [points[0]] : points
        case let .arc(center, radius, start, sweep):
            let n = max(Int(abs(sweep) * radius / spacing), 24)
            return (0...n).map { i in
                let a = start + sweep * CGFloat(i) / CGFloat(n)
                return CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
            }
        case let .ellipse(center, radii, tilt):
            let n = max(Int(2 * .pi * max(radii.width, radii.height) / spacing), 48), frame = CGAffineTransform(rotationAngle: tilt)
            return (0...n).map { i in
                let a = 2 * .pi * CGFloat(i) / CGFloat(n), p = CGPoint(x: radii.width * cos(a), y: radii.height * sin(a)).applying(frame)
                return CGPoint(x: center.x + p.x, y: center.y + p.y)
            }
        }
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    static func length(_ points: [CGPoint]) -> CGFloat { zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) } }
    static func middle(_ points: [CGPoint]) -> CGPoint {
        CGPoint(x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count), y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count))
    }
    static func box(_ points: [CGPoint]) -> CGRect {
        points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
    }
    static func signedArea(_ points: [CGPoint]) -> CGFloat {
        points.indices.reduce(0) { sum, i in
            let a = points[i], b = points[(i + 1) % points.count]
            return sum + a.x * b.y - b.x * a.y
        } / 2
    }

    /// How far `p` is from the segment `a` to `b`.
    static func away(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, span = dx * dx + dy * dy
        guard span > 0 else { return distance(p, a) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / span, 0), 1)
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// How far on average `points` lie from the polyline `line`.
    static func meanDistance(_ points: [CGPoint], _ line: [CGPoint]) -> CGFloat {
        points.reduce(CGFloat(0)) { sum, p in sum + zip(line, line.dropFirst()).map { away(p, $0, $1) }.min()! } / CGFloat(points.count)
    }

    /// How sharply a path turns at `b`, from 0 for straight on to π for straight back.
    static func turn(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let one = atan2(b.y - a.y, b.x - a.x), two = atan2(c.y - b.y, c.x - b.x)
        return abs((two - one).remainder(dividingBy: 2 * .pi))
    }
}
