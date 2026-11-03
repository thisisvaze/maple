// swiftc -swift-version 6 -O -parse-as-library Maple/PencilSynth.swift checks/pencil-check.swift -o /tmp/pencil-check && /tmp/pencil-check
// What the ear relies on, measured: a still pen is silent, a quicker line is louder and brighter, a heavier hand louder,
// a lifted pen falls quiet within a breath, a steady line has no pitch of its own, and nothing clips or goes non-finite.
import Foundation

@main
struct Check {
    static let rate = 48_000.0

    static func render(speed: Double, pressure: Double = 0.5, seconds: Double = 1, synth: inout PencilSynth) -> [Float] {
        var out = [Float](repeating: 0, count: Int(seconds * rate))
        out.withUnsafeMutableBufferPointer { buffer in
            var at = 0
            while at < buffer.count {  // in audio-callback-sized blocks, as the app calls it
                let n = min(256, buffer.count - at)
                synth.render(into: buffer.baseAddress! + at, count: n, speed: speed, pressure: pressure)
                at += n
            }
        }
        return out
    }

    static func steady(_ speed: Double, pressure: Double = 0.5, material: PencilSynth.Material = .pencil) -> [Float] {
        var synth = PencilSynth(rate: rate)
        synth.begin(tap: false, material: material)
        _ = render(speed: speed, pressure: pressure, seconds: 0.3, synth: &synth)  // past the onset
        return render(speed: speed, pressure: pressure, synth: &synth)
    }

