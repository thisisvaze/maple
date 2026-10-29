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
                dots.append(Dot(x: center + px, y: center - (py * cos(cameraTilt) - pz * sin(cameraTilt)), z: depthZ,
                                radius: max(0.3, (1.0516 + 1.6252 * depth) * (1 - 0.25 * edge) * radiusScale),
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

/// The pixel grid over a box being drawn in: grey cells about a 32nd of the box, a soft diagonal wave rolling through,
/// and each cell flickering a little on its own clock.
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

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Thinking, _: UITraitCollection) in view.setNeedsDisplay() }
        for (name, running) in [(UIApplication.willResignActiveNotification, false), (UIApplication.didBecomeActiveNotification, true)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.active = running; self?.animate() }
            }
        }
        NotificationCenter.default.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.animate() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        animate()
    }

    override var isHidden: Bool { didSet { animate() } }

    /// Runs only while shown, in the foreground, and without Reduce Motion, which keeps a still frame.
    func animate() {
        let running = window != nil && !isHidden && active && !UIAccessibility.isReduceMotionEnabled
        if running, link == nil {
            lastFrame = 0
            let link = CADisplayLink(target: Tick(self), selector: #selector(Tick.tick))
            let rate: Float = style == .orb ? 60 : 30
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: rate, preferred: rate)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !running {
            link?.invalidate()
            link = nil
        }
        setNeedsDisplay()
    }

    func tick(_ link: CADisplayLink) {
        if lastFrame > 0 { time += min(link.timestamp - lastFrame, 0.05) * (style == .orb ? Orb.speed : 1) }
        lastFrame = link.timestamp
        setNeedsDisplay()
    }

    /// Sits over `box` on the page and scales with it, staying sharp up to 3×.
    func place(over box: CGRect, zoom: CGFloat) {
        layer.anchorPoint = .zero
        bounds = CGRect(origin: .zero, size: box.size)
        transform = CGAffineTransform(scaleX: zoom, y: zoom)
        center = CGPoint(x: box.minX * zoom, y: box.minY * zoom)
        contentScaleFactor = traitCollection.displayScale * min(max(zoom, 1), 3)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        func color(_ c: SIMD3<Double>, _ alpha: Double) -> CGColor { UIColor(red: c.x, green: c.y, blue: c.z, alpha: alpha).cgColor }
        switch style {
        case .orb:
            let scale = min(bounds.width, bounds.height) / 64
            context.translateBy(x: (bounds.width - 64 * scale) / 2, y: (bounds.height - 64 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            for dot in Orb.frame(at: time) {
                context.setFillColor(color(Orb.color(dot, at: time, dark: dark), dot.alpha))
                context.fillEllipse(in: CGRect(x: dot.x - dot.radius, y: dot.y - dot.radius, width: dot.radius * 2, height: dot.radius * 2))
            }
        case .pixels:
            for cell in PixelGrid.frame(size: bounds.size, at: time) {
                context.setFillColor(UIColor.secondaryLabel.withAlphaComponent(cell.alpha).cgColor)
                context.fill(cell.rect)
            }
        }
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
