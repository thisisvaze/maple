import UIKit

/// Maple's thinking mark, in its blue pencil: a scribble of small loops round a ring. While thinking, the line draws
/// itself on round the ring as its tail lifts away behind; at rest, as on the AI button, one lap stays drawn. Either way
/// it boils between three hand-drawn takes, as a drawn animation does.
nonisolated enum Scribble {
    // Calibration knobs, tuned by eye at 24 to 160 px. ring + loop + width / 2 stays under half the side.
    static let loops = 6
    static let ring: CGFloat = 0.29, loop: CGFloat = 0.13  // radii, as fractions of the side
    static let width: CGFloat = 0.04  // the pencil's line, as a fraction of the side
    static let shown: CGFloat = 0.62  // how much of a lap is drawn at once while thinking
    static let lap: CFTimeInterval = 1.8  // seconds per lap while thinking
    static func hold(thinking: Bool) -> CFTimeInterval { thinking ? 0.12 : 0.5 }  // seconds each take holds

    /// One lap round the ring, centered in `rect`, ending where it began. `take` is 0, 1 or 2: the same scribble by a
    /// slightly different hand. Only whole harmonics of the lap, so it closes.
    static func lap(_ take: Int, in rect: CGRect, points: Int = 240) -> [CGPoint] {
        let side = min(rect.width, rect.height), s = Double(take) * 2.4
        return (0...points).map { i in
            let t = Double(i) / Double(points) * 2 * .pi
            let r = ring * (1 + 0.05 * sin(2 * t + s) + 0.03 * sin(3 * t + 1.7 * s))
            let l = loop * (1 + 0.14 * sin(5 * t + 0.9 * s))
            let a = Double(loops) * t + 0.12 * sin(4 * t + s)
            return CGPoint(x: rect.midX + side * (r * cos(t) + l * cos(a)), y: rect.midY + side * (r * sin(t) + l * sin(a)))
        }
    }

    /// Two laps, so the line chasing round starts its next lap without a jump.
    static func path(_ take: Int, in rect: CGRect) -> CGPath {
        let one = lap(take, in: rect), path = CGMutablePath()
        path.addLines(between: one + one.dropFirst())
        return path
    }
}

