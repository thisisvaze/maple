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
    // Drawings in a hand (Drawing.handDrawn), in screen points: a lighter line for axes, guides and inner details, and
    // colouring in with the side of the pencil, at a low opacity, since PencilKit's pencil takes no tilt or force from
    // made-up points, only size and opacity (probed on the iOS 26.5 simulator, 3 Nov).
    static let fine: CGFloat = 1.5  // calibration knob
    static let soft: CGFloat = 5.2  // calibration knob: under Written.reveal's 7.4-point trail, as unbowed colouring is
    static let softTone: CGFloat = 0.34  // calibration knob: how strongly colouring in shows, a light wash labels read over

    /// PencilKit's pencil stamps a point's texture over and over along a line, so a point's opacity builds up: about
    /// 2.4 stamps per point of size, so opacity o shows as 1 − (1 − o)^(2.4 × size). Measured on the iOS 26.5 simulator,
    /// 3 Nov: o 0.3 at size 3.15 shows 0.93, o 0.1 shows 0.56, and o 0.3 at size 1.82 shows 0.80.
    static let stamps: CGFloat = 2.4  // calibration knob
    static func shown(opacity: CGFloat, size: CGFloat) -> CGFloat { 1 - pow(1 - min(max(opacity, 0), 1), stamps * max(size, 0.1)) }
    /// The opacity that shows as `tone` at point `size`, so a line's tone doesn't change with the zoom it's drawn at.
    static func opacity(showing tone: CGFloat, size: CGFloat) -> CGFloat { 1 - pow(1 - min(max(tone, 0), 0.999), 1 / (stamps * max(size, 0.1))) }

    /// Maple writes answers in a fine blue pen, smooth so a line of writing reads calmly, with the same taper. PencilKit
    /// draws a pen point about 2 × (size − 2) points wide, nothing at a size under 2, and ignores opacity (probed on the
    /// iOS 26.5 simulator, 3 Nov), so pen sizes keep to 2.2 and up.
    static let pen = PKInk(.pen, color: blue)
    static let penShare: CGFloat = 0.62  // calibration knob: a pen line this share of the pencil's width weighs the same (1.6 at a 24-point capital)
    enum Nib: Sendable { case pencil, pen }

    /// How a hand presses along a drawn line: it sets down light, presses through and lifts quickly; a flick starts firm
    /// and is gone by its end; colouring in stays soft, easing in and out.
    enum Press: Sendable { case hand, flick, shade }

    /// How hard `press` presses `s` screen points into a stroke `length` long, from 0 to 1.
    static func pressure(_ press: Press, at s: CGFloat, of length: CGFloat) -> CGFloat {
        func ease(_ x: CGFloat) -> CGFloat { let x = min(max(x, 0), 1); return x * (2 - x) }
        switch press {
        case .hand:
            guard length >= 8 else { return 1 }  // a dot or a short tick keeps its full weight
            let firm = (0.35 + 0.65 * ease(s / 6)) * (0.3 + 0.7 * ease((length - s) / 4.5))
            return length > 90 ? firm * (1 - 0.1 * pow(sin(.pi * s / length), 2)) : firm  // a long line eases off as it speeds up
        case .flick: return 1 - 0.8 * pow(min(max(s / max(length, 1), 0), 1), 1.2)
        case .shade: return 0.55 + 0.45 * ease(min(s, length - s) / 5)
        }
    }

    /// How thick Maple writes letters whose capitals are `cap` screen points: about an eighth of the capital, so a small
    /// label stays open instead of clogging.
    static func thickness(cap: CGFloat) -> CGFloat { min(max(cap * 0.12, 1.1), hand) }

    /// The pencil point size that draws `thickness` screen points at `zoom`: PencilKit draws a pencil point about
    /// 1.95 × size − 0.95 points wide, whatever the force (probed on the iOS 26.5 simulator, 3 Nov).
    static func pencilSize(_ thickness: CGFloat, at zoom: CGFloat) -> CGFloat { max((thickness / zoom + 0.95) / 1.95, 0.5) }

    static let bow: CGFloat = 1.4  // calibration knob: screen points a long line may bow off true, so it isn't a ruler's

    /// A pencil stroke of Maple's through `points`, `thickness` screen points at the `zoom` it's written at. It sets down
    /// and lifts a little thinner, as a pencil does, or with `press`, thins and lightens along the stroke as that hand
    /// presses; with `wobble`, a drawn line bows and drifts gently off true, its ends kept where they are. The same line
    /// always draws the same way, so redrawing it leaves it as it was. Pressure changes only size and opacity, never where
    /// a point is.
    static func write(_ points: [CGPoint], zoom: CGFloat, thickness: CGFloat = hand, wobble: Bool = false, colour: UIColor = blue,
                      press: Press? = nil, nib: Nib = .pencil, date: Date = Date()) -> PKStroke {
        var dense = filled(points, every: 2 / zoom), along: [CGFloat] = [0]  // screen points from the start
        for (a, b) in zip(dense, dense.dropFirst()) { along.append(along[along.count - 1] + hypot(b.x - a.x, b.y - a.y) * zoom) }
        let length = along[along.count - 1], size = pencilSize(thickness, at: zoom)
        if wobble { dense = bowed(dense, along: along, zoom: zoom) }
        let samples = dense.indices.map { i in
            // A dot or a short tick keeps its full width; a longer stroke tapers over its first 3 and last 5 screen points.
            let taper = length < 8 ? 1 : 0.65 + 0.35 * min(1, along[i] / 3, (length - along[i]) / 5)
            var point = size * taper, opacity: CGFloat = 1
            if nib == .pen {
                // ponytail: the 2.2 floor is 0.4 page points, so above about 4× zoom answers write a little heavier and
                // lose their taper; probe how thin PencilKit's pen still draws before lowering it.
                point = max(2.2, 2 + thickness * penShare * taper / zoom / 2)
            } else if let press {  // in width, before the size it takes, so a light end never thins to nothing
                let p = pressure(press, at: along[i], of: length)
                point = pencilSize(thickness * (0.5 + 0.5 * p), at: zoom)
                // Colouring is set by the tone it shows, its opacity building up as the size goes up; a line lightens as it lifts.
                // ponytail: a line's lift shows more zoomed in than out, since its opacity isn't set by tone; the stamp
                // model is only measured for light tones, so set lines by it once it's measured near full.
                opacity = press == .shade ? Self.opacity(showing: softTone * (0.6 + 0.4 * p), size: point) : 0.45 + 0.55 * p
            }
            return PKStrokePoint(location: dense[i], timeOffset: Double(i) * 0.002, size: CGSize(width: point, height: point),
                                 opacity: opacity, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let ink = nib == .pen ? (colour == blue ? pen : PKInk(.pen, color: colour)) : (colour == blue ? pencil : PKInk(.pencil, color: colour))
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: samples, creationDate: date))
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
