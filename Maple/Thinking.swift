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

/// Grey cells about a 32nd of the box, with a soft diagonal wave and scattered grain.
nonisolated enum PixelGrid {
    struct Cell {
        var rect: CGRect
        var alpha: Double
    }

    static func frame(size: CGSize, at t: Double) -> [Cell] {
        let area = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.06, dy: size.height * 0.06)
        guard area.width > 0, area.height > 0 else { return [] }
        let side = max(8, max(area.width, area.height) / 32)
        var cells: [Cell] = []
        for row in 0..<Int((area.height / side).rounded(.up)) {
            for column in 0..<Int((area.width / side).rounded(.up)) {
                let x = Double(column), y = Double(row)
                let grain = sin(x * 12.9898 + y * 78.233) * 43758.5453, phase = (grain - grain.rounded(.down)) * 2 * .pi
                let wave = (1 + sin(x * 0.24 + y * 0.18 - t * 1.2)) / 2
                let rect = CGRect(x: area.minX + CGFloat(column) * side, y: area.minY + CGFloat(row) * side, width: side, height: side)
                cells.append(Cell(rect: rect.intersection(area), alpha: 0.035 + 0.07 * (1 + sin(t * 0.8 + phase)) / 2 + 0.09 * wave))
            }
        }
        return cells
    }
}

/// A thinking animation: the scribble in an answer's dot, or the pixel grid over a box being drawn in.
final class Thinking: UIView {
    enum Style { case orb, pixels }
    let style: Style
    /// The scribble chases round the ring; false holds one lap, as on the AI button at rest.
    var thinking = true { didSet { if thinking != oldValue { restart() } } }
    var active = UIApplication.shared.applicationState == .active
    let scribble = CAShapeLayer()
    let texture = CALayer()
    var cells: [CAShapeLayer] = []
    private var textureSize = CGSize.zero
    private var scribbleBounds = CGRect.zero
    private var takes: [CGPath] = []
    var indicator: Thinking?
    /// The page's zoom on a box being drawn in, so the scribble is drawn sharp at its size on screen.
    var pageZoom: CGFloat = 1 { didSet { sharpen() } }
    override var contentScaleFactor: CGFloat { didSet { sharpen() } }

    /// The light-mode blue Maple writes in, and PencilKit's own dark-mode version of it.
    static let pencil = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x69 / 255, green: 0x8F / 255, blue: 0xE0 / 255, alpha: 1) : AgentPen.blue }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        isOpaque = false
        isUserInteractionEnabled = false
        if style == .orb {
            (scribble.fillColor, scribble.lineCap, scribble.lineJoin) = (nil, .round, .round)
            layer.addSublayer(scribble)
            sharpen()
        } else {
            layer.addSublayer(texture)
            cells = (0..<4).map { _ in
                let cells = CAShapeLayer()
                texture.addSublayer(cells)
                return cells
            }
            let orb = Thinking(style: .orb)
            addSubview(orb)
            indicator = orb
            isAccessibilityElement = true
            accessibilityLabel = "Working on this image"
        }
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
        scribble.frame = bounds
        if style == .orb, bounds.width > 0, bounds.height > 0, bounds != scribbleBounds {
            scribbleBounds = bounds
            takes = (0..<3).map { Scribble.path($0, in: bounds) }
            scribble.lineWidth = min(bounds.width, bounds.height) * Scribble.width
            scribble.removeAllAnimations()  // its takes were for the old size
        }
        if style == .pixels, bounds.size != textureSize {
            textureSize = bounds.size
            // Four retained shades let Core Animation breathe the texture without repainting it during a pinch.
            let paths = (0..<4).map { _ in CGMutablePath() }
            for cell in PixelGrid.frame(size: bounds.size, at: 0.6) {
                let bin = min(3, max(0, Int((cell.alpha - 0.035) / 0.04)))
                paths[bin].addRect(cell.rect)
            }
            for (cell, path) in zip(cells, paths) { cell.path = path }
        }
        CATransaction.commit()
        let side = min(40 / pageZoom, min(bounds.width, bounds.height) * 0.65)
        indicator?.pageZoom = pageZoom
        indicator?.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        if style == .orb { animate() }
    }

    @objc func pause() { active = false; animate() }
    @objc func resume() { active = true; animate() }

    /// Runs only while shown, in the foreground, and without Reduce Motion, which keeps one lap still. All of it is
    /// Core Animation's: no display link, and nothing redrawn on the main thread.
    @objc func animate() {
        let running = window != nil && !isHidden && active && !UIAccessibility.isReduceMotionEnabled
        if style == .pixels {
            indicator?.isHidden = isHidden
            if running, texture.animation(forKey: "shimmer") == nil {
                let shimmer = CABasicAnimation(keyPath: "opacity")
                shimmer.fromValue = 0.65
                shimmer.toValue = 1
                shimmer.duration = 2.2
                shimmer.autoreverses = true
                shimmer.repeatCount = .infinity
                texture.add(shimmer, forKey: "shimmer")
            } else if !running { texture.removeAnimation(forKey: "shimmer") }
            return
        }
        guard !takes.isEmpty else { return }
        let chasing = running && thinking
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        (scribble.path, scribble.strokeStart, scribble.strokeEnd) = (takes[0], 0, chasing ? Scribble.shown / 2 : 0.5)
        if !running { scribble.removeAllAnimations() }
        if running, scribble.animation(forKey: "boil") == nil {
            let boil = CAKeyframeAnimation(keyPath: "path")
            boil.values = takes
            boil.calculationMode = .discrete
            boil.duration = Scribble.hold(thinking: thinking) * Double(takes.count)
            boil.repeatCount = .infinity
            scribble.add(boil, forKey: "boil")
        }
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
        CATransaction.commit()
    }

    /// Starts again for a new state: thinking chases and boils fast, at rest it holds a lap and boils slowly.
    private func restart() {
        scribble.removeAllAnimations()
        animate()
    }

    private func sharpen() { scribble.contentsScale = contentScaleFactor * pageZoom }

    /// The texture scales as vector paths; zoom never allocates or redraws a page-sized bitmap.
    func place(over box: CGRect, turn: CGFloat, zoom: CGFloat) {
        pageZoom = max(zoom, 0.1)
        layer.anchorPoint = .zero
        pin(to: box, turn: turn, zoom: zoom)
        setNeedsLayout()
    }

    private func updateColors() {
        guard style == .pixels else {
            scribble.strokeColor = Self.pencil.resolvedColor(with: traitCollection).cgColor
            return
        }
        backgroundColor = .paper.withAlphaComponent(0.6)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, cell) in cells.enumerated() {
            cell.fillColor = UIColor.secondaryLabel.resolvedColor(with: traitCollection).withAlphaComponent((0.055 + Double(i) * 0.04) * 0.3).cgColor
        }
        CATransaction.commit()
    }
}