/// What fills an empty box while Maple draws in it, in pencil on the page: Maple's blue pencil traces just inside the
/// box's own line as light hatching fills it, both fade, and it starts again. Everything follows the line the box was
/// drawn with, so it fits a slanted or wobbly box; a box with no drawn line, like a picture being edited, uses its rect.
nonisolated enum Sketch {
    // Calibration knobs, in screen points at the zoom the box was drawn at, and seconds.
    static let traceInset: CGFloat = 7, hatchInset: CGFloat = 5, gap: CGFloat = 6
    static let traceWidth: CGFloat = 2.2, hatchWidth: CGFloat = 1.2, wobble: CGFloat = 0.7, drift: CGFloat = 120  // drift: a wobble's length
    static let trace: CFTimeInterval = 1.1, hatchFrom: CFTimeInterval = 0.2, hatch: CFTimeInterval = 1.6
    static let hold: CFTimeInterval = 0.6, fade: CFTimeInterval = 0.6
    static var cycle: CFTimeInterval { hatchFrom + hatch + hold + fade }

    /// The points of a box's own lines, from the strokes of its mark, each a stroke's points: a box written under its
    /// label comes with the label, and its letters are left out, as any stroke under half as long as the longest.
    static func lines(_ strokes: [[CGPoint]]) -> [CGPoint] {
        let spans = strokes.map { stroke -> CGFloat in
            let box = stroke.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            return box.isNull ? 0 : max(box.width, box.height)
        }
        guard let longest = spans.max(), longest > 0 else { return [] }
        return zip(strokes, spans).filter { $0.1 >= longest / 2 }.flatMap(\.0)
    }

    /// The convex hull of `points`, clockwise on screen from its leftmost point: the outside of a drawn box.
    static func hull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        func turnsLeft(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Bool { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) > 0 }
        func chain(_ ordered: [CGPoint]) -> [CGPoint] {
            var out: [CGPoint] = []
            for p in ordered {
                while out.count >= 2, !turnsLeft(out[out.count - 2], out[out.count - 1], p) { out.removeLast() }
                out.append(p)
            }
            return out
        }
        return Array(chain(sorted).dropLast() + chain(sorted.reversed()).dropLast())
    }

    /// The convex `polygon` moved `d` inward: each corner along the bisector of its sides, as far as keeps both sides
    /// `d` in, and no further than 2d at a sharp tip.
    static func inset(_ polygon: [CGPoint], by d: CGFloat) -> [CGPoint] {
        let n = polygon.count
        guard n > 2 else { return polygon }
        let middle = CGPoint(x: polygon.map(\.x).reduce(0, +) / CGFloat(n), y: polygon.map(\.y).reduce(0, +) / CGFloat(n))
        func inward(_ a: CGPoint, _ b: CGPoint) -> CGVector {
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { return .zero }
            let v = CGVector(dx: (a.y - b.y) / length, dy: (b.x - a.x) / length)
            return (middle.x - a.x) * v.dx + (middle.y - a.y) * v.dy < 0 ? CGVector(dx: -v.dx, dy: -v.dy) : v
        }
        // The sides each corner moves off are read from the nearest corners at least d away, so a cluster of close
        // points, where the pen overshot a corner, doesn't swing it out of line.
        func neighbour(_ i: Int, _ step: Int) -> CGPoint {
            var j = (i + step + n) % n
            while j != i, hypot(polygon[j].x - polygon[i].x, polygon[j].y - polygon[i].y) < d { j = (j + step + n) % n }
            return polygon[j]
        }
        return polygon.indices.map { i in
            let p = polygon[i], before = inward(neighbour(i, -1), p), after = inward(p, neighbour(i, 1))
            let sum = CGVector(dx: before.dx + after.dx, dy: before.dy + after.dy), length = hypot(sum.dx, sum.dy)
            guard length > 0 else { return p }
            let m = CGVector(dx: sum.dx / length, dy: sum.dy / length), reach = d / max(m.dx * after.dx + m.dy * after.dy, 0.5)
            return CGPoint(x: p.x + m.dx * reach, y: p.y + m.dy * reach)
        }
    }

    /// The closed `polygon` as points about `step` apart, from its top-left corner, back to where it began.
    static func around(_ polygon: [CGPoint], every step: CGFloat) -> [CGPoint] {
        guard let start = polygon.indices.min(by: { polygon[$0].x + polygon[$0].y < polygon[$1].x + polygon[$1].y }), step > 0 else { return polygon }
        let ring = Array(polygon[start...] + polygon[..<start]) + [polygon[start]]
        return zip(ring, ring.dropFirst()).flatMap { a, b in
            let count = max(1, Int((hypot(b.x - a.x, b.y - a.y) / step).rounded()))
            return (0..<count).map { k in CGPoint(x: a.x + (b.x - a.x) * CGFloat(k) / CGFloat(count), y: a.y + (b.y - a.y) * CGFloat(k) / CGFloat(count)) }
        } + [ring[0]]
    }

    /// Lines `gap` apart at `angle`, each cut to the convex `polygon`, swept from one side to the other.
    static func hatching(_ polygon: [CGPoint], gap: CGFloat, angle: CGFloat = -.pi / 4) -> CGPath {
        let path = CGMutablePath(), along = CGVector(dx: cos(angle), dy: sin(angle)), across = CGVector(dx: -along.dy, dy: along.dx)
        let offsets = polygon.map { $0.x * across.dx + $0.y * across.dy }
        guard let low = offsets.min(), let high = offsets.max(), gap > 0 else { return path }
        for o in stride(from: low + gap / 2, to: high, by: gap) {
            var hits: [CGFloat] = []  // where this line crosses the polygon's sides, measured along it
            for i in polygon.indices {
                let j = (i + 1) % polygon.count, oa = offsets[i] - o, ob = offsets[j] - o
                guard (oa <= 0) != (ob <= 0) else { continue }
                let f = oa / (oa - ob), a = polygon[i], b = polygon[j]
                hits.append((a.x + (b.x - a.x) * f) * along.dx + (a.y + (b.y - a.y) * f) * along.dy)
            }
            guard let from = hits.min(), let to = hits.max(), to > from else { continue }
            path.move(to: CGPoint(x: across.dx * o + along.dx * from, y: across.dy * o + along.dy * from))
            path.addLine(to: CGPoint(x: across.dx * o + along.dx * to, y: across.dy * o + along.dy * to))
        }
        return path
    }
}

