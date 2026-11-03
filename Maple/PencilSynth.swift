import Foundation

/// A pencil on paper, synthesised as it's drawn: a scraping model. The nib reads the paper's tooth as a height profile
/// laid out along the stroke, so the grain's pitch and density follow the pen's speed the way real paper does (a slow
/// line rasps low and sparse, a quick one hisses bright and dense). Graphite crackle comes from fibres giving way, a few
/// per point travelled, and the sheet adds a little body. A still pen is silent. Pure arithmetic with no allocation,
/// for one thread: the audio thread in the app (PencilSound), or a file renderer for the launch film.
/// Eraser spreads that contact into a warm rubber rub; edit uses finer, smoother felt with much less crackle.
nonisolated struct PencilSynth: Sendable {
    enum Material: UInt64, CaseIterable { case pencil, eraser, edit }
    // Calibration knobs. Lengths are screen points (about 0.19 mm on an iPad), levels linear.
    /// The tooth's scales, coarse to fine, and how much each is heard: drawing paper's tooth is ~0.1–0.3 mm, its fibres
    /// ~0.02–0.05 mm. At writing speed (150–400 pt/s) these land between 120 Hz and 16 kHz, weighted to 1–5 kHz.
    static let tooth: [(spacing: Double, weight: Double)] = [(1.2, 0.1), (0.45, 0.25), (0.17, 0.7), (0.065, 1), (0.025, 0.8)]
    static let crackles = 2.0  // graphite crackles per point travelled
    static let crackleMix = 0.4  // calibration knob: lower is calmer, fewer brittle ticks
    static let fullSpeed = 900.0  // points a second for full level; level grows as speed^0.65 below it
    static let level = 0.062  // the whole sound; about -37 dBFS for writing at 300 pt/s, half pressure

    let rate: Double
    private(set) var material = Material.pencil
    private var seed: UInt64
    private var along = 0.0  // points along the paper: a fresh stretch each stroke
    private var speed = 0.0, gain = 0.0
    private var last = [Double](repeating: 0, count: PencilSynth.tooth.count)
    private var high = Biquad(), body = Biquad(), low = Biquad()
    private var fibres = [Biquad](repeating: Biquad(), count: 3)
    private var tapBody = Biquad(), tapLeft = 0
    private var countdown = 0  // samples until the low-pass follows the speed again
    private let speedK: Double, attackK: Double, releaseK: Double

    init(rate: Double, seed: UInt64 = 0x5EED) {
        self.rate = rate
        self.seed = seed | 1
        speedK = 1 - exp(-1 / (0.010 * rate))  // speed glides over 10 ms: touch samples arrive at 120–240 Hz
        attackK = 1 - exp(-1 / (0.008 * rate))  // a soft onset, never a click
        releaseK = 1 - exp(-1 / (0.030 * rate))  // a lifted pen whispers out rather than cuts
        high.set(.highPass, 400, 0.7, rate)
        body.set(.bandPass, 420, 1.2, rate)  // the sheet on the desk
        for (i, f) in [2400.0, 3600, 5000].enumerated() { fibres[i].set(.bandPass, f, 3, rate) }
        tapBody.set(.bandPass, 1900, 2.5, rate)
        low.set(.lowPass, 3000, 0.7, rate)
    }

    /// A new stroke: another stretch of paper, so no two strokes rasp alike. `tap` adds the nib's soft landing; the app
    /// leaves it out because a real Pencil already taps the glass.
    mutating func begin(tap: Bool, material: Material = .pencil) {
        if self.material != material {
            self.material = material
            // Each tool lands softly; old filter energy must not click through a change of material.
            gain = 0; speed = 0; countdown = 0; tapLeft = 0
            high = Biquad(); body = Biquad(); low = Biquad()
            let (cut, resonance): (Double, Double) = switch material {
            case .pencil: (400, 420)
            case .eraser: (90, 220)
            case .edit: (900, 600)
            }
            high.set(.highPass, cut, 0.7, rate)
            body.set(.bandPass, resonance, material == .pencil ? 1.2 : 0.7, rate)
        }
        along = Double(next() >> 40)  // anywhere along 16 million points of paper
        for (i, scale) in Self.tooth.enumerated() { last[i] = profile(along, scale.spacing * grainScale, i) }
        if tap { tapLeft = Int(0.004 * rate) }
    }

    private var grainScale: Double {
        switch material { case .pencil: 1; case .eraser: 2.8; case .edit: 0.8 }
    }

    /// Writes `count` samples for a pen moving at `target` points a second (0 when still or lifted) at `pressure` 0...1.
    mutating func render(into out: UnsafeMutablePointer<Float>, count: Int, speed target: Double, pressure: Double) {
        let target = target.isFinite ? min(max(target, 0), 6000) : 0
        let pressure = pressure.isFinite ? min(max(pressure, 0), 1) : 0.5
        let bodyMix = material == .eraser ? 0.4 + 0.4 * pressure : 0.12 + 0.25 * pressure
        let (scrapeMix, crackleMix, level, cutoff, brightness): (Double, Double, Double, Double, Double) = switch material {
        case .pencil: (0.35, Self.crackleMix, Self.level, 4000, 4200)  // calm: soft graphite, the top octave kept low
        case .eraser: (0.5, 0.025, 0.075, 1600, 1800)  // broad rubber rub, barely any brittle fibres
        case .edit: (0.32, 0.06, 0.065, 6000, 8000)  // fine, smooth felt; lighter than graphite
        }
        let grainScale = grainScale
        for n in 0..<count {
            speed += (target - speed) * speedK
            let goal = Self.loudness(speed) * (0.35 + 0.65 * pressure.squareRoot())
            gain += (goal - gain) * (goal > gain ? attackK : releaseK)
            if countdown == 0 {
                countdown = 32
                low.set(.lowPass, (cutoff + brightness * min(speed / Self.fullSpeed, 1)) * (1.1 - 0.25 * pressure), 0.7, rate)
            }
            countdown -= 1

            let step = speed / rate
            along += step
            var scrape = 0.0
            if step > 1e-7 {
                for (i, scale) in Self.tooth.enumerated() {
                    let spacing = scale.spacing * grainScale
                    let height = profile(along, spacing, i)
                    let grain = speed / spacing  // Hz: how often this scale's bumps pass under the nib
                    let clear = 1 - smoothstep(0.3 * rate, 0.45 * rate, grain)  // no grain finer than the sample rate holds
                    scrape += scale.weight * clear * (height - last[i]) * spacing / step
                    last[i] = height
                }
            }
            var crackle = 0.0
            if unit() < Self.crackles * step {
                let size = exp(0.7 * gaussian()) * (0.6 + 0.8 * pressure) * (unit() < 0.5 ? -1 : 1)
                let fibre = Int(unit() * 3) % 3
                crackle = fibres[fibre](size)
                for i in 0..<3 where i != fibre { crackle += fibres[i](0) }
            } else {
                for i in 0..<3 { crackle += fibres[i](0) }
            }
            let rub = material == .eraser ? 0.85 + 0.15 * profile(along, 9, 6) : 1
            var x = high((scrapeMix * scrape + crackleMix * crackle) * rub)
            x = low(x + bodyMix * body(x))
            var tap = 0.0
            if tapLeft > 0 {
                tapLeft -= 1
                tap = tapBody(Double(tapLeft) / (0.004 * rate) * (0.5 * gaussian()))
            } else {
                tap = tapBody(0)
            }
            out[n] = Float(tanh((x * gain + 0.6 * tap) * level))
        }
    }

    /// Level from speed: nothing under 4 points a second (a resting nib), then speed^0.65 up to full.
    static func loudness(_ speed: Double) -> Double {
        smoothstep(4, 20, speed) * pow(min(speed / fullSpeed, 1), 0.65)
    }

    // MARK: Paper

    /// The tooth at one scale: a fixed random height per lattice point, eased between them.
    private func profile(_ s: Double, _ spacing: Double, _ octave: Int) -> Double {
        let x = s / spacing, cell = x.rounded(.down), f = x - cell, k = f * f * (3 - 2 * f)
        let i = Int64(cell)
        return height(i, octave) * (1 - k) + height(i &+ 1, octave) * k
    }

    private func height(_ i: Int64, _ octave: Int) -> Double {
        var z = UInt64(bitPattern: i) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(octave + 1) &* 0xD1B5_4A32_D192_ED03
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53) * 2 - 1
    }

    // MARK: Randomness (xorshift64*), no allocation

    private mutating func next() -> UInt64 {
        seed ^= seed >> 12
        seed ^= seed << 25
        seed ^= seed >> 27
        return seed &* 0x2545_F491_4F6C_DD1D
    }

    private mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    private mutating func gaussian() -> Double {  // Irwin–Hall: close enough, and cheap
        (unit() + unit() + unit() + unit() - 2) * 1.732
    }
}

nonisolated private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

/// RBJ cookbook biquad, transposed direct form II.
nonisolated struct Biquad: Sendable {
    enum Kind { case lowPass, highPass, bandPass }
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0

    mutating func set(_ kind: Kind, _ frequency: Double, _ q: Double, _ rate: Double) {
        let w = 2 * Double.pi * min(frequency, 0.45 * rate) / rate, alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        switch kind {
        case .lowPass: (b0, b1, b2) = ((1 - c) / 2, 1 - c, (1 - c) / 2)
        case .highPass: (b0, b1, b2) = ((1 + c) / 2, -(1 + c), (1 + c) / 2)
        case .bandPass: (b0, b1, b2) = (alpha, 0, -alpha)
        }
        (b0, b1, b2, a1, a2) = (b0 / a0, b1 / a0, b2 / a0, -2 * c / a0, (1 - alpha) / a0)
    }

    mutating func callAsFunction(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
