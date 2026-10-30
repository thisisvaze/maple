import PencilKit

/// The agent writes in real ink, so its drawings save, zoom, erase and undo like the person's. Its strokes are told apart
/// by colour: PencilKit stores colours exactly, but turns .monoline ink into .pen when a page is saved and reopened
/// (probed on the iOS 26.5 simulator, 29 Oct), so the ink type can't be trusted.
enum AgentPen {
    /// The light-mode blue PencilKit stores. In dark mode PencilKit draws its own conversion, #698FE0: 5.4:1 on the dark
    /// paper, and 8.6:1 for this one on the light paper.
    static let blue = UIColor(red: 0x1F / 255, green: 0x45 / 255, blue: 0x96 / 255, alpha: 1)
    static let ink = PKInk(.monoline, color: blue)

    /// Today's blue mixed 70% toward the light paper: an answer faded under the person's writing. PencilKit's dark-mode
    /// conversion keeps it faint on the dark paper too.
    static let faded = UIColor(red: 0xB9 / 255, green: 0xC4 / 255, blue: 0xDC / 255, alpha: 1)

    /// The blues Maple has written in: today's, the lighter #2F5DB8 of pages made before 29 Oct, and today's faded.
    static let blues: [SIMD3<Double>] = [[0x1F, 0x45, 0x96], [0x2F, 0x5D, 0xB8], [0xB9, 0xC4, 0xDC]].map { $0 / 255 }

    /// The edit brush's deep coral, #D9481C, which PencilKit stores exactly too and draws as #E35226 on the dark paper
    /// (probed, 29 Oct): 4.1:1 on the light paper, 4.5:1 on the dark. Its marks tell Maple what to change; they are
    /// never writing.
    static let coral = UIColor(red: 0xD9 / 255, green: 0x48 / 255, blue: 0x1C / 255, alpha: 1)

    /// The corals the edit brush has drawn in: today's, and the lighter #FF7F50 of its first marks, 29 Oct.
    static let corals: [SIMD3<Double>] = [[0xD9, 0x48, 0x1C], [0xFF, 0x7F, 0x50]].map { $0 / 255 }

    static func wrote(_ stroke: PKStroke) -> Bool { inked(stroke, in: blues) }

    /// A mark of the edit brush.
    static func edit(_ stroke: PKStroke) -> Bool { inked(stroke, in: corals) }

    static func inked(_ stroke: PKStroke, in colours: [SIMD3<Double>]) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard stroke.ink.color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        let rgb = SIMD3<Double>(r, g, b)
        return colours.contains { (($0 - rgb) * ($0 - rgb)).max() <= 1.0 / 255 / 255 }
    }

    /// The person's own writing: their pen, not Maple's ink or the edit brush.
    static func person(_ stroke: PKStroke) -> Bool { stroke.ink.inkType == .pen && !wrote(stroke) && !edit(stroke) }

    /// Point size for ink drawn at `zoom`. These points render 2 × (size − 2) thick, and nothing at 2 or less (probed,
    /// 29 Oct), so 2 + 1.2/zoom draws 2.4 points on screen at the zoom it was written at.
    static func width(at zoom: CGFloat) -> CGFloat { 2 + 1.2 / zoom }  // calibration knob: about as heavy as the person's pen

    /// A stroke through `points`, filled in every `step` so PencilKit's spline smoothing keeps straight lines straight.
    /// Strokes written together share `date`, which is how an answer or a drawing finds its own ink again.
    static func stroke(_ points: [CGPoint], width: CGFloat, step: CGFloat, date: Date = Date()) -> PKStroke {
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
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: samples, creationDate: date))
    }
}
