import Metal
import UIKit

/// Maple's thinking light, drawn in Metal: one soft band of cyan light round a ring, its line and its width wavering on
/// slow waves, with a sheen travelling round it. "Thinking" is a wide band that breathes; "idle", for the AI button at
/// rest, a thin, slow ring.
enum Aura {
    /// Matches `Uniforms` in the shader. `shape` is the ring's radius and its band's width, in half-sides of the view,
    /// and how far each wavers, as fractions of them.
    struct Uniforms {
        var resolution: SIMD2<Float>
        var phase: Float
        var brightness: Float
        var shape: SIMD4<Float>
        var dark: Float
    }

    /// Radius, waver, width, width's waver. Calibration knobs, tuned by eye at 24 to 160 px; thinking's edge, 0.58 ×
    /// 1.08 + 3 × 0.1 × 1.25 ≈ 1.0 half-sides out, is where its faint haze has faded to 1%.
    static func shape(thinking: Bool) -> SIMD4<Float> { thinking ? [0.58, 0.08, 0.1, 0.25] : [0.42, 0.07, 0.06, 0.25] }

    /// How fast the waves move, radians of phase per second.
    static func speed(thinking: Bool) -> Float { thinking ? 1.2 : 0.4 }

    static let breath = 1.2  // calibration knob: seconds per breath while thinking

    /// Thinking breathes between 0.8 and 1.6 and back, once a `breath`; idle holds at 1.
    static func brightness(thinking: Bool, at time: Double) -> Float {
        guard thinking else { return 1 }
        return Float(1.2 + 0.4 * sin(2 * .pi * time / breath))
    }

    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()
    // ponytail: compiled from source on first use (tens of ms, once); move to a .metal file if launch time matters.
    static let pipeline: (any MTLRenderPipelineState)? = {
        guard let device else { return nil }
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "auraVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "auraFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            assertionFailure("Aura shader: \(error)")
            return nil
        }
    }()

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float2 resolution; float phase; float brightness; float4 shape; float dark; };

    constant float3 inner = float3(0.20, 0.86, 0.98);  // cyan, on the band's inside
    constant float3 outer = float3(0.18, 0.62, 0.98);  // blue, on its outside
    constant float3 deep = float3(0.04, 0.40, 0.70);   // where the band is brightest, on paper

    // One triangle that covers the view: (-1, -1), (3, -1), (-1, 3).
    vertex float4 auraVertex(uint id [[vertex_id]]) {
        return float4(id == 1 ? 3.0 : -1.0, id == 2 ? 3.0 : -1.0, 0.0, 1.0);
    }

    // How far the ring wavers at angle `a`, -1 to 1; `k` picks one of its waves. Only whole harmonics of the angle and
    // the phase, so it closes round the ring, and the loop has no seam when the phase wraps at 2π.
    float swing(float a, float phase, float k) {
        return 0.5 * sin(3.0 * a + phase + 1.9 * k)
             + 0.3 * sin(5.0 * a - 2.0 * phase + 3.1 * k)
             + 0.2 * sin(2.0 * a + 3.0 * phase + 0.7 * k);
    }

    fragment float4 auraFragment(float4 position [[position]], constant Uniforms &u [[buffer(0)]]) {
        float2 p = (position.xy - 0.5 * u.resolution) / (0.5 * min(u.resolution.x, u.resolution.y));
        float r = length(p), a = atan2(p.y, p.x);
        float radius = u.shape.x, wobble = u.shape.y, width = u.shape.z, uneven = u.shape.w;
        float center = radius * (1.0 + wobble * swing(a, u.phase, 0.0));
        float w = width * (1.0 + uneven * swing(a, u.phase, 2.0));
        float d = (r - center) / w;
        float d2 = d * d;
        float body = exp(-d2 * d2);  // flat-topped, so the band has an edge
        float haze = 0.15 * exp(-0.3 * d2);  // and a faint glow past it
        float sheen = 0.65 + 0.35 * sin(2.0 * a - u.phase + 1.4 * d);  // brighter folds travel round the ring
        float3 tint = mix(inner, outer, saturate(0.5 + 0.5 * d));
        float3 light = tint * (body * sheen + haze) * u.brightness;
        // Output is premultiplied: color no brighter than its alpha.
        if (u.dark > 0.5) {
            float3 glow = 1.0 - exp(-1.8 * light);
            return float4(glow, max(glow.r, max(glow.g, glow.b)));
        }
        // On paper, light can't brighten white, so it shows as tinted ink: its hue at full strength, deepening where
        // the band is brightest, and its amount as coverage.
        float peak = max(light.r, max(light.g, light.b));
        float cover = min(1.0 - exp(-1.8 * peak), 0.92);
        float3 hue = mix(light / max(peak, 1e-4), deep, saturate(0.5 * (peak - 0.9)));
        return float4(0.92 * hue * cover, cover);
    }
    """
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

/// A thinking animation: the Aura in an answer's dot, or the pixel grid over a box being drawn in.
final class Thinking: UIView {
    enum Style { case orb, pixels }
    let style: Style
    /// Aura's thinking state; false gives its calmer idle one.
    var thinking = true { didSet { if window == nil { shape = Aura.shape(thinking: thinking) } } }
    var time = 0.1  // a mid-pulse still frame under Reduce Motion
    var phase: Float = 0
    var shape = Aura.shape(thinking: true)
    var lastFrame = 0.0
    var link: CADisplayLink?
    var active = UIApplication.shared.applicationState == .active
    let aura = CAMetalLayer()
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
            aura.device = Aura.device
            aura.pixelFormat = .bgra8Unorm
            aura.isOpaque = false
            layer.addSublayer(aura)
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
        aura.frame = bounds
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
        indicator?.pageZoom = pageZoom  // so its drawable matches its size on screen
        indicator?.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        if style == .orb, link == nil { renderOrb() }
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
        if lastFrame > 0 {
            let step = min(link.timestamp - lastFrame, 0.05)
            time += step
            // The waves only turn by whole multiples of the phase, so it wraps without a seam and keeps float precision.
            phase = (phase + Float(step) * Aura.speed(thinking: thinking)).truncatingRemainder(dividingBy: 2 * .pi)
            shape += (Aura.shape(thinking: thinking) - shape) * Float(min(1, step * 6))  // settles in about 0.5 s
        }
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

    /// Draws one frame at the orb's size on screen; a page zoom on the box being drawn in doesn't resize it.
    func renderOrb() {
        guard style == .orb, let pipeline = Aura.pipeline else { return }
        let scale = contentScaleFactor * pageZoom
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width > 0, size.height > 0 else { return }
        if aura.drawableSize != size { aura.drawableSize = size }
        guard let drawable = aura.nextDrawable(), let buffer = Aura.queue?.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare  // the shader writes every pixel
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = Aura.Uniforms(resolution: [Float(size.width), Float(size.height)], phase: phase,
                                     brightness: Aura.brightness(thinking: thinking, at: time), shape: shape,
                                     dark: traitCollection.userInterfaceStyle == .dark ? 1 : 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Aura.Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
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
