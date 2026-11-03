// Run on the connected iPad after granting Maple microphone access:
// xcodebuild test -project Maple.xcodeproj -scheme Maple -destination 'id=<iPad UDID>' -only-testing:MapleDeviceChecks
import AVFoundation
import Testing
import UIKit
@testable import Maple

@Suite(.serialized) @MainActor struct DeviceChecks {
    @Test func recordAndCancelOnDevice() async throws {
        try #require(AVAudioApplication.shared.recordPermission == .granted, "Grant Maple microphone access before this hardware check.")
        let folder = URL.temporaryDirectory.appending(path: "maple-audio-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let controller = CanvasController(page: Page(url: folder, edited: .now))
        controller.loadViewIfNeeded()
        controller.setAIEnabled(true)
        controller.setVoiceEnabled(true)
        let voice = try #require(controller.voice)
        let previousFiles = Set(try FileManager.default.contentsOfDirectory(atPath: URL.temporaryDirectory.path))
        defer {
            voice.cancel()
            controller.marks.stop()
            controller.turner.isHidden = true
            Store.queue.sync {}
            try? FileManager.default.removeItem(at: folder)
        }

        for (index, material) in PencilSynth.Material.allCases.enumerated() {
            controller.toolButtons[index].sendActions(for: .primaryActionTriggered)
            #expect(controller.soundMaterial == material)
            voice.button.sendActions(for: .primaryActionTriggered)
            for _ in 0 ..< 100 where voice.state == .permission {
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(voice.state == .recording, "The real microphone must start, not just permission setup.")
            try await Task.sleep(for: .milliseconds(1400))
            #expect(voice.state == .recording)
            #expect(voice.button.detail.text != "0:00", "The recorder and its meter timer must advance.")
            #expect(controller.pencilSound.suspended)
            // Reproduce the audio thread's notifications while capture is active; no audio is uploaded.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
                    NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
                        userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
                    NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil)
                    done.resume()
                }
            }
            for _ in 0 ..< 100 where voice.state != .idle {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(voice.state == .idle)
            #expect(!controller.pencilSound.suspended)
            let files = Set(try FileManager.default.contentsOfDirectory(atPath: URL.temporaryDirectory.path)).subtracting(previousFiles)
            #expect(!files.contains { $0.hasPrefix("maple-voice-") && $0.hasSuffix(".wav") }, "Cancellation removes this test's captured audio.")
        }
    }
}
