import AVFoundation
import UIKit

/// A small, dry pencil recording, shaped by screen speed and pressure. Touches still belong entirely to PencilKit.
final class PencilSound: NSObject {
    var suspended = false { didSet { if suspended { stop() } } }
    private var player: AVAudioPlayer?
    private var displayLink: CADisplayLink?
    private var previous: (point: CGPoint, time: TimeInterval)?
    private var lastMotion = 0.0
    private var targetVolume: Float = 0
    private var targetRate: Float = 1
    private var audioActive = false

    override init() {
        super.init()
        if let url = Bundle.main.url(forResource: "pencil", withExtension: "wav") {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.numberOfLoops = -1
                player.enableRate = true
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
            stop()
            previous = (touch.location(in: view), touch.timestamp)
        case .moved:
            let point = touch.location(in: view), time = touch.timestamp
            defer { previous = (point, time) }
            guard let previous, time > previous.time else { return }
            let speed = hypot(point.x - previous.point.x, point.y - previous.point.y) / (time - previous.time)
            let response = Self.response(speed: speed, force: touch.force, maximumForce: touch.maximumPossibleForce)
            targetVolume = response.volume
            targetRate = response.rate
            lastMotion = CACurrentMediaTime()
            if targetVolume > 0 { play() }
        case .ended, .cancelled:
            previous = nil
            targetVolume = 0
        default: break
        }
    }

    // Calibration: quiet by default; screen points keep the feel the same at every canvas zoom and rotation.
    nonisolated static func response(speed: Double, force: Double, maximumForce: Double) -> (volume: Float, rate: Float) {
        guard speed.isFinite, speed > 3 else { return (0, 1) }
        let motion = sqrt(min(speed / 800, 1))
        // Apple Pencil USB-C has no pressure sensor; speed still gives it a natural response.
        let pressure = maximumForce > 0 && force.isFinite && maximumForce.isFinite ? min(max(force / maximumForce, 0), 1) : 0.5
        return (Float(0.16 * motion * (0.3 + 0.7 * sqrt(pressure))), Float(0.8 + 0.55 * motion))
    }

    private func play() {
        guard displayLink == nil, let player else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default) // mixes with music and respects the silent switch
            try session.setActive(true)
            audioActive = true
            player.volume = 0
            player.rate = targetRate
            guard player.play() else { stop(); return }
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } catch {
            stop()
            logger.error("pencil playback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func tick() {
        guard let player else { return }
        let target = CACurrentMediaTime() - lastMotion < 0.06 ? targetVolume : 0
        player.volume += (target - player.volume) * 0.4
        player.rate += (targetRate - player.rate) * 0.25
        if target == 0, player.volume < 0.001 { silence() }
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
