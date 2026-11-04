import AVFoundation
import UIKit

/// Optional voice input: hold a Pencil Pro squeeze to record, release to send. The button is an accessible alternative.
@MainActor final class Voice: NSObject, AVAudioRecorderDelegate {
    enum State { case idle, permission, recording, ready, transcribing, answering }
    private(set) var state = State.idle { didSet { update() } }
    let button = MapleButton(minimumWidth: 160)
    weak var controller: CanvasController?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var audioActive = false
    private var task: Task<Void, Never>?
    private var squeezing = false
    private var editMarks: Set<String> = []
    private var selection: [Note] = []
    private var meter: Timer?

    init(controller: CanvasController) {
        self.controller = controller
        super.init()
        button.accessibilityIdentifier = "voice-input"
        button.addAction(UIAction { [weak self] _ in self?.tap() }, for: .primaryActionTriggered)
        button.translatesAutoresizingMaskIntoConstraints = false
        controller.controls.addArrangedSubview(button)
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(resignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cancel), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: AVAudioSession.interruptionNotification, object: nil)
        update()
    }

    func squeeze(_ phase: UIPencilInteraction.Phase) {
        guard controller?.marks.enabled == true else { return }
        switch phase {
        case .began:
            guard state == .idle else { return }
            squeezing = true
            tap()
        case .ended:
            guard squeezing else { return }
            squeezing = false
            if state == .permission { cancel() } else { finish() }
        case .cancelled:
            if squeezing { cancel() }
        case .changed: break
        @unknown default:
            if squeezing { cancel() }
        }
    }

    func tap() {
        guard controller?.marks.enabled == true else { return }
        switch state {
        case .idle:
            editMarks = Set(controller?.canvas.drawing.strokes.filter(AgentPen.edit).map(Marks.id) ?? [])
            if !editMarks.isEmpty {
                guard let batch = controller?.marks.batch(editMarks, together: true) else { return fail(Muse.Failure("Already changing those marks. Try again in a moment.")) }
                selection = batch.targets
            } else { selection = [] }
            state = .permission
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    try Task.checkCancellation()
                    guard controller?.marks.agent != nil else { throw Muse.Failure("No Meta API key. Add one in Secrets.xcconfig.") }
                    let allowed = await AVAudioApplication.requestRecordPermission()
                    try Task.checkCancellation()
                    guard allowed else { throw Muse.Failure("The microphone is off for Maple. Turn it on in Settings.") }
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.record, mode: .default)
                    try session.setActive(true)
                    audioActive = true
                    let url = URL.temporaryDirectory.appending(path: "maple-voice-\(UUID().uuidString).wav")
                    recordingURL = url
                    let recorder = try AVAudioRecorder(url: url, settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 24_000,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false,
                    ])
                    self.recorder = recorder
                    recorder.delegate = self
                    recorder.isMeteringEnabled = true
                    guard recorder.record(forDuration: 60) else { throw Muse.Failure("Couldn't start the microphone. Try again.") }
                    state = .recording
                    task = nil
                } catch {
                    if !Task.isCancelled { fail(error) }
                }
            }
        case .recording, .ready: finish()
        case .permission, .transcribing, .answering: cancel()
        }
    }

    func finish() {
        guard state == .recording || state == .ready, let url = recordingURL else { return }
        squeezing = false
        state = .transcribing
        recorder?.delegate = nil
        recorder?.stop()
        deactivateAudio()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard let controller, let muse = controller.marks.agent?.muse else { throw CancellationError() }
                let wav = try Data(contentsOf: url)
                discardRecording()
                let transcript = try await Transcribe(key: muse.key).transcribe(wav)
                try Task.checkCancellation()
                state = .answering
                try await controller.marks.askVoice(transcript, editMarks: editMarks, selection: selection)
                try Task.checkCancellation()
                state = .idle
                task = nil
            } catch {
                if !Task.isCancelled { fail(error) }
            }
        }
    }

    @objc func cancel() {
        squeezing = false
        task?.cancel()
        task = nil
        discardRecording()
        state = .idle
    }

    @objc private func resignActive() {
        // The microphone permission dialog itself temporarily deactivates the app.
        if state != .permission { cancel() }
    }

    @objc nonisolated private func interrupted() {
        Task { @MainActor [weak self] in self?.cancel() }
    }

    private func discardRecording() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        deactivateAudio()
    }

    private func deactivateAudio() {
        guard audioActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioActive = false
    }

    private func fail(_ error: any Error) {
        cancel()
    }

    private func update() {
        controller?.marks.voiceActive = state != .idle
        controller?.pencilSound?.suspended = [.permission, .recording, .ready].contains(state)
        let (title, mark, hint): (String, MapleButton.Mark, String) = switch state {
        case .idle: ("Record", .symbol("mic"), "Squeeze and hold Apple Pencil Pro and ask out loud, or circle Maple's drawings with the edit brush and say what to change. Release to send, or tap here to start and stop.")
        case .permission: ("Allow mic", .loading, "Cancel microphone setup.")
        case .recording: ("Recording", .waveform, "Release the squeeze, or tap here, to send.")
        case .ready: ("Release to send", .symbol("arrow.up"), "Time's up. Release the squeeze, or tap here, to send.")
        case .transcribing: ("Transcribing", .loading, "Tap to cancel.")
        case .answering: ("Thinking", .orb, "Tap to cancel.")
        }
        let recording = state == .recording || state == .ready
        let color: UIColor = recording ? MapleStyle.coral : state == .idle ? .label : Marks.ink
        button.display(title, mark: mark, color: color, filled: state != .idle,
                       detail: state == .recording ? "0:00" : [.permission, .transcribing, .answering].contains(state) ? "×" : "")
        button.accessibilityLabel = state == .recording ? "Stop recording and send" : title
        button.accessibilityHint = hint
        meter?.invalidate()
        meter = nil
        if state == .recording {
            meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMeter() }
            }
        }
    }

    private func updateMeter() {
        guard state == .recording, let recorder else { return }
        recorder.updateMeters()
        let seconds = min(60, Int(recorder.currentTime))
        button.detail.text = String(format: "%d:%02d", seconds / 60, seconds % 60)
        button.level(CGFloat(pow(10, recorder.averagePower(forChannel: 0) / 35)))
        button.setNeedsLayout()
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, recordingURL == url, state == .recording else { return }
            guard flag else { return fail(Muse.Failure("Recording stopped early. Try again.")) }
            if squeezing {
                // The one-minute cap stops the microphone; only release sends a held recording.
                deactivateAudio()
                state = .ready
            } else {
                finish()
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, recordingURL == url else { return }
            fail(Muse.Failure("Couldn't save that recording. Try again."))
        }
    }
}
