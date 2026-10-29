import PencilKit

/// The agent writes in real ink, so its drawings save, zoom, erase and undo like the person's. It uses the monoline ink
/// (people write with `.pen`), which is how its strokes are told apart and never read as marks.
enum AgentPen {
    static let ink = PKInk(.monoline, color: Marks.ink.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))  // PencilKit flips it in dark mode

    static func wrote(_ stroke: PKStroke) -> Bool { stroke.ink.inkType == .monoline }

    /// Point size for ink drawn into a box made at `zoom`. Monoline draws 2 pt thinner than its point size, and at 2 or
    /// less only a hairline that vanishes as the page zooms in (measured in the simulator, 27 Oct), so: 2 plus what shows.
    static func width(at zoom: CGFloat) -> CGFloat { 2 + 1.2 / zoom }  // calibration knob: about as heavy as the person's pen

    /// A stroke through `points`, filled in every `step` so PencilKit's spline smoothing keeps straight lines straight.
    static func stroke(_ points: [CGPoint], width: CGFloat, step: CGFloat) -> PKStroke {
        var dense = [points[0]]
        for (a, b) in zip(points, points.dropFirst()) {
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / step))
            dense += (1...n).map { i in
                let t = CGFloat(i) / CGFloat(n)
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
        }
        let size = CGSize(width: width, height: width)
        let samples = dense.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.002, size: size, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: samples, creationDate: Date()))
    }
}
