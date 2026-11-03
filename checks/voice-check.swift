// Offline: validates the transcription request, errors, cancellation and Spark's voice context with a URLProtocol stub.
//   swiftc -swift-version 6 -parse-as-library Maple/{Transcribe,Muse,Memory,Agent,Drawing,Figure,Computed,Hershey}.swift checks/voice-check.swift -o /tmp/voice-check && /tmp/voice-check
// On the simulator, compile with the same sources as canvas-check plus this file (instead of canvas-check), and put
// MODEL_API_KEY=voice-check in the test app's Info.plist. Also checks squeeze cancellation, the toggle and saved page bubbles.
import Foundation
#if canImport(UIKit)
import AVFoundation
import PencilKit
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
        precondition(reply.reply == "4" && reply.boxes.isEmpty)
        let drawn = try await Agent(muse: Muse(key: "voice-check")).ask(near: Data([1]), around: Data([2]), gesture: "voice", threads: [], target: nil, speech: "Draw a triangle")
        precondition(drawn.reply.isEmpty && drawn.boxes.count == 1 && drawn.boxes[0].request == "a triangle" && drawn.boxes[0].width == 300,
                     "a spoken drawing comes back as a box to draw, not words")
        let edited = try await Agent(muse: Muse(key: "voice-check")).edit(near: Data([1]), around: Data([2]),
            targets: [.init(id: "1", kind: "picture", at: [1, 2, 3, 4], overview: [10, 20, 30, 40])],
            speech: "Move this one", previous: "Which picture?")
        precondition(edited.edits.isEmpty && edited.question == "Where should it go?", "ambiguity returns a question without edits")
        print("voice request, response, errors, cancellation, Spark context and draw_box ok")

        #if canImport(UIKit)
        let previousAI = UserDefaults.standard.object(forKey: "aiEnabled")
        UserDefaults.standard.removeObject(forKey: "aiEnabled")
        defer { UserDefaults.standard.set(previousAI, forKey: "aiEnabled") }
        precondition(Marks.aiEnabled, "AI defaults on")
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
        precondition(voice.state == .idle && voice.button.superview === controller.controls)
        precondition(controller.controls.arrangedSubviews == [controller.aiButton, voice.button], "AI sits beside Record")
        precondition(AVAudioApplication.shared.recordPermission == permission, "enabling doesn't ask for permission")
        // Audio-engine/session notifications arrive on their own queues when Record changes the audio category.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                precondition(!Thread.isMainThread)
                NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
                NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
                NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil)
                done.resume()
            }
        }
        await Task.yield()
        precondition(voice.state == .idle, "off-main audio notifications are safe and leave voice idle")
        print("background audio-engine, route and interruption callbacks ok")
        voice.squeeze(.changed)
        voice.squeeze(.ended)
        precondition(voice.state == .idle, "a squeeze must begin before it can send")
        voice.squeeze(.began)
        precondition(voice.state == .permission)
        precondition(controller.marks.voiceActive, "recording setup holds pending coral edits")
        voice.squeeze(.changed)
        voice.squeeze(.began)
        precondition(voice.state == .permission, "held or repeated squeeze events don't restart setup")
        voice.squeeze(.ended)
        await Task.yield()
        precondition(voice.state == .idle, "release during permission setup cancels a late microphone start")
        precondition(!controller.marks.voiceActive, "cancelling releases the hold without executing marks")
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
        let marks = controller.marks!
        // A spoken drawing: Maple frames a box in its own pen clear of the person's ink, then fills it like a drawn box.
        let words = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: (0 ... 40).map {
            PKStrokePoint(location: CGPoint(x: 120 + CGFloat($0) * 4, y: 300), timeOffset: Double($0) * 0.01, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: Date()))
        controller.canvas.drawing.strokes.append(words)
        let before = marks.notes.count
        try await marks.askVoice("Draw a triangle")
        precondition(marks.notes.count == before, "an empty reply with a box opens no bubble")
        marks.flush()
        let frame = controller.canvas.drawing.strokes.last!
        precondition(AgentPen.wrote(frame) && !frame.renderBounds.intersects(words.renderBounds), "the frame is Maple's ink, clear of the person's")
        for _ in 0 ..< 200 where !marks.notes.contains(where: { $0.mark == "frame" }) {
            try await Task.sleep(for: .milliseconds(50))
            marks.flush()
        }
        let filled = marks.notes.last!
        precondition(filled.mark == "frame" && filled.trigger == [Marks.id(frame)] && filled.reply == "A triangle", "the box fills: \(filled)")
        let ink = marks.strokes(of: filled)
        precondition(!ink.isEmpty && ink.allSatisfy { frame.renderBounds.insetBy(dx: -4, dy: -4).contains($0.renderBounds) }, "the drawing sits in its frame")
        controller.canvas.drawing.strokes.removeAll { Marks.id($0) == Marks.id(words) }
        print("voice draw_box: frame placement, fill and request ok")
        let drawing = controller.canvas.drawing.dataRepresentation(), notes = marks.notes
        var queuedLanded = false, staleLanded = false, disabledRan = false
        marks.enqueue { queuedLanded = true; return .init() }
        var resume: CheckedContinuation<Void, Never>?
        marks.run {
            await withCheckedContinuation { resume = $0 }
            marks.enqueue { staleLanded = true; return .init() }
        }
        while resume == nil { await Task.yield() }
        let oldWork = Array(marks.work.values)
        marks.add(Bubble(anchor: .zero, zoom: 1, turn: 0))
        _ = marks.shimmer(over: CGRect(x: 0, y: 0, width: 100, height: 100), turn: 0)
        controller.voice!.squeeze(.began)
        precondition(controller.pencilSound.suspended, "microphone setup mutes pencil playback")
        controller.toggleAI()
        precondition(!Marks.aiEnabled && !marks.enabled && !controller.voice!.button.isEnabled)
        precondition(controller.voice!.state == .idle && !controller.pencilSound.suspended, "AI off cancels voice setup")
        precondition(marks.pending.isEmpty && marks.grids.isEmpty && marks.bubbles.allSatisfy { $0.note != nil })
        marks.run { disabledRan = true }
        marks.penUp(writing: true)
        marks.look()
        marks.edit()
        controller.voice!.squeeze(.began)
        precondition(controller.voice!.state == .idle, "AI off blocks squeeze recording")
        do { try await marks.askVoice(transcript); preconditionFailure("AI off accepted a voice question") } catch {}
        let renamed = await page.nameFromInk(), handwriting = await page.handwriting()
        precondition(!renamed, "AI off blocks automatic naming")
        precondition(handwriting == nil, "AI off blocks memory reading")
        controller.saveNow()
        precondition(controller.canvas.drawing.dataRepresentation() == drawing && marks.notes == notes, "AI off preserves saved content")
        precondition(!queuedLanded && !disabledRan)
        let reopened = CanvasController(page: page)
        reopened.loadViewIfNeeded()
        precondition(!reopened.marks.enabled, "new pages inherit the saved AI setting")
        controller.cycle()
        controller.cycle()
        precondition(!controller.brushing, "AI off skips the edit brush")
        controller.toggleAI()
        resume?.resume()
        for task in oldWork { await task.value }
        marks.flush()
        precondition(!staleLanded && marks.enabled && controller.voice!.button.isEnabled, "a cancelled result stays discarded after AI is re-enabled")
        marks.penDown()
        marks.enqueue { queuedLanded = true; return .init() }
        marks.penUp(writing: false)
        try await Task.sleep(for: .seconds(1.4))
        precondition(queuedLanded, "AI on still lands queued answers after the pen rests")
        // The synth's own response is measured in checks/pencil-check.swift; here, what the app feeds it, and that it builds.
        precondition(PencilSynth.loudness(0) == 0 && PencilSynth.loudness(700) > PencilSynth.loudness(40))
        precondition(PencilSound.pressure(force: 0, maximumForce: 0) == 0.5, "speed works without a pressure sensor")
        precondition(PencilSound.pressure(force: .nan, maximumForce: 1) == 0.5 && PencilSound.pressure(force: 9, maximumForce: 1) == 1)
        _ = PencilSound()
        print("AI off, cancellation, persistence, controls and pencil sound response ok")
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
            let tools = (object["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let answered = input.contains { $0["type"] as? String == "function_call_output" }
            if let targets = context["targets"] as? [[String: Any]] {
                precondition(context["speech"] as? String == "Move this one" && context["previous"] as? String == "Which picture?")
                precondition(targets.count == 1 && targets[0]["overview"] as? [Int] == [10, 20, 30, 40])
                let format = (object["text"] as! [String: Any])["format"] as! [String: Any]
                let schema = format["schema"] as! [String: Any]
                precondition(format["strict"] as? Bool == true && (schema["required"] as! [String]).contains("question"))
                let properties = schema["properties"] as! [String: Any]
                let items = (properties["edits"] as! [String: Any])["items"] as! [String: Any]
                precondition((items["required"] as! [String]).contains("placement"), "placement participates in the strict output schema")
                json = #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"reading\":\"move the selected picture\",\"question\":\"Where should it go?\",\"edits\":[]}"}]}]}"#
            } else if context["box"] != nil {
                precondition(context["request"] as? String == "a triangle", "a spoken box carries what was asked")
                json = #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"reading\":\"a triangle\",\"kind\":\"ink\",\"say\":\"A triangle\",\"plot\":{\"expression\":\"\",\"xMin\":0,\"xMax\":1,\"yMin\":0,\"yMax\":1},\"parts\":[{\"name\":\"triangle\",\"strokes\":[[[20,180],[150,20],[280,180],[20,180]]],\"labels\":[]}]}"}]}]}"#
            } else if context["speech"] as? String == "Draw a triangle" {
                precondition(context["gesture"] as? String == "voice" && tools.contains("draw_box"), "voice can draw")
                json = answered
                    ? #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"reading\":\"Draw a triangle\",\"confidence\":\"high\",\"reply\":\"\",\"passage\":false}"}]}]}"#
                    : #"{"status":"completed","output":[{"type":"function_call","name":"draw_box","call_id":"box","arguments":"{\"request\":\"a triangle\",\"width\":300,\"height\":200}"}]}"#
            } else {
                precondition(context["gesture"] as? String == "voice" && context["speech"] as? String == "What is two plus two?")
                json = #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"reading\":\"What is two plus two?\",\"confidence\":\"high\",\"reply\":\"4\",\"passage\":false}"}]}]}"#
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: rejected ? 401 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
