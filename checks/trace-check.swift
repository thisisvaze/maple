// Offline: Trace turns line art into a drawing's parts, from paintings drawn here.
//   swiftc -swift-version 6 -parse-as-library Maple/{Trace,Drawing,Figure,Computed,Hershey}.swift checks/trace-check.swift -o /tmp/trace-check && /tmp/trace-check
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct Check {
    static let palette: [String: SIMD3<Double>] = ["paper": [1, 1, 1], "yellow": [0xF7, 0xDC, 0x6E].map { Double($0) / 255 }.simd,
                                                   "green": [0x7F, 0xC4, 0x8E].map { Double($0) / 255 }.simd]

    /// A painting `size` pixels: paper, then `draw`.
    static func painting(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        let data = NSMutableData(), out = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(out, context.makeImage()!, nil)
        CGImageDestinationFinalize(out)
        return data as Data
    }

    static func box(_ points: [[Double]]) -> CGRect { points.reduce(CGRect.null) { $0.union(CGRect(x: $1[0], y: $1[1], width: 0, height: 0)) } }

    static func main() {
        // A yellow disc in a black ring, a rounded rectangle on its own (a loop with no ends), and a straight line.
        let art = painting(1024, 768) { c in
            c.setFillColor(CGColor(red: 0xF7 / 255, green: 0xDC / 255, blue: 0x6E / 255, alpha: 1))
            c.fillEllipse(in: CGRect(x: 100, y: 200, width: 400, height: 400))
            c.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            c.setLineWidth(12)
            c.strokeEllipse(in: CGRect(x: 100, y: 200, width: 400, height: 400))
            c.addPath(CGPath(roundedRect: CGRect(x: 600, y: 400, width: 320, height: 200), cornerWidth: 40, cornerHeight: 40, transform: nil))
            c.strokePath()
            c.move(to: CGPoint(x: 600, y: 200)); c.addLine(to: CGPoint(x: 920, y: 260)); c.strokePath()
        }
        let size = CGSize(width: 400, height: 300)
        guard let parts = Trace.parts(art, in: size, palette: palette) else { preconditionFailure("traced nothing") }
        let lines = parts[0], fills = parts.dropFirst()
        precondition(lines.name == "drawing" && lines.fill == nil && lines.role == nil, "the lines come first, drawn as lines")
        precondition((3...6).contains(lines.strokes.count), "one stroke a line, down its middle: \(lines.strokes.count) strokes")
        // The ring and the rounded rectangle are loops, closed and round, not folded to a dot.
        let loops = lines.strokes.filter { s in s.count > 8 && hypot(s[0][0] - s.last![0], s[0][1] - s.last![1]) < 2 }
        precondition(loops.count == 2 && loops.allSatisfy { box($0).width > 80 }, "two loops kept whole: \(loops.map { box($0) })")
        // The disc is the one fill: yellow, coloured in with no line of its own, inside the ring.
        precondition(fills.count == 1 && fills.first?.fill == "yellow" && fills.first?.role == "fill", "the disc's colour: \(fills.map { ($0.fill, $0.strokes.count) })")
        let ring = box(loops.max { box($0).height < box($1).height }!), disc = box(fills.first!.strokes[0])
        precondition(ring.insetBy(dx: -1, dy: -1).contains(disc) && disc.width > ring.width * 0.8, "the fill sits inside its ring: \(disc) in \(ring)")
        // Everything fits the box inside its 6% margins, at one scale across and up.
        let all = parts.flatMap(\.strokes).reduce(CGRect.null) { $0.union(box($1)) }
        let inner = CGRect(origin: .zero, size: size).insetBy(dx: size.width * Trace.margin - 1, dy: size.height * Trace.margin - 1)
        precondition(inner.contains(all), "inside the margins: \(all)")
        precondition(parts.flatMap(\.strokes).joined().allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) }, "points are x and y")

        // A blank painting, or one that isn't a picture, traces to nothing, so the drawing keeps the model's own strokes.
        precondition(Trace.parts(painting(64, 64) { _ in }, in: size, palette: palette) == nil, "blank")
        precondition(Trace.parts(Data([1, 2, 3]), in: size, palette: palette) == nil, "not a picture")

        // A busy painting stays within the drawing's budget of strokes and points.
        let busy = painting(1024, 1024) { c in
            c.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            c.setLineWidth(3)
            for i in 0..<300 {
                let x = Double(i % 20) * 50 + 10, y = Double(i / 20) * 65 + 10
                c.move(to: CGPoint(x: x, y: y)); c.addCurve(to: CGPoint(x: x + 30, y: y + 40), control1: CGPoint(x: x + 40, y: y), control2: CGPoint(x: x - 10, y: y + 30))
                c.strokePath()
            }
        }
        let crowded = Trace.parts(busy, in: size, palette: palette)!
        let strokes = crowded.flatMap(\.strokes)
        precondition(strokes.count <= Trace.mostStrokes + Trace.mostFills && strokes.joined().count <= Trace.mostPoints, "within budget: \(strokes.count) strokes, \(strokes.joined().count) points")
        print("trace ok: one stroke a line, loops kept whole, fills in their colour without outlines, inside the margins, blank and broken paintings, budget")
    }
}

extension Array where Element == Double { var simd: SIMD3<Double> { [self[0], self[1], self[2]] } }
