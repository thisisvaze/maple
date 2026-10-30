// Offline: validates the transcription request, errors, cancellation and Spark's voice context with a URLProtocol stub.
//   swiftc -swift-version 6 -parse-as-library Maple/{Transcribe,Muse,Agent,Drawing,Hershey}.swift checks/voice-check.swift -o /tmp/voice-check && /tmp/voice-check
// On the simulator, compile with the same sources as canvas-check plus this file (instead of canvas-check), and put
// MODEL_API_KEY=voice-check in the test app's Info.plist. Also checks squeeze cancellation, the toggle and saved page bubbles.
import Foundation
#if canImport(UIKit)
import AVFoundation
import UIKit
#endif

@main
struct Check {
    @MainActor static func main() async throws {
        precondition(URLProtocol.registerClass(VoiceStub.self))
        defer { URLProtocol.unregisterClass(VoiceStub.self) }
        let wav = Data([0x52, 0x49, 0x46, 0x46, 0, 255, 13, 10]) // binary sentinel, never sent to a real service
        let client = Transcribe(key: "voice-check")
        let request = try client.request(wav)
        precondition(request.url?.absoluteString == "https://api.meta.ai/v1/asr/transcribe")
        precondition(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == "Bearer voice-check")
        let boundary = request.value(forHTTPHeaderField: "Content-Type")!.components(separatedBy: "boundary=")[1]
        let body = request.httpBody!, text = String(decoding: body, as: UTF8.self)
        precondition(text.contains("name=\"request\"\r\nContent-Type: application/json\r\n\r\n"))
        precondition(text.contains(#""model":"muse-voice-transcribe-1.0""#) && text.contains(#""mode":"PUSH_TO_TALK""#))
        precondition(text.contains(#""audioEncoding":"WAV""#) && text.contains("name=\"audio\"; filename=\"question.wav\""))
        precondition(body.range(of: wav) != nil && text.hasSuffix("\r\n--\(boundary)--\r\n"), "binary audio and closing boundary survive")
        for invalid in [#"{"transcript":"   "}"#, #"{"error":"bad audio"}"#, "not JSON"] {
            do { _ = try Transcribe.text(from: Data(invalid.utf8)); preconditionFailure("bad response accepted") } catch {}
        }
        do { _ = try client.request(Data()); preconditionFailure("empty recording accepted") } catch {}
        do { _ = try Transcribe(key: "").request(wav); preconditionFailure("missing key accepted") } catch {}
        let transcript = try await client.transcribe(wav)
        precondition(transcript == "What is two plus two?")
        do {
            _ = try await Transcribe(key: "reject").transcribe(wav)
            preconditionFailure("HTTP failure accepted")
        } catch { precondition(error.localizedDescription.contains("401")) }
        let cancelled = Task { try await client.transcribe(wav) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("cancelled upload accepted") } catch {}
        let reply = try await Agent(muse: Muse(key: "voice-check")).ask(near: Data([1]), around: Data([2]), gesture: "voice", threads: [], target: nil, speech: transcript)
        precondition(reply.reply == "4")
        print("voice request, response, errors, cancellation and Spark context ok")

        #if canImport(UIKit)
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = Page(url: folder, edited: .now)
        defer {
            Store.queue.sync {}
            UserDefaults.standard.removeObject(forKey: page.viewportKey)
            try? FileManager.default.removeItem(at: folder)
        }
        precondition(!UserDefaults.standard.bool(forKey: "voiceInput"), "voice defaults off")
        let controller = CanvasController(page: page)
        controller.loadViewIfNeeded()
        controller.view.bounds.size = CGSize(width: 820, height: 1180)
        controller.viewDidLayoutSubviews()
        precondition(controller.voice == nil, "no voice module when disabled")
        let permission = AVAudioApplication.shared.recordPermission
        controller.setVoiceEnabled(true)
        let voice = controller.voice!
        precondition(voice.state == .idle && voice.button.superview === controller.view)
        precondition(AVAudioApplication.shared.recordPermission == permission, "enabling doesn't ask for permission")
        voice.squeeze(.changed)
        voice.squeeze(.ended)
        precondition(voice.state == .idle, "a squeeze must begin before it can send")
        voice.squeeze(.began)
        precondition(voice.state == .permission)
        voice.squeeze(.changed)
        voice.squeeze(.began)
        precondition(voice.state == .permission, "held or repeated squeeze events don't restart setup")
        voice.squeeze(.ended)
        await Task.yield()
        precondition(voice.state == .idle, "release during permission setup cancels a late microphone start")
        precondition(AVAudioApplication.shared.recordPermission == permission)
        voice.squeeze(.began)
        voice.squeeze(.cancelled)
        await Task.yield()
        voice.squeeze(.ended)
        precondition(voice.state == .idle, "cancelled squeezes can't send on release")
        voice.tap()
        precondition(voice.state == .permission)
        voice.squeeze(.ended)
        voice.squeeze(.cancelled)
        precondition(voice.state == .permission, "unowned squeeze events don't stop the microphone button")
        voice.cancel()
        voice.squeeze(.began)
        controller.setVoiceEnabled(false)
        await Task.yield()
        precondition(controller.voice == nil && voice.button.superview == nil && voice.state == .idle)
        precondition(AVAudioApplication.shared.recordPermission == permission, "disable cancels even a pending permission request")
        controller.setVoiceEnabled(true)
        controller.voice!.squeeze(.began)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await Task.yield()
        controller.voice!.squeeze(.ended)
        precondition(controller.voice!.state == .idle, "background cancels pending work")
        try await controller.marks.askVoice(transcript)
        precondition(controller.marks.notes.last?.mark == "voice" && controller.marks.notes.last?.reading == transcript)
        precondition(controller.marks.notes.last?.reply == "4" && controller.marks.bubbles.last?.open == true)
        controller.saveNow()
        Store.queue.sync {}
        let saved = try page.loadNotes()
        precondition(saved.last?.mark == "voice", "voice answers persist")
        let count = controller.marks.notes.count
        controller.voice!.squeeze(.began)
        controller.viewWillDisappear(false)
        await Task.yield()
        controller.voice!.squeeze(.ended)
        precondition(controller.voice!.state == .idle)
        do { try await controller.marks.askVoice(transcript); preconditionFailure("closed page accepted a voice question") } catch {}
        precondition(controller.marks.notes.count == count)
        print("voice default, toggle, squeeze/permission cancellation, background, saved bubble and page-close checks ok")
        #endif
    }
}

nonisolated final class VoiceStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.meta.ai" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let rejected = request.value(forHTTPHeaderField: "Authorization") == "Bearer reject"
        let json: String
        if request.url!.path == "/v1/asr/transcribe" {
            json = #"{"transcript":"  What is two plus two?\n","turns":[]}"#
        } else {
            let body: Data
            if let data = request.httpBody { body = data } else {
                let stream = request.httpBodyStream!
                stream.open()
                defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    precondition(n >= 0)
                    if n == 0 { break }
                    data.append(contentsOf: buffer.prefix(n))
                }
                body = data
            }
            let object = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            precondition(object["model"] as? String == "muse-spark-1.3")
            precondition((object["reasoning"] as? [String: String])?["effort"] == "minimal")
            let input = object["input"] as! [[String: Any]], content = input[0]["content"] as! [[String: String]]
            precondition(content.filter { $0["type"] == "input_image" }.count == 2)
            let context = try! JSONSerialization.jsonObject(with: Data(content.last!["text"]!.utf8)) as! [String: Any]
            precondition(context["gesture"] as? String == "voice" && context["speech"] as? String == "What is two plus two?")
            json = #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"reading\":\"What is two plus two?\",\"confidence\":\"high\",\"reply\":\"4\",\"passage\":false}"}]}]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: rejected ? 401 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
