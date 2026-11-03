import CoreGraphics
import Foundation
import ImageIO

/// A picture worked out from the physics rather than drawn: a value at every point (|ψ|², a wave's height, a potential),
/// shaded by the app pixel by pixel; a field's flow, traced into lines (electric field lines, a phase portrait); and
/// curves x(t), y(t) (an orbit, a thrown ball's path). Muse gives the equations, in Plot's grammar, and the region they
/// hold over, y upward. The app computes every pixel and point, one unit the same size across and up, so nothing is
/// bent to fit the box.
nonisolated struct Computed: Codable, Equatable, Sendable {
    struct Curve: Codable, Equatable, Sendable {
        var x, y: String  // of t
        var tMin, tMax: Double
    }

    var field = ""  // of x and y
    var u = "", v = ""  // the flow at x, y
    var curves: [Curve] = []
    var labels: [Drawing.Label] = []  // x, y in the region's units: the label's centre
    var xMin = 0.0, xMax = 0.0, yMin = 0.0, yMax = 0.0

    var empty: Bool { field.isEmpty && u.isEmpty && curves.isEmpty }

    static let longSide = 640.0  // calibration knob: pixels on a picture's long side
    static let seeds = 16.0  // calibration knob: flow lines across the box's long side, at most
    static let paper: SIMD3<Double> = [0xFB, 0xFB, 0xFA], blue: SIMD3<Double> = [0x1F, 0x45, 0x96], coral: SIMD3<Double> = [0xD9, 0x48, 0x1C]

    /// Box points per unit, and the unit point at the box's centre: the whole region shows, however the box is shaped.
    func frame(_ size: CGSize) throws -> (scale: Double, middle: SIMD2<Double>) {
        guard [xMin, xMax, yMin, yMax].allSatisfy({ $0.isFinite && abs($0) <= 1e12 }), xMax > xMin, yMax > yMin, size.width > 0, size.height > 0 else {
            throw Plot.Failure("Invalid region")
        }
        return (min(size.width / (xMax - xMin), size.height / (yMax - yMin)), SIMD2((xMin + xMax) / 2, (yMin + yMax) / 2))
    }

    /// The field shaded into an opaque PNG for a box of `size`: from paper to Maple's blue, or from coral through paper to
    /// blue when it swings both ways about zero. The top and bottom 0.1% are clipped, so a singularity doesn't wash out the rest.
    func raster(in size: CGSize) throws -> Data {
        let (scale, middle) = try frame(size), f = try Plot.expression(field, variables: ["x", "y"])
        let density = min(2, Self.longSide / max(size.width, size.height)), width = max(Int(size.width * density), 1), height = max(Int(size.height * density), 1)
        var values = [Double](repeating: .nan, count: width * height), at = [0.0, 0.0]
        for row in 0..<height {
            at[1] = middle.y - (Double(row) + 0.5 - Double(height) / 2) / density / scale
            for column in 0..<width {
                at[0] = middle.x + (Double(column) + 0.5 - Double(width) / 2) / density / scale
                values[row * width + column] = f(at)
            }
        }
        let finite = values.filter(\.isFinite).sorted()
        guard let first = finite.first, let last = finite.last, last > first else { throw Plot.Failure("The field is flat over this region") }
        let low = finite[finite.count / 1000], high = max(finite[finite.count * 999 / 1000], low + (last - first) * 1e-6)
        guard high > low, high.isFinite, (high - low).isFinite else { throw Plot.Failure("The field's range can't be shaded") }
        let swings = low < 0 && high > 0 && min(-low, high) > 0.15 * max(-low, high), reach = max(-low, high)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in values.indices {
            let value = values[i].isNaN ? high : values[i]  // a singularity reads as the field's peak
            let colour: SIMD3<Double>
            if swings {
                let t = min(max(value / reach, -1), 1)
                colour = t < 0 ? Self.paper + (Self.coral - Self.paper) * pow(-t, 0.7) : Self.paper + (Self.blue - Self.paper) * pow(t, 0.7)
            } else {
                colour = Self.paper + (Self.blue - Self.paper) * pow(min(max((value - low) / (high - low), 0), 1), 0.6)
            }
            (pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2]) = (UInt8(colour.x), UInt8(colour.y), UInt8(colour.z))
        }
        let out = NSMutableData()
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let image = context.makeImage(),
              let file = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { throw Plot.Failure("Couldn't make the picture") }
        CGImageDestinationAddImage(file, image, nil)
        guard CGImageDestinationFinalize(file) else { throw Plot.Failure("Couldn't make the picture") }
        return out as Data
    }

    /// The flow's lines, its curves and its labels, in a box of `size`.
    func lines(in size: CGSize, font: Hershey) throws -> [[CGPoint]] {
        guard !empty else { throw Plot.Failure("Nothing to compute") }
        let (scale, middle) = try frame(size)
        func place(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: size.width / 2 + (p.x - middle.x) * scale, y: size.height / 2 - (p.y - middle.y) * scale) }
        let box = CGRect(origin: .zero, size: size)
        if !field.isEmpty { _ = try Plot.expression(field, variables: ["x", "y"]) }
        var out = u.isEmpty ? [] : try flow(in: size, scale: scale, middle: middle)
        for curve in curves.prefix(16) {
            let x = try Plot.expression(curve.x, variables: ["t"]), y = try Plot.expression(curve.y, variables: ["t"])
            guard curve.tMin.isFinite, curve.tMax.isFinite, curve.tMax > curve.tMin else { throw Plot.Failure("Invalid range of t") }
            var line: [CGPoint] = []
            for n in 0...600 {
                let t = curve.tMin + (curve.tMax - curve.tMin) * Double(n) / 600, a = x([t]), b = y([t]), p = place(SIMD2(a, b))
                if a.isFinite, b.isFinite, box.contains(p) { line.append(p) } else {
                    if line.count > 1 { out.append(line) }
                    line = []
                }
            }
            if line.count > 1 { out.append(line) }
        }
        for label in labels.prefix(32) where [label.x, label.y, label.size].allSatisfy(\.isFinite) {
            let text = String(label.text.prefix(80)), height = min(max(label.size, 4), 48), at = place(SIMD2(label.x, label.y))
            out += font.lines(text, at: CGPoint(x: at.x - font.width(text, height: height) / 2, y: at.y - height / 2), height: height)
        }
        return out
    }

    /// Lines along the flow, traced both ways from a grid of seeds with fourth-order Runge–Kutta, kept apart by a coarse
    /// grid of cells they've passed through, each with an arrowhead at its middle.
    func flow(in size: CGSize, scale: Double, middle: SIMD2<Double>) throws -> [[CGPoint]] {
        let fu = try Plot.expression(u, variables: ["x", "y"]), fv = try Plot.expression(v, variables: ["x", "y"])
        func direction(_ p: SIMD2<Double>) -> SIMD2<Double>? {
            let d = SIMD2(fu([p.x, p.y]), fv([p.x, p.y])), n = (d * d).sum().squareRoot()
            return n.isFinite && n > 1e-12 ? d / n : nil
        }
        func place(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: size.width / 2 + (p.x - middle.x) * scale, y: size.height / 2 - (p.y - middle.y) * scale) }
        let spacing = max(size.width, size.height) / Self.seeds, cell = spacing / 2, step = 1.5 / scale, box = CGRect(origin: .zero, size: size)
        func key(_ p: CGPoint) -> Int { Int(p.x / cell) * 100_000 + Int(p.y / cell) }
        var taken: Set<Int> = [], out: [[CGPoint]] = [], seeds: [SIMD2<Double>] = []
        for row in 0..<Int(size.height / spacing) + 1 {
            for column in 0..<Int(size.width / spacing) + 1 {
                seeds.append(middle + SIMD2((Double(column) + 0.5) * spacing - size.width / 2, size.height / 2 - (Double(row) + 0.5) * spacing) / scale)
            }
        }
        for seed in seeds where out.count < 96 && !taken.contains(key(place(seed))) {
            var traced: [[SIMD2<Double>]] = []
            for sign in [1.0, -1.0] {
                var p = seed, path: [SIMD2<Double>] = []
                for _ in 0..<1500 {
                    guard let k1 = direction(p), let k2 = direction(p + k1 * step / 2 * sign), let k3 = direction(p + k2 * step / 2 * sign),
                          let k4 = direction(p + k3 * step * sign) else { break }
                    p += (k1 + 2 * k2 + 2 * k3 + k4) / 6 * step * sign
                    let spot = place(p)
                    guard box.contains(spot), !taken.contains(key(spot)) else { break }
                    path.append(p)
                    if path.count > 40, (p - seed).max() < step, (seed - p).max() < step { break }  // it came round
                }
                traced.append(path)
            }
            let path = traced[1].reversed() + [seed] + traced[0]
            guard path.count >= 12 else { continue }
            let line = path.map(place)
            taken.formUnion(line.map(key))
            out.append(line)
            let mid = line[line.count / 2], before = line[line.count / 2 - 4], along = CGPoint(x: mid.x - before.x, y: mid.y - before.y), n = max(hypot(along.x, along.y), 0.001)
            let dx = along.x / n * 5, dy = along.y / n * 5
            out.append([CGPoint(x: mid.x - dx + dy * 0.5, y: mid.y - dy - dx * 0.5), mid, CGPoint(x: mid.x - dx - dy * 0.5, y: mid.y - dy + dx * 0.5)])
        }
        return out
    }
}
