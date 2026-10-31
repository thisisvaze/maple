import AVFoundation
import UIKit

/// Skuzic's continuous paper texture, shaped by screen speed and pressure. Touches still belong entirely to PencilKit.
final class PencilSound: NSObject {
    var suspended = false { didSet { if suspended { stop() } } }
    private var player: AVAudioPlayer?
    private var displayLink: CADisplayLink?
    private var previous: (point: CGPoint, time: TimeInterval)?
    private var speed = 0.0
    private var lastMotion = 0.0
    private var targetVolume: Float = 0
    private var audioActive = false

    override init() {
        super.init()
        if let url = Bundle.main.url(forResource: "pencil", withExtension: "wav") {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.numberOfLoops = -1
                player.volume = 0
                self.player = player
            } catch { logger.error("pencil sound unavailable: \(error.localizedDescription, privacy: .public)") }
        }
        for name in [AVAudioSession.interruptionNotification, UIApplication.willResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(stop), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged), name: AVAudioSession.routeChangeNotification, object: nil)
    }

    func touch(_ touch: UITouch, in view: UIView) {
        guard !suspended else { return }
        switch touch.phase {
        case .began:
            speed = 0
            targetVolume = 0
            previous = (touch.location(in: view), touch.timestamp)
        case .moved:
            let point = touch.location(in: view), time = touch.timestamp
            guard let previous, time > previous.time else { return }
            let dt = time - previous.time
            let measured = hypot(point.x - previous.point.x, point.y - previous.point.y) / dt
            speed += (measured - speed) * (1 - exp(-dt / 0.040)) // Skuzic's 40 ms motion smoothing
            self.previous = (point, time)
            targetVolume = Self.volume(speed: speed, force: touch.force, maximumForce: touch.maximumPossibleForce)
            lastMotion = CACurrentMediaTime()
            if targetVolume > 0 { play() }
        case .ended, .cancelled:
            previous = nil
            targetVolume = 0
        default: break
        }
    }

    // Calibration: quiet by default; screen points keep the feel the same at every canvas zoom and rotation.
    nonisolated static func volume(speed: Double, force: Double, maximumForce: Double) -> Float {
        guard speed.isFinite, speed > 3 else { return 0 }
        let motion = sqrt(min(speed / 800, 1))
        // Apple Pencil USB-C has no pressure sensor; speed still gives it a natural response.
        let pressure = maximumForce > 0 && force.isFinite && maximumForce.isFinite ? min(max(force / maximumForce, 0), 1) : 0.5
        return Float(0.16 * motion * (0.3 + 0.7 * sqrt(pressure)))
    }

    private func play() {
        guard displayLink == nil, let player else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default) // mixes with music and respects the silent switch
            try session.setActive(true)
            audioActive = true
            player.volume = 0
            guard player.play() else { stop(); return }
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } catch {
            stop()
            logger.error("pencil playback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let player else { return }
        let moving = CACurrentMediaTime() - lastMotion < 0.06
        let target = moving ? targetVolume : 0
        let tau = if previous == nil { 0.025 } else if moving { 0.015 } else { 0.06 }
        let dt = link.targetTimestamp - link.timestamp
        player.volume += (target - player.volume) * Float(1 - exp(-dt / tau))
        // A pause inside one stroke changes gain only; never restart the sound under a continuous line.
        if previous == nil, player.volume < 0.001 { silence() }
    }

    @objc func stop() {
        previous = nil
        targetVolume = 0
        silence()
    }

    @objc private func routeChanged(_ notification: Notification) {
        guard notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt != AVAudioSession.RouteChangeReason.categoryChange.rawValue else { return }
        stop()
    }

    private func silence() {
        displayLink?.invalidate()
        displayLink = nil
        player?.volume = 0
        player?.pause()
        if audioActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioActive = false
        }
    }
}