/// A thinking animation: the scribble in an answer's dot, or the sketch in a box being drawn in.
final class Thinking: UIView {
    enum Style { case orb, sketch }
    let style: Style
    /// The scribble chases round the ring; false holds one lap, as on the AI button at rest.
    var thinking = true { didSet { if thinking != oldValue { restart() } } }
    var active = UIApplication.shared.applicationState == .active
    let scribble = CAShapeLayer()
    let trace = CAShapeLayer(), hatching = CAShapeLayer()  // the sketch's pencil line round the box, and its hatching
    /// The box's drawn line, in the box's own points from its top-left; empty for a box with no line, which uses its rect.
    var outline: [CGPoint] = [] { didSet { sketched = .zero; setNeedsLayout() } }
    private var sketched = CGRect.zero  // the bounds the sketch was last made for
    private var scribbleBounds = CGRect.zero
    private var takes: [CGPath] = []  // the scribble's, or the trace's, three hand-drawn takes
    /// The page's zoom on a box being drawn in: the sketch's lines are sized for it, and drawn sharp at it.
    var pageZoom: CGFloat = 1 { didSet { sharpen() } }
    override var contentScaleFactor: CGFloat { didSet { sharpen() } }

    /// The light-mode blue Maple writes in, and PencilKit's own dark-mode version of it.
    static let pencil = UIColor { $0.userInterfaceStyle == .dark ? AgentPen.darkBlue : AgentPen.blue }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        isOpaque = false
        isUserInteractionEnabled = false
        for shape in style == .orb ? [scribble] : [hatching, trace] {
            (shape.fillColor, shape.lineCap, shape.lineJoin) = (nil, .round, .round)
            layer.addSublayer(shape)
        }
        if style == .sketch {
            isAccessibilityElement = true
            accessibilityLabel = "Working on this image"
        }
        sharpen()
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Thinking, _: UITraitCollection) in view.updateColors() }
        let center = NotificationCenter.default  // selector observers leave with the view
        center.addObserver(self, selector: #selector(pause), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(resume), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(animate), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        animate()
    }

    override var isHidden: Bool { didSet { animate() } }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [scribble, trace, hatching] { shape.frame = bounds }
        if style == .orb, bounds.width > 0, bounds.height > 0, bounds != scribbleBounds {
            scribbleBounds = bounds
            takes = (0..<3).map { Scribble.path($0, in: bounds) }
            scribble.lineWidth = min(bounds.width, bounds.height) * Scribble.width
            scribble.removeAllAnimations()  // its takes were for the old size
        }
        if style == .sketch, bounds.width > 0, bounds.height > 0, bounds != sketched { makeSketch() }
        CATransaction.commit()
        animate()
    }

    /// The trace's takes and the hatching for this box, sized in screen points at the zoom it's placed at; a pinch
    /// afterwards scales them with the page, like ink.
    private func makeSketch() {
        sketched = bounds
        let unit = 1 / pageZoom, side = min(bounds.width, bounds.height)
        let corners = [CGPoint.zero, CGPoint(x: bounds.width, y: 0), CGPoint(x: bounds.width, y: bounds.height), CGPoint(x: 0, y: bounds.height)]
        let hull = Sketch.hull(outline.count > 2 ? outline : corners)
        // A small box keeps a little room in the middle rather than turning itself inside out.
        let line = Sketch.around(Sketch.inset(hull, by: min(Sketch.traceInset * unit, side / 6)), every: 3 * unit)
        // Each take drifts in and out a little, slowly along the line, in whole waves round it so the corner it starts at
        // closes.
        let middle = CGPoint(x: bounds.midX, y: bounds.midY), laps = max(2, (CGFloat(line.count) * 3 / Sketch.drift).rounded())
        takes = (0..<3).map { take in
            let path = CGMutablePath()
            path.addLines(between: line.enumerated().map { i, p in
                let out = CGVector(dx: p.x - middle.x, dy: p.y - middle.y), length = max(hypot(out.dx, out.dy), 1)
                let a = 2 * .pi * laps * CGFloat(i) / CGFloat(line.count - 1), k = CGFloat(take) * 2.1
                let shift = Sketch.wobble * unit * (0.7 * sin(a + k) + 0.3 * sin(2 * a + 1.7 * k)) / length
                return CGPoint(x: p.x + out.dx * shift, y: p.y + out.dy * shift)
            })
            return path
        }
        trace.lineWidth = Sketch.traceWidth * unit
        hatching.path = Sketch.hatching(Sketch.inset(hull, by: min(Sketch.hatchInset * unit, side / 8)), gap: Sketch.gap * unit)
        hatching.lineWidth = Sketch.hatchWidth * unit
        trace.removeAllAnimations()
        hatching.removeAllAnimations()
    }

    @objc func pause() { active = false; animate() }
    @objc func resume() { active = true; animate() }

    /// Runs only while shown, in the foreground, and without Reduce Motion, which keeps one lap, or the whole sketch,
    /// still. All of it is Core Animation's: no display link, and nothing redrawn on the main thread.
    @objc func animate() {
        guard !takes.isEmpty else { return }
        let running = window != nil && !isHidden && active && !UIAccessibility.isReduceMotionEnabled
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if style == .sketch {
            (trace.path, trace.strokeEnd, hatching.strokeEnd) = (takes[0], 1, 1)
            guard running else { return [trace, hatching].forEach { $0.removeAllAnimations() } }
            guard hatching.animation(forKey: "sketch") == nil else { return }
            let cycle = Sketch.cycle, filled = Sketch.hatchFrom + Sketch.hatch, fading = filled + Sketch.hold
            func keys(_ path: String, _ values: [CGFloat], at times: [CFTimeInterval]) -> CAKeyframeAnimation {
                let keys = CAKeyframeAnimation(keyPath: path)
                (keys.values, keys.keyTimes) = (values, times.map { NSNumber(value: $0 / cycle) })
                return keys
            }
            func looping(_ parts: [CAAnimation]) -> CAAnimationGroup {
                let group = CAAnimationGroup()
                (group.animations, group.duration, group.repeatCount) = (parts, cycle, .infinity)
                return group
            }
            let fade = keys("opacity", [1, 1, 0], at: [0, fading, cycle])
            let draw = keys("strokeEnd", [0, 1, 1], at: [0, Sketch.trace, cycle])
            draw.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)]
            trace.add(looping([draw, fade]), forKey: "sketch")
            hatching.add(looping([keys("strokeEnd", [0, 0, 1, 1], at: [0, Sketch.hatchFrom, filled, cycle]), fade]), forKey: "sketch")
            trace.add(boil(hold: Scribble.hold(thinking: true)), forKey: "boil")
            return
        }
        let chasing = running && thinking
        (scribble.path, scribble.strokeStart, scribble.strokeEnd) = (takes[0], 0, chasing ? Scribble.shown / 2 : 0.5)
        if !running { scribble.removeAllAnimations() }
        if running, scribble.animation(forKey: "boil") == nil { scribble.add(boil(hold: Scribble.hold(thinking: thinking)), forKey: "boil") }
        // The path holds two laps: drawing from one lap's point to the same point a lap on loops without a seam.
        if chasing, scribble.animation(forKey: "chase") == nil {
            let start = CABasicAnimation(keyPath: "strokeStart"), end = CABasicAnimation(keyPath: "strokeEnd")
            (start.fromValue, start.toValue) = (0, 0.5)
            (end.fromValue, end.toValue) = (Scribble.shown / 2, 0.5 + Scribble.shown / 2)
            let chase = CAAnimationGroup()
            chase.animations = [start, end]
            chase.duration = Scribble.lap
            chase.repeatCount = .infinity
            scribble.add(chase, forKey: "chase")
        }
    }

    /// The line flickering between its three hand-drawn takes, each held `hold` seconds.
    private func boil(hold: CFTimeInterval) -> CAKeyframeAnimation {
        let boil = CAKeyframeAnimation(keyPath: "path")
        boil.values = takes
        boil.calculationMode = .discrete
        boil.duration = hold * Double(takes.count)
        boil.repeatCount = .infinity
        return boil
    }

    /// Starts again for a new state: thinking chases and boils fast, at rest it holds a lap and boils slowly.
    private func restart() {
        scribble.removeAllAnimations()
        animate()
    }

    private func sharpen() { [scribble, trace, hatching].forEach { $0.contentsScale = contentScaleFactor * pageZoom } }

    /// The sketch is vector paths; zoom never allocates or redraws a page-sized bitmap.
    func place(over box: CGRect, turn: CGFloat, zoom: CGFloat) {
        pageZoom = max(zoom, 0.1)
        layer.anchorPoint = .zero
        pin(to: box, turn: turn, zoom: zoom)
        setNeedsLayout()
    }

    private func updateColors() {
        scribble.strokeColor = Self.pencil.resolvedColor(with: traitCollection).cgColor
        trace.strokeColor = scribble.strokeColor
        hatching.strokeColor = UIColor.label.withAlphaComponent(0.34).resolvedColor(with: traitCollection).cgColor  // a soft graphite
    }
}
