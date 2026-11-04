// Offline: Muse's function-call rounds, the answer taken from the last message, web search, Agent's calculate tool, page names
// and streaming, against a URLProtocol stub that plays the API's side.
//   swiftc -swift-version 6 -parse-as-library Maple/{Muse,Memory,Agent,Drawing,Figure,Computed,Hershey}.swift checks/muse-check.swift -o /tmp/muse-check && /tmp/muse-check
import Foundation
import Synchronization

@main
struct Check {
    static func main() async throws {
        precondition(URLProtocol.registerClass(MuseStub.self))
        defer { URLProtocol.unregisterClass(MuseStub.self) }

        // calculate evaluates with Plot's grammar and says when it can't.
        func calculate(_ expression: String) async throws -> String {
            guard case .text(let value)? = try await Agent.calculate.run(try JSONEncoder().encode(["expression": expression])).first else { return "" }
            return value
        }
        var values: [String] = []
        for expression in ["17.3*2.9+sqrt(41)", "2^10", "1/0"] { values.append(try await calculate(expression)) }
        precondition(values == ["56.57312424", "1024", "undefined"], "calculate: \(values)")
        let refused = try? await calculate("2x")
        precondition(refused == nil, "a formula outside the grammar is refused, never run")

        // A round of calls: Muse asks, Maple answers with the computed value, and Muse's final message is the reply. The
        // commentary before the call is not part of it.
        let muse = Muse(key: "calls")
        let reply = try await muse.respond([.text("What is 17.3 * 2.9 + sqrt(41)?")], search: true, functions: [Agent.calculate])
        precondition(reply.text == #"{"reply": "56.57312424"}"#, "the last message is the answer: \(reply.text)")
        precondition(reply.called == ["calculate"] && !reply.searched)
        let second = MuseStub.bodies[1], tools = MuseStub.bodies[0]["tools"] as! [[String: Any]]
        precondition(tools.map { $0["type"] as! String } == ["function", "web_search"] && tools[0]["strict"] as? Bool == true)
        let input = second["input"] as! [[String: Any]]
        precondition(input.map { $0["type"] as! String } == ["message", "reasoning", "message", "function_call", "function_call_output"],
                     "the second round replays the exchange: \(input.map { $0["type"] as! String })")
        precondition(input.last?["call_id"] as? String == "call_1" && input.last?["output"] as? String == "56.57312424")

        // A search shows in the reply, and its commentary is left out too.
        let found = try await Muse(key: "search").respond([.text("Who won the latest Grand Prix?")], search: true)
        precondition(found.searched && found.text == #"{"reply": "Kimi Antonelli"}"#)

        // An unknown function gets an error back, not a crash; a model that never stops calling is cut off.
        _ = try await Muse(key: "unknown").respond([.text("?")], functions: [Agent.calculate])
        precondition((MuseStub.bodies.last!["input"] as! [[String: Any]]).last?["output"] as? String == "error: there's no function lookup")
        do {
            _ = try await Muse(key: "forever").respond([.text("?")], functions: [Agent.calculate])
            preconditionFailure("endless calls accepted")
        } catch {
            precondition(error.localizedDescription.contains("kept calling"))
        }

        // A page's name is its first line without quotes or full stop, and Muse gets what Maple read there and the current name.
        let name = try await Agent(muse: Muse(key: "name")).name(page: Data(), readings: ["x² = 49 ?"], current: "Equations")
        precondition(name == "Water cycle", "name: \(name)")
        let sent = ((MuseStub.bodies.last!["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]]).last!["text"] as! String
        precondition(sent.contains("- x² = 49 ?") && sent.contains("Its current name: Equations"), "name context: \(sent)")

        // A ?? goes to Muse Wonder with time to think; every other mark stays on Spark at minimal effort.
        for (gesture, model, effort) in [("double_question", "muse-wonder-1.0", "medium"), ("question", "muse-spark-1.3", "minimal"), ("equals", "muse-spark-1.3", "minimal"), ("bullet", "muse-spark-1.3", "minimal")] {
            let answer = try await Agent(muse: Muse(key: "answer")).ask(near: Data(), around: Data(), gesture: gesture, threads: [], target: nil)
            let body = MuseStub.bodies.last!
            precondition(answer.reply == (gesture == "double_question" ? "375 g" : ". 375 g") && body["model"] as? String == model && (body["reasoning"] as? [String: String])?["effort"] == effort,
                         "\(gesture) asks \(body["model"] ?? "") at \(body["reasoning"] ?? "")")
        }
        // Streamed, the answer builds up as it comes: Muse's summary of its thinking, then the final message's reply from
        // its "reply" key on, and the whole answer is the same as a plain call's. Rounds of calls stream the same way.
        let seen = Mutex<[(thinking: String, reply: String)]>([])
        let streamed = try await Agent(muse: Muse(key: "answer")).ask(near: Data(), around: Data(), gesture: "double_question", threads: [], target: nil) { thinking, reply in
            seen.withLock { $0.append((thinking, reply)) }
        }
        let streaming = MuseStub.bodies.last!
        precondition(streaming["stream"] as? Bool == true && (streaming["reasoning"] as? [String: String])?["summary"] == "auto", "a stream asks for a summary")
        let pieces = seen.withLock { $0 }
        precondition(streamed.reply == "375 g" && pieces.last?.reply == "375 g" && pieces.first?.thinking == "Working it out.", "streamed: \(pieces)")
        precondition(pieces.contains { !$0.reply.isEmpty && $0.reply != "375 g" && "375 g".hasPrefix($0.reply) }, "the reply comes in pieces: \(pieces.map(\.reply))")
        let rounds = try await Muse(key: "calls").respond([.text("What is 17.3 * 2.9 + sqrt(41)?")], search: true, functions: [Agent.calculate]) { _, _ in }
        precondition(rounds.text == #"{"reply": "56.57312424"}"# && rounds.called == ["calculate"], "streamed rounds: \(rounds.text)")
        for (json, reply) in [(#"{"confidence": "high", "reading": "x"#, ""), (#"{"reading": "x", "reply": "Say \"hi\", 2\"#, #"Say "hi", 2"#),
                              (#"{"reply": "• Done."}"#, "Done."), (#"{"reply": "done", "passage": false}"#, "done")] {
            precondition(Agent.partialReply(json) == reply, "partial reply of \(json): \(Agent.partialReply(json))")
        }
        // A function that answers with a picture sends content parts, so Muse sees the photo itself.
        let look = Muse.Function(name: "lookup", description: "Shows a photo.", parameters: #"{"type": "object", "additionalProperties": false, "properties": {}}"#) { _ in
            [.text("Taken Fri 2026-11-06 13:00:"), .jpeg(Data([0xFF, 0xD8, 0xFF]))]
        }
        let before = MuseStub.bodies.count
        _ = try await Muse(key: "unknown").respond([.text("What's on the whiteboard?")], functions: [look])
        let shown = (MuseStub.bodies[before + 1]["input"] as! [[String: Any]]).last!["output"] as! [[String: String]]
        precondition(shown.map { $0["type"]! } == ["input_text", "input_image"] && shown[1]["image_url"] == "data:image/jpeg;base64,/9j/", "\(shown)")

        print("muse ok: calculate, pictures from a function, function-call rounds, last message, search, unknown function, endless calls, page name, ?? to Wonder, streaming")
    }
}

/// Plays the Responses API: the key says which script to follow, and each request's body is kept.
nonisolated final class MuseStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [[String: Any]] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.meta.ai" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = try! JSONSerialization.jsonObject(with: Self.read(request)) as! [String: Any]
        Self.bodies.append(body)
        let answered = (body["input"] as! [[String: Any]]).contains { $0["type"] as? String == "function_call_output" }
        let reasoning = #"{"type":"reasoning","id":"rs_1","encrypted_content":"x","summary":[]}"#
        func message(_ text: String, commentary: Bool = false) -> String {
            let escaped = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
            return #"{"type":"message","role":"assistant","phase":"\#(commentary ? "commentary" : "final_answer")","content":[{"type":"output_text","text":\#(escaped)}]}"#
        }
        func call(_ name: String) -> String { #"{"type":"function_call","call_id":"call_1","name":"\#(name)","arguments":"{\"expression\":\"17.3*2.9+sqrt(41)\"}"}"# }
        let output: [String]
        switch request.value(forHTTPHeaderField: "Authorization") {
        case "Bearer calls": output = answered ? [message(#"{"reply": "56.57312424"}"#)] : [reasoning, message("Let me work that out.", commentary: true), call("calculate")]
        case "Bearer search": output = [message("I'll search for the latest result.", commentary: true), #"{"type":"web_search_call","id":"ws_1","status":"completed"}"#, message(#"{"reply": "Kimi Antonelli"}"#)]
        case "Bearer name": output = [message("\"Water cycle.\"\nIt shows evaporation and rain.")]
        case "Bearer unknown": output = answered ? [message(#"{"reply": "done"}"#)] : [call("lookup")]
        case "Bearer answer": output = [message(#"{"reading": "75% of 500 g =", "confidence": "high", "reply": ". 375 g", "passage": false, "remember": [], "forget": []}"#)]
        default: output = [call("calculate")]
        }
        let json = #"{"status":"completed","output":[\#(output.joined(separator: ","))],"usage":{"output_tokens":10}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body["stream"] as? Bool == true ? Self.streamed(output, json) : json).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    /// The same output as server-sent events: a summary line, each message's text three characters at a time, then the
    /// whole response.
    static func streamed(_ output: [String], _ json: String) -> String {
        var events = [#"{"type":"response.reasoning_summary_text.delta","delta":"Working it out."}"#]
        for item in output.compactMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }) where item["type"] as? String == "message" {
            events.append(#"{"type":"response.output_item.added","item":{"type":"message"}}"#)
            let text = (item["content"] as! [[String: Any]])[0]["text"] as! String
            for start in stride(from: 0, to: text.count, by: 3) {
                let piece = String(decoding: try! JSONEncoder().encode(String(text.dropFirst(start).prefix(3))), as: UTF8.self)
                events.append(#"{"type":"response.output_text.delta","delta":\#(piece)}"#)
            }
        }
        events.append(#"{"type":"response.completed","response":\#(json)}"#)
        return events.map { "event: e\ndata: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
    }

    static func read(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        let stream = request.httpBodyStream!
        stream.open()
        defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer.prefix(n))
        }
        return data
    }
}
