import UIKit

/// The "breathing" ring of Thinking Orbs' 64 pt preset (by Jakub Antalik, MIT, ThinkingOrbs-LICENSE.txt), ported from
/// its engine: 11 lanes of 44 dots on a face-on circle whose radius undulates, depth-shaded and z-sorted, in a 64-unit
/// square. Maple tints it like an opal, with a glint travelling round.
nonisolated enum Orb {
    struct Dot {
        var x, y, z, radius, alpha: Double
    }

    static let speed = 3.24  // the preset's clock multiplier

    static func frame(at t: Double) -> [Dot] {
        let center = 32.0, ringRadius = center * 0.78, cameraTilt = 0.3, wobble = 0.368
        let baseRadius = ringRadius / (1 + 0.85 * 0.23 * wobble)  // lobes swell past the radius; keep them in the frame
        let radiusScale = pow(64.0 / 300, 0.6)  // dot sizes were tuned at 300 pt
        // Face-on: the band's plane is tilted back by exactly the camera's tilt, so it reads as a true circle.
        let tilt = -cameraTilt
        let v = (y: cos(tilt), z: sin(tilt)), n = (y: -sin(tilt), z: cos(tilt))
        var dots: [Dot] = []
        for lane in 0..<11 {
            let offset = Double(lane - 5) * 0.075, edge = Double(abs(lane - 5)) / 5
            for segment in 0..<44 {
                let a = Double(segment) / 44 * 2 * .pi
                let wave = (0.16 * sin(a * 3 - t * 1.7 + Double(lane) * 0.22) + 0.07 * sin(a * 5 + t * 1.1)) * wobble
                let x = cos(a), y = v.y * sin(a) + n.y * offset, z = v.z * sin(a) + n.z * offset
                let scale = baseRadius * (1 + wave) / (x * x + y * y + z * z).squareRoot()
                let (px, py, pz) = (x * scale, y * scale, z * scale)
                let depthZ = py * sin(cameraTilt) + pz * cos(cameraTilt)
                let depth = (depthZ / ringRadius + 1) / 2
                let fullness = 0.56 + 0.44 * Double(lane) / 10  // approved Fuller original preset
                dots.append(Dot(x: center + px * fullness, y: center - (py * cos(cameraTilt) - pz * sin(cameraTilt)) * fullness, z: depthZ,
                                radius: max(0.3, (1.0516 + 1.6252 * depth) * (1 - 0.25 * edge) * radiusScale) * 1.05,
                                alpha: 0.4 + 0.6 * depth))
            }
        }
        return dots.sorted { $0.z < $1.z }
    }

    static let opal: [SIMD3<Double>] = [[0.48, 0.77, 0.80], [0.63, 0.57, 0.81], [0.84, 0.64, 0.74], [0.84, 0.76, 0.55]]

    /// Opal colours drifting round the ring, over a pearl base, lit by a glint that travels round it.
    static func color(_ dot: Dot, at t: Double, dark: Bool) -> SIMD3<Double> {
        let angle = atan2(dot.y - 32, dot.x - 32)
        let tint = blend(opal, at: angle / (2 * .pi) + t * 0.014)
        let glint = pow(max(0, cos(angle + t * 0.13)), 16)
        let pearl: SIMD3<Double> = dark ? [0.80, 0.84, 0.89] : [0.31, 0.35, 0.42]
        let lit = pearl + (tint - pearl) * (0.3 + 0.6 * glint)
        return lit + ((dark ? [1, 1, 1] : [0.68, 0.73, 0.78]) - lit) * (glint * 0.5)
    }

    /// The cyclic blend of `colors` at `position`, which wraps every 1.
    static func blend(_ colors: [SIMD3<Double>], at position: Double) -> SIMD3<Double> {
        let p = (position - position.rounded(.down)) * Double(colors.count)
        let i = Int(p) % colors.count, f = p - p.rounded(.down)
        return colors[i] + (colors[(i + 1) % colors.count] - colors[i]) * f
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

/// A thinking animation: the opal orb in an answer's dot, or the pixel grid over a box being drawn in.
final class Thinking: UIView {
    enum Style { case orb, pixels }
    let style: Style
    var time = 0.6
    var lastFrame = 0.0
    var link: CADisplayLink?
    var active = UIApplication.shared.applicationState == .active
    let particles = CALayer()
    var dots: [CAShapeLayer] = []
    let texture = CALayer()
    var cells: [CAShapeLayer] = []
    private var textureSize = CGSize.zero
    var indicator: Thinking?
    var pageZoom: CGFloat = 1

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        isOpaque = false
        isUserInteractionEnabled = false
        if style == .orb {
            layer.addSublayer(particles)
            let circle = CGPath(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2), transform: nil)
            dots = (0..<484).map { _ in
                let dot = CAShapeLayer()
                dot.path = circle
                particles.addSublayer(dot)
                return dot
            }
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
        particles.position = CGPoint(x: bounds.midX, y: bounds.midY)
        particles.bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        particles.setAffineTransform(CGAffineTransform(scaleX: min(bounds.width, bounds.height) / 64, y: min(bounds.width, bounds.height) / 64))
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
        indicator?.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    @objc func pause() { active = false; animate() }
    @objc func resume() { active = true; animate() }

    /// Runs only while shown, in the foreground, and without Reduce Motion, which keeps a still frame.
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
        if running, link == nil {
            lastFrame = 0
            let link = CADisplayLink(target: Tick(self), selector: #selector(Tick.tick))
            let rate: Float = 60
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: rate, preferred: rate)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !running {
            link?.invalidate()
            link = nil
        }
        renderOrb()
    }

    func tick(_ link: CADisplayLink) {
        if lastFrame > 0 { time += min(link.timestamp - lastFrame, 0.05) * Orb.speed }
        lastFrame = link.timestamp
        renderOrb()
    }

    /// The texture scales as vector paths; zoom never allocates or redraws a page-sized bitmap.
    func place(over box: CGRect, turn: CGFloat, zoom: CGFloat) {
        pageZoom = max(zoom, 0.1)
        layer.anchorPoint = .zero
        pin(to: box, turn: turn, zoom: zoom)
        setNeedsLayout()
    }

    private func updateColors() {
        guard style == .pixels else { renderOrb(); return }
        backgroundColor = .paper.withAlphaComponent(0.6)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, cell) in cells.enumerated() {
            cell.fillColor = UIColor.secondaryLabel.resolvedColor(with: traitCollection).withAlphaComponent((0.055 + Double(i) * 0.04) * 0.3).cgColor
        }
        CATransaction.commit()
    }

    func renderOrb() {
        guard style == .orb else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, dot) in zip(dots, Orb.frame(at: time)) {
            let c = Orb.color(dot, at: time, dark: dark)
            layer.fillColor = UIColor(red: c.x, green: c.y, blue: c.z, alpha: dot.alpha).cgColor
            layer.position = CGPoint(x: dot.x, y: dot.y)
            layer.setAffineTransform(CGAffineTransform(scaleX: dot.radius, y: dot.radius))
        }
        CATransaction.commit()
    }

    /// The display link holds its target strongly; this keeps it from keeping a removed view alive.
    final class Tick: NSObject {
        weak var view: Thinking?
        init(_ view: Thinking) { self.view = view }
        @objc func tick(_ link: CADisplayLink) {
            guard let view else { return link.invalidate() }
            view.tick(link)
        }
    }
}
