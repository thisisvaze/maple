import AVFoundation
import Synchronization
import UIKit

/// Pencil, rubber and felt on paper, made as they're drawn by PencilSynth on the audio thread: touches steer it with the
/// speed in screen points (the same feel at every zoom and turn) and its pressure. Touches still belong entirely to
/// PencilKit. It mixes with music, respects the silent switch, and lets go of the audio session a moment after the pen
/// lifts.
final class PencilSound: NSObject {
    var suspended = false { didSet { if suspended { stop() } } }
    private let engine = AVAudioEngine()
    private let pen = Pen()
    private var previous: (point: CGPoint, time: TimeInterval)?
    private var speed = 0.0
    private var idle: Timer?
    private var audioActive = false

    override init() {
        super.init()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let source = Self.source(pen, format: format)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()  // so the first stroke doesn't wait on the audio hardware
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification, .AVAudioEngineConfigurationChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(audioChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(stop), name: UIApplication.willResignActiveNotification, object: nil)
    }

    func touch(_ touch: UITouch, in view: UIView, material: PencilSynth.Material) {
        guard !suspended else { return }
        let pressure = Self.pressure(force: touch.force, maximumForce: touch.maximumPossibleForce)
        switch touch.phase {
        case .began:
            speed = 0
            previous = (touch.location(in: view), touch.timestamp)
            pen.begin(pressure: pressure, at: touch.timestamp, material: material)
            start()
        case .moved:
            let point = touch.location(in: view), time = touch.timestamp
            guard let previous, time > previous.time else { return }
            let dt = time - previous.time
            let measured = hypot(point.x - previous.point.x, point.y - previous.point.y) / dt
            speed += (measured - speed) * (1 - exp(-dt / 0.040))  // Skuzic's 40 ms motion smoothing
            self.previous = (point, time)
            pen.steer(speed: speed, pressure: pressure, at: time)
        case .ended, .cancelled:
            previous = nil
            pen.lift()
            idle?.invalidate()
            idle = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { if self?.previous == nil { self?.silence() } }
            }
        default: break
        }
    }

    /// Apple Pencil USB-C has no pressure sensor; it gets the middle, and speed still gives it a natural response.
    nonisolated static func pressure(force: Double, maximumForce: Double) -> Double {
        maximumForce > 0 && force.isFinite && maximumForce.isFinite ? min(max(force / maximumForce, 0), 1) : 0.5
    }

    private func start() {
        idle?.invalidate()
        guard !engine.isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default)  // mixes with music and respects the silent switch
            try session.setActive(true)
            audioActive = true
            try engine.start()
        } catch {
            silence()
            logger.error("pencil sound failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc func stop() {
        previous = nil
        pen.lift()
        silence()
    }

    @objc nonisolated private func audioChanged(_ notification: Notification) {
        if notification.name == AVAudioSession.routeChangeNotification,
           notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.categoryChange.rawValue { return }
        // Audio notifications arrive on the engine/session queue, including when Record changes the category.
        Task { @MainActor [weak self] in self?.stop() }
    }

    private func silence() {
        idle?.invalidate()
        idle = nil
        if engine.isRunning { engine.stop() }  // the next stroke starts it again
        if audioActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioActive = false
        }
    }

    /// The audio thread's side: one synth, steered by `pen`. A pen that stops moving goes quiet 60 ms later, like a
    /// real one, even though the Pencil stops sending samples while it rests.
    nonisolated private static func source(_ pen: Pen, format: AVAudioFormat) -> AVAudioSourceNode {
        let paper = PencilVoice(PencilSynth(rate: format.sampleRate))
        return AVAudioSourceNode(format: format) { _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let stroke = pen.stroke.load(ordering: .acquiring)
            if stroke != paper.stroke {
                paper.stroke = stroke
                let material = PencilSynth.Material(rawValue: pen.material.load(ordering: .relaxed)) ?? .pencil
                paper.synth.begin(tap: false, material: material)  // a real Pencil already taps the glass
            }
            let moving = pen.touching.load(ordering: .relaxed)
                && ProcessInfo.processInfo.systemUptime - Double(bitPattern: pen.moved.load(ordering: .relaxed)) < 0.06
            let speed = moving ? Double(bitPattern: pen.speed.load(ordering: .relaxed)) : 0
            paper.synth.render(into: out, count: Int(frames), speed: speed, pressure: Double(bitPattern: pen.pressure.load(ordering: .relaxed)))
            return noErr
        }
    }
}

/// What the touch thread tells the audio thread, without locks: material, speed, pressure and motion time.
nonisolated private final class Pen: Sendable {
    let speed = Atomic<UInt64>(0), pressure = Atomic<UInt64>(0.5.bitPattern), moved = Atomic<UInt64>(0)
    let touching = Atomic<Bool>(false), stroke = Atomic<Int>(0)
    let material = Atomic<UInt64>(PencilSynth.Material.pencil.rawValue)

    func begin(pressure: Double, at time: TimeInterval, material: PencilSynth.Material) {
        self.material.store(material.rawValue, ordering: .relaxed)
        steer(speed: 0, pressure: pressure, at: time)
        touching.store(true, ordering: .relaxed)
        stroke.add(1, ordering: .releasing)
    }

    func steer(speed: Double, pressure: Double, at time: TimeInterval) {
        self.speed.store(speed.bitPattern, ordering: .relaxed)
        self.pressure.store(pressure.bitPattern, ordering: .relaxed)
        moved.store(time.bitPattern, ordering: .relaxed)  // UITouch time is system uptime, like the audio thread's clock
    }

    func lift() { touching.store(false, ordering: .relaxed) }
}

/// The synth, owned by the audio thread alone.
nonisolated private final class PencilVoice: @unchecked Sendable {
    var synth: PencilSynth
    var stroke = 0
    init(_ synth: PencilSynth) { self.synth = synth }
}
