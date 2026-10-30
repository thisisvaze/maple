// swiftc -swift-version 6 -O -parse-as-library Maple/Shape.swift checks/shape-check.swift -o /tmp/shape-check && /tmp/shape-check
import CoreGraphics
import Foundation

@main
struct Check {
    /// A pen's wobble: smooth, drifting, seeded, so a failure repeats.
    struct Hand {
        var seed: UInt64
        mutating func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 33) & 0xFFFF) / 65535 * 2 - 1
        }
        mutating func wobble(_ points: [CGPoint], by amount: CGFloat) -> [CGPoint] {
            var dx: CGFloat = 0, dy: CGFloat = 0
            let a = next() * 6, b = next() * 6, f = 3 + next() * 2
            return points.enumerated().map { i, p in
                dx = dx * 0.85 + CGFloat(next()) * amount * 0.18
                dy = dy * 0.85 + CGFloat(next()) * amount * 0.18
                let t = Double(i) / Double(points.count), slow = CGFloat(sin(t * f * 2 * .pi + a)) * amount * 0.6, slower = CGFloat(cos(t * f * 2 * .pi + b)) * amount * 0.6
                return CGPoint(x: p.x + dx + slow, y: p.y + dy + slower)
            }
        }
    }

    static func path(_ corners: [CGPoint], each: Int = 30) -> [CGPoint] {
        zip(corners, corners.dropFirst()).flatMap { a, b in (0..<each).map { i in
            let t = CGFloat(i) / CGFloat(each)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        } } + [corners.last!]
    }
    static func turn(_ points: [CGPoint], _ a: CGFloat, about c: CGPoint = .zero) -> [CGPoint] {
        points.map { p in
            let d = CGPoint(x: p.x - c.x, y: p.y - c.y).applying(CGAffineTransform(rotationAngle: a))
            return CGPoint(x: c.x + d.x, y: c.y + d.y)
        }
    }
    static func oval(_ rx: CGFloat, _ ry: CGFloat, from: CGFloat = 0, sweep: CGFloat = 6.1, n: Int = 120) -> [CGPoint] {
        (0...n).map { i in
            let a = from + sweep * CGFloat(i) / CGFloat(n)
            return CGPoint(x: 400 + rx * cos(a), y: 300 + ry * sin(a))
        }
    }
    enum Kind: String { case line, arc, ellipse, circle, rectangle, triangle, quadrilateral, polyline, none }
    static func kind(_ s: Shape?) -> Kind {
        switch s {
        case .line: .line
        case .arc: .arc
        case let .ellipse(_, r, _): r.width == r.height ? .circle : .ellipse
        case let .polygon(p, true): p.count == 3 ? .triangle : p.count == 4 ? (Shape.rectangle(p, level: 0) != nil ? .rectangle : .quadrilateral) : .polyline
        case .polygon: .polyline
        case nil: .none
        }
    }

    static func main() {
        setbuf(stdout, nil)
        // Every way of drawing each shape, many hands, at many sizes and angles: how often is it read right?
        var hand = Hand(seed: 7)
        let cases: [(Kind, CGFloat, (CGFloat) -> [CGPoint])] = [
            (.line, 0.99, { s in path([CGPoint(x: 100, y: 100), CGPoint(x: 100 + 3 * s, y: 100 + s)]) }),
            (.circle, 0.97, { s in oval(s, s) }),
            (.ellipse, 0.97, { s in oval(1.7 * s, s) }),
            (.rectangle, 0.95, { s in path([CGPoint(x: 100, y: 100), CGPoint(x: 100 + 2 * s, y: 100), CGPoint(x: 100 + 2 * s, y: 100 + 1.2 * s), CGPoint(x: 100, y: 100 + 1.2 * s), CGPoint(x: 100, y: 100)]) }),
            (.rectangle, 0.95, { s in path([CGPoint(x: 100, y: 100), CGPoint(x: 100 + s, y: 100), CGPoint(x: 100 + s, y: 100 + s), CGPoint(x: 100, y: 100 + s), CGPoint(x: 100, y: 100)]) }),
            (.triangle, 0.95, { s in path([CGPoint(x: 100, y: 100), CGPoint(x: 100 + 2 * s, y: 100), CGPoint(x: 100 + s, y: 100 + 1.6 * s), CGPoint(x: 100, y: 100)]) }),
            (.quadrilateral, 0.9, { s in path([CGPoint(x: 100, y: 100), CGPoint(x: 100 + 2 * s, y: 100), CGPoint(x: 100 + 2.8 * s, y: 100 + 1.2 * s), CGPoint(x: 100 + 0.8 * s, y: 100 + 1.2 * s), CGPoint(x: 100, y: 100)]) }),
            (.polyline, 0.9, { s in path([CGPoint(x: 100, y: 100), CGPoint(x: 100 + s, y: 100 + 1.4 * s), CGPoint(x: 100 + 2 * s, y: 100), CGPoint(x: 100 + 3 * s, y: 100 + 1.4 * s)]) }),
            (.arc, 0.9, { s in oval(s, s, from: 0.3, sweep: 2.2) }),
        ]
        for (want, floor, draw) in cases {
            var right = 0, total = 0, seen: [Kind: Int] = [:]
            for size in [50.0, 90.0, 160.0, 300.0] as [CGFloat] {
                for angle in stride(from: 0.0, to: 6.2, by: 0.45) {
                    for _ in 0..<12 {
                        let stroke = hand.wobble(turn(draw(size), angle, about: CGPoint(x: 300, y: 300)), by: size * 0.018)
                        let got = kind(Shape.recognize(stroke))
                        seen[got, default: 0] += 1
                        total += 1
                        if got == want { right += 1 }
                    }
                }
            }
            let rate = Double(right) / Double(total)
            print(String(format: "%-14@ %.1f%%", want.rawValue as NSString, rate * 100), seen.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key.rawValue) \($0.value)" })
            precondition(rate >= floor, "\(want) read right only \(rate)")
        }

        // Handwriting and scribbles stay as they were written: a held pen must never mangle them.
        var left = 0, scribbles = 0
        for _ in 0..<400 {
            var p = CGPoint(x: 200, y: 200), angle = hand.next() * 6.28, stroke = [p]
            for i in 0..<160 {
                angle += hand.next() * 0.9 + sin(Double(i) / 6) * 0.55
                p = CGPoint(x: p.x + cos(angle) * 3, y: p.y + sin(angle) * 3)
                stroke.append(p)
            }
            scribbles += 1
            if Shape.recognize(stroke) == nil { left += 1 }
        }
        print("scribbles left alone: \(left) of \(scribbles)")
        precondition(Double(left) / Double(scribbles) >= 0.9, "scribbles left alone only \(left) of \(scribbles)")
        func word() -> [CGPoint] {  // joined-up loops, like cursive
            (0..<220).map { i in
                let t = Double(i) / 14
                return CGPoint(x: 100 + Double(i) * 1.3 + sin(t) * 9, y: 200 + cos(t) * 16 + sin(t * 0.37) * 5)
            }
        }
        precondition(Shape.recognize(word()) == nil, "joined-up writing isn't a shape: \(String(describing: Shape.recognize(word())))")

        // A rectangle comes out perfect: square corners, equal opposite sides; nearly level means level with the screen.
        guard case let .polygon(box, true)? = Shape.recognize(hand.wobble(path([CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 104), CGPoint(x: 398, y: 300), CGPoint(x: 102, y: 297), CGPoint(x: 100, y: 100)]), by: 2)), box.count == 4 else { preconditionFailure("a rectangle") }
        precondition(box.indices.allSatisfy { abs(box[$0].x - box[($0 + 1) % 4].x) < 1e-6 || abs(box[$0].y - box[($0 + 1) % 4].y) < 1e-6 }, "level, side by side: \(box)")
        // ... by the screen, on a turned page.
        let turned = turn(path([CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 104), CGPoint(x: 398, y: 300), CGPoint(x: 102, y: 297), CGPoint(x: 100, y: 100)]), -0.9)
        guard case let .polygon(tilted, true)? = Shape.recognize(turned, level: 0.9) else { preconditionFailure("a turned rectangle") }
        let side = atan2(tilted[1].y - tilted[0].y, tilted[1].x - tilted[0].x) + 0.9
        precondition(abs((side / (.pi / 2)) - (side / (.pi / 2)).rounded()) < 1e-6, "level on screen, though the page is turned: \(side)")

        // A line's end follows the pen. A finger down steps it every fifteen degrees, on screen.
        let line = Shape.line(.zero, CGPoint(x: 100, y: 0))
        guard case let .line(a, b) = line.dragged(from: CGPoint(x: 100, y: 0), to: CGPoint(x: 60, y: 80), regular: false, level: 0) else { preconditionFailure() }
        precondition(a == .zero && Shape.distance(b, CGPoint(x: 60, y: 80)) < 1e-6, "the end follows the pen")
        for level in [0, 0.9, -2.1] as [CGFloat] {
            for degrees in stride(from: -180.0, to: 180.0, by: 7.3) {
                let pen = CGPoint(x: 200 * cos(degrees * .pi / 180), y: 200 * sin(degrees * .pi / 180))
                guard case let .line(_, end) = line.dragged(from: CGPoint(x: 100, y: 0), to: pen, regular: true, level: level) else { preconditionFailure() }
                let on = (atan2(end.y, end.x) + level) * 180 / .pi
                precondition(abs(on / 15 - (on / 15).rounded()) < 1e-6, "fifteen-degree steps: \(on)")
                precondition(abs(hypot(end.x, end.y) - 200) < 1e-6, "as long as the pen reaches")
            }
        }

        // A finger makes it regular: an oval a circle, a rectangle a square, a triangle equilateral.
        guard case let .ellipse(_, r, _) = Shape.ellipse(center: CGPoint(x: 10, y: 10), radii: CGSize(width: 90, height: 50), angle: 0.4).regularized else { preconditionFailure() }
        precondition(r.width == r.height && r.width == 70, "a circle")
        let wide = Shape.polygon([CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 100), CGPoint(x: 0, y: 100)], closed: true)
        guard case let .polygon(square, true) = wide.regularized else { preconditionFailure() }
        let sides = square.indices.map { Shape.distance(square[$0], square[($0 + 1) % 4]) }
        precondition(sides.allSatisfy { abs($0 - 150) < 1e-6 }, "a square: \(sides)")
        precondition(Shape.polygon(square, closed: true).pivot.x == 100 && abs(Shape.polygon(square, closed: true).pivot.y - 50) < 1e-6, "about the same middle")
        guard case let .polygon(tri, true) = Shape.polygon([CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 10), CGPoint(x: 90, y: 120)], closed: true).regularized else { preconditionFailure() }
        let edges = tri.indices.map { Shape.distance(tri[$0], tri[($0 + 1) % 3]) }
        precondition(edges.allSatisfy { abs($0 - edges[0]) < 1e-6 }, "equilateral: \(edges)")

        // Closed shapes turn and scale about their middle as the pen drags, and outlines close.
        let circle = Shape.ellipse(center: CGPoint(x: 100, y: 100), radii: CGSize(width: 50, height: 50), angle: 0)
        guard case let .ellipse(c, grown, _) = circle.dragged(from: CGPoint(x: 150, y: 100), to: CGPoint(x: 200, y: 100), regular: false, level: 0) else { preconditionFailure() }
        precondition(c == CGPoint(x: 100, y: 100) && grown.width == 100, "grows about its middle")
        let ring = circle.outline(spacing: 2)
        precondition(Shape.distance(ring[0], ring[ring.count - 1]) < 1e-9 && ring.count > 100 && ring.allSatisfy { abs(Shape.distance($0, CGPoint(x: 100, y: 100)) - 50) < 1e-9 }, "a true circle")
        precondition(wide.outline(spacing: 2).count == 5, "a closed polygon comes back to its start")
        print("shape ok: reading strokes, leaving writing alone, perfect rectangles, fifteen-degree steps, regular forms")
    }
}
