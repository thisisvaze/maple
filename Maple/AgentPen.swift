import PencilKit

/// The agent writes in real ink, so its drawings save, zoom, erase and undo like the person's. Its strokes are told apart
/// by colour: PencilKit stores colours exactly, but turned the .monoline ink Maple wrote in before 3 Nov into .pen when a
/// page was saved and reopened (probed on the iOS 26.5 simulator, 29 Oct), so the ink type can't be trusted.
nonisolated enum AgentPen {
    /// The light-mode blue PencilKit stores. In dark mode PencilKit draws its own conversion, #698FE0: 5.4:1 on the dark
    /// paper, and 8.6:1 for this one on the light paper.
    static let blue = UIColor(red: 0x1F / 255, green: 0x45 / 255, blue: 0x96 / 255, alpha: 1)
    static let ink = PKInk(.monoline, color: blue)  // `stroke`'s even line; Maple's own hand is `write`'s pencil

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

    static func wrote(_ stroke: PKStroke) -> Bool { inked(stroke, in: blues + fills.values.map(rgb)) }

    /// The coloured pencils Maple colours a drawing's parts in, by the name Muse gives (Drawing.fills): soft enough that
    /// its blue lines and labels read over them, and none near the edit brush's coral, which means "change this".
    static let fills: [String: UIColor] = [
        "yellow": UIColor(red: 0xF7 / 255, green: 0xDC / 255, blue: 0x6E / 255, alpha: 1),
        "green": UIColor(red: 0x7F / 255, green: 0xC4 / 255, blue: 0x8E / 255, alpha: 1),
        "blue": UIColor(red: 0x86 / 255, green: 0xB4 / 255, blue: 0xEC / 255, alpha: 1),
        "pink": UIColor(red: 0xF0 / 255, green: 0x9B / 255, blue: 0xBD / 255, alpha: 1),
    ]

    static func rgb(_ colour: UIColor) -> SIMD3<Double> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(r, g, b)
    }

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

    /// Point size for an even pen line drawn at `zoom`, as the crops Muse sees draw edit marks. These points render
    /// 2 × (size − 2) thick, and nothing at 2 or less (probed, 29 Oct), so 2 + thickness / 2 / zoom draws `thickness`
    /// points on screen at the zoom it was written at.
    static let thickness: CGFloat = 1.8  // calibration knob: screen points
    static func width(at zoom: CGFloat) -> CGFloat { 2 + thickness / 2 / zoom }

    /// A stroke through `points`, filled in every `step` so PencilKit's spline smoothing keeps straight lines straight.
    /// Strokes written together share `date`, which is how an answer or a drawing finds its own ink again.
    static func stroke(_ points: [CGPoint], width: CGFloat, step: CGFloat, date: Date = Date()) -> PKStroke {
        let dense = filled(points, every: step), size = CGSize(width: width, height: width)
        let samples = dense.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.002, size: size, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: samples, creationDate: date))
    }

    // MARK: Maple's hand

    /// Maple writes and draws in a blue coloured pencil: the grain of a real pencil on paper, next to the person's pen. A
    /// pencil stays a pencil when a page is saved and reopened (probed on the iOS 26.5 simulator, 3 Nov), unlike .monoline.
    static let pencil = PKInk(.pencil, color: blue)

    /// Screen points thick for Maple's drawn lines, and the most its writing gets.
    static let hand: CGFloat = 2.6  // calibration knob: the pencil's grain reads lighter than a pen line this thick
    static let shade: CGFloat = 1.3  // calibration knob: screen points thick for colouring in, light enough that labels read over it in dark mode too

    /// How thick Maple writes letters whose capitals are `cap` screen points: about an eighth of the capital, so a small
    /// label stays open instead of clogging.
    static func thickness(cap: CGFloat) -> CGFloat { min(max(cap * 0.12, 1.1), hand) }

    /// The pencil point size that draws `thickness` screen points at `zoom`: PencilKit draws a pencil point about
    /// 1.95 × size − 0.95 points wide, whatever the force (probed on the iOS 26.5 simulator, 3 Nov).
    static func pencilSize(_ thickness: CGFloat, at zoom: CGFloat) -> CGFloat { max((thickness / zoom + 0.95) / 1.95, 0.5) }

    static let bow: CGFloat = 1.4  // calibration knob: screen points a long line may bow off true, so it isn't a ruler's

    /// A pencil stroke of Maple's through `points`, `thickness` screen points at the `zoom` it's written at. It sets down
    /// and lifts a little thinner, as a pencil does; with `wobble`, a drawn line bows and drifts gently off true, its ends
    /// kept where they are. The same line always wobbles the same way, so redrawing it leaves it as it was.
    static func write(_ points: [CGPoint], zoom: CGFloat, thickness: CGFloat = hand, wobble: Bool = false, colour: UIColor = blue,
                      date: Date = Date()) -> PKStroke {
        var dense = filled(points, every: 2 / zoom), along: [CGFloat] = [0]  // screen points from the start
        for (a, b) in zip(dense, dense.dropFirst()) { along.append(along[along.count - 1] + hypot(b.x - a.x, b.y - a.y) * zoom) }
        let length = along[along.count - 1], size = pencilSize(thickness, at: zoom)
        if wobble { dense = bowed(dense, along: along, zoom: zoom) }
        let samples = dense.indices.map { i in
            // A dot or a short tick keeps its full width; a longer stroke tapers over its first 3 and last 5 screen points.
            let taper = length < 8 ? 1 : 0.65 + 0.35 * min(1, along[i] / 3, (length - along[i]) / 5)
            return PKStrokePoint(location: dense[i], timeOffset: Double(i) * 0.002, size: CGSize(width: size * taper, height: size * taper),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: colour == blue ? pencil : PKInk(.pencil, color: colour), path: PKStrokePath(controlPoints: samples, creationDate: date))
    }

    /// `points` moved off their line along its normal: one gentle bow over the whole stroke and a slow drift, both nothing
    /// at the ends and growing with length, at most `bow` screen points. Seeded by the line itself.
    static func bowed(_ points: [CGPoint], along: [CGFloat], zoom: CGFloat) -> [CGPoint] {
        let length = along[along.count - 1]
        guard points.count > 2, length > 4 else { return points }
        var seed = UInt64(truncatingIfNeeded: Int(((points[0].x * 31 + points[0].y * 17) * zoom + length) * 64))
        func random() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(seed >> 33) / CGFloat(1 << 31)  // 0 ..< 1
        }
        let bend = (random() * 2 - 1) * min(bow, length * 0.012), drift = min(bow / 3, length * 0.01), phase = (random() * 6.3, random() * 6.3)
        return points.indices.map { i in
            let a = points[max(i - 1, 0)], b = points[min(i + 1, points.count - 1)], d = hypot(b.x - a.x, b.y - a.y)
            guard d > 0 else { return points[i] }
            let s = along[i], off = (bend + drift * (0.6 * sin(s / 23 + phase.0) + 0.4 * sin(s / 61 + phase.1))) * sin(.pi * s / length) / zoom
            return CGPoint(x: points[i].x - (b.y - a.y) / d * off, y: points[i].y + (b.x - a.x) / d * off)
        }
    }

    /// `points` with a point at least every `step` along each segment.
    static func filled(_ points: [CGPoint], every step: CGFloat) -> [CGPoint] {
        var dense = [points[0]]
        for (a, b) in zip(points, points.dropFirst()) {
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / step))
            dense += (1...n).map { i in
                let t = CGFloat(i) / CGFloat(n)
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
        }
        return dense
    }
}