    static func rms(_ x: ArraySlice<Float>) -> Double { (x.reduce(0) { $0 + Double($1 * $1) } / Double(max(x.count, 1))).squareRoot() }
    static func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }

    /// Spectral centroid from a Welch average of Hann-windowed DFTs.
    static func spectrum(_ x: [Float], size: Int = 1024) -> [Double] {
        var power = [Double](repeating: 0, count: size / 2)
        var segments = 0
        for start in stride(from: 0, to: x.count - size, by: size / 2) {
            for k in 1..<(size / 2) {
                var re = 0.0, im = 0.0
                for n in 0..<size {
                    let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(size))
                    let a = 2 * Double.pi * Double(k * n) / Double(size)
                    re += Double(x[start + n]) * w * cos(a)
                    im -= Double(x[start + n]) * w * sin(a)
                }
                power[k] += re * re + im * im
            }
            segments += 1
            if segments == 12 { break }
        }
        return power
    }

    static func centroid(_ p: [Double]) -> Double {
        let hz = rate / Double(p.count * 2)
        return p.enumerated().reduce(0) { $0 + Double($1.offset) * hz * $1.element } / max(p.reduce(0, +), 1e-30)
    }

    static func main() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "ok  " : "FAIL", what)
            if !ok { failures += 1 }
        }

        let still = steady(0)
        check(rms(still[...]) < 1e-6, "a still pen is silent (\(String(format: "%.1f", db(rms(still[...])))) dBFS)")

        let slow = steady(60), writing = steady(300), quick = steady(900)
        let levels = [slow, writing, quick].map { db(rms($0[...])) }
        print(String(format: "     60 / 300 / 900 pt/s: %.1f / %.1f / %.1f dBFS", levels[0], levels[1], levels[2]))
        check(levels[0] < levels[1] - 3 && levels[1] < levels[2] - 3, "quicker is louder")
        check(levels[1] > -42 && levels[1] < -30, "writing sits quietly under everything else")

        let spectra = [slow, writing, quick].map { spectrum($0) }
        let centroids = spectra.map(centroid)
        print(String(format: "     centroid: %.0f / %.0f / %.0f Hz", centroids[0], centroids[1], centroids[2]))
        check(centroids[0] < centroids[1] && centroids[1] < centroids[2], "quicker is brighter")
        // Graphite on drawing paper, recorded close, centres around 2–3.5 kHz at writing speed: a scratch, not a brush.
        check(centroids[1] > 1800 && centroids[1] < 3500, "writing sounds like graphite, not a brush or a hiss")

        // A steady line must not whine: no bin far above its neighbourhood's median.
        let p = spectra[1], hz = rate / Double(p.count * 2)
        var peak = 0.0, peakAt = 0.0
        for k in 8..<(p.count - 8) where Double(k) * hz > 300 && Double(k) * hz < 9000 {
            let near = p[(k - 8)...(k + 8)].sorted()[8]
            if p[k] / near > peak { peak = p[k] / near; peakAt = Double(k) * hz }
        }
        check(10 * log10(peak) < 10, String(format: "no pitch of its own (tallest bin %.1f dB over its neighbours, at %.0f Hz)", 10 * log10(peak), peakAt))

        check(db(rms(steady(300, pressure: 1)[...])) > db(rms(steady(300, pressure: 0.15)[...])) + 3, "a heavier hand is louder")

        var synth = PencilSynth(rate: rate)
        synth.begin(tap: false)
        let moving = render(speed: 300, seconds: 0.5, synth: &synth)
        let lifted = render(speed: 0, seconds: 0.3, synth: &synth)
        let after = db(rms(lifted[Int(0.12 * rate)...])) - db(rms(moving[Int(0.25 * rate)...]))
        check(after < -40, String(format: "a lifted pen is quiet within 120 ms (%.0f dB)", after))

        var tapped = PencilSynth(rate: rate)
        tapped.begin(tap: true)
        let landing = render(speed: 0, seconds: 0.05, synth: &tapped)
        check(db(rms(landing[..<Int(0.006 * rate)])) > -60 && rms(landing[Int(0.03 * rate)...]) < 1e-4, "the film's nib tap is short and soft")

        var wild = PencilSynth(rate: rate)
        wild.begin(tap: true)
        var extremes: [Float] = []
        for speed in [5000.0, .infinity, .nan, -20, 1e9, 0] { extremes += render(speed: speed, pressure: speed.isNaN ? .nan : 1, seconds: 0.2, synth: &wild) }
        check(extremes.allSatisfy { $0.isFinite && abs($0) < 0.9 }, "finite and unclipped at any speed (peak \(String(format: "%.3f", extremes.map(abs).max()!)))")

        for material in [PencilSynth.Material.eraser, .edit] {
            let quiet = steady(0, material: material), slow = steady(60, material: material)
            let normal = steady(300, material: material), fast = steady(900, material: material)
            let level = db(rms(normal[...])), centre = centroid(spectrum(normal))
            print(String(format: "     %@: %.1f dBFS, %.0f Hz", String(describing: material), level, centre))
            print(String(format: "     60 / 300 / 900 pt/s: %.1f / %.1f / %.1f dBFS", db(rms(slow[...])), level, db(rms(fast[...]))))
            check(rms(quiet[...]) < 1e-6, "\(material): stationary tool is silent")
            check(db(rms(slow[...])) + 3 < level && level + 3 < db(rms(fast[...])), "\(material): speed controls level")
            check(abs(level - levels[1]) < 6, "\(material): balanced with the pencil")
            check(material == .eraser ? centre < centroids[1] * 0.65 : centre > centroids[1] * 1.15,
                  "\(material): distinct warm rubber / fine felt spectrum")
            check(db(rms(steady(300, pressure: 1, material: material)[...])) > db(rms(steady(300, pressure: 0.15, material: material)[...])) + 3,
                  "\(material): pressure controls level")
            var tool = PencilSynth(rate: rate)
            tool.begin(tap: false, material: material)
            let moving = render(speed: 300, seconds: 0.5, synth: &tool)
            let lifted = render(speed: 0, seconds: 0.3, synth: &tool)
            check(db(rms(lifted[Int(0.12 * rate)...])) < db(rms(moving[Int(0.25 * rate)...])) - 40,
                  "\(material): lift fades quietly")
            for speed in [5000.0, .infinity, .nan, -20, 1e9, 0] {
                let audio = render(speed: speed, pressure: .nan, seconds: 0.1, synth: &tool)
                check(audio.allSatisfy { $0.isFinite && abs($0) < 0.9 }, "\(material): safe output at \(speed) pt/s")
            }
        }

        var switching = PencilSynth(rate: rate)
        for material in PencilSynth.Material.allCases + [.pencil] {
            switching.begin(tap: false, material: material)
            let start = render(speed: 900, seconds: 0.2, synth: &switching)
            check(abs(start[0]) < 0.001 && start.allSatisfy { $0.isFinite && abs($0) < 0.9 }, "\(material): soft onset when switching tools")
            _ = render(speed: 0, seconds: 0.2, synth: &switching)
        }

        print(failures == 0 ? "pencil-check: all passed" : "pencil-check: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
