import AVFoundation
import UIKit

/// Optional voice input: hold a Pencil Pro squeeze to record, release to send. The button is an accessible alternative.
@MainActor final class Voice: NSObject, AVAudioRecorderDelegate {
    enum State { case idle, permission, recording, ready, transcribing, answering }
    private(set) var state = State.idle { didSet { update() } }
    let button = UIButton(configuration: .tinted())
    weak var controller: CanvasController?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var audioActive = false
    private var task: Task<Void, Never>?
    private var squeezing = false

    init(controller: CanvasController) {
        self.controller = controller
        super.init()
        button.configuration?.cornerStyle = .capsule
        button.configuration?.imagePadding = 8
        button.configuration?.baseForegroundColor = Marks.ink
        button.accessibilityIdentifier = "voice-input"
        button.addAction(UIAction { [weak self] _ in self?.tap() }, for: .primaryActionTriggered)
        button.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            button.bottomAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(resignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cancel), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cancel), name: AVAudioSession.interruptionNotification, object: nil)
        update()
    }

    func squeeze(_ phase: UIPencilInteraction.Phase) {
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
        switch state {
        case .idle:
            state = .permission
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    try Task.checkCancellation()
                    guard controller?.marks.agent != nil else { throw Muse.Failure("The Meta API key is missing.") }
                    let allowed = await AVAudioApplication.requestRecordPermission()
                    try Task.checkCancellation()
                    guard allowed else { throw Muse.Failure("Microphone access is off. Allow it for Maple in iPad Settings to record a question.") }
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
                    guard recorder.record(forDuration: 60) else { throw Muse.Failure("Couldn't start the microphone. Please try again.") }
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
                try await controller.marks.askVoice(transcript)
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
        guard let controller, controller.view.window != nil else { return }
        let alert = UIAlertController(title: "Couldn't use voice input", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        controller.present(alert, animated: true)
    }

    private func update() {
        let (title, symbol, hint): (String, String, String) = switch state {
        case .idle: ("Record", "mic", "Squeeze and hold Apple Pencil Pro to record, then release to send. Or tap here to start and stop.")
        case .permission: ("Cancel", "xmark", "Cancel microphone setup.")
        case .recording: ("Recording…", "stop.fill", "Release the Pencil squeeze or tap here to stop and send your question.")
        case .ready: ("Release to send", "arrow.up", "One-minute limit reached. Release the Pencil squeeze or tap here to send.")
        case .transcribing: ("Transcribing…", "xmark", "Tap to cancel.")
        case .answering: ("Thinking…", "xmark", "Tap to cancel.")
        }
        button.configuration?.title = title
        button.configuration?.image = UIImage(systemName: symbol)
        button.configuration?.baseForegroundColor = state == .recording ? .systemRed : Marks.ink
        button.accessibilityLabel = state == .recording ? "Stop recording and send" : title
        button.accessibilityHint = hint
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, recordingURL == url, state == .recording else { return }
            guard flag else { return fail(Muse.Failure("The recording was interrupted. Please try again.")) }
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
            fail(Muse.Failure("Couldn't save the recording. Please try again."))
        }
    }
}
