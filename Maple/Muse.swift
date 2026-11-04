import Foundation

/// Meta's Muse Spark over the Responses API: https://dev.meta.ai/docs/quickstart
/// Foundation only, so `checks/muse-check.swift` can run it on the Mac.
nonisolated struct Muse: Sendable {
    enum Part: Sendable {
        case text(String)
        case png(Data)
    }

    /// The API defaults to high, which spent 662 reasoning tokens on "say hi" (28 Oct). Raise it only where thinking pays.
    enum Effort: String, Sendable { case minimal, low, medium, high }

    struct Reply: Sendable {
        let text: String
        let outputTokens: Int
        let reasoningTokens: Int
        var searched = false  // it searched the web
        var called: [String] = []  // the functions it called, in order
    }

    /// A function Muse may call. Maple runs it on the device and sends back what it returns; an error goes back as text,
    /// so Muse can try again or answer without it.
    struct Function: Sendable {
        let name: String
        let description: String
        let parameters: String  // JSON Schema for its arguments, in the strict subset
        let run: @Sendable (Data) throws -> String
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static let endpoint = URL(string: "https://api.meta.ai/v1/responses")!
    static let maxCalls = 4  // calibration knob: rounds of function calls before Muse has to answer
    var key: String
    var model = "muse-spark-1.3"

    /// The key built into the app from Secrets.xcconfig, if there is one.
    static var bundled: Muse? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "MODEL_API_KEY") as? String, !key.isEmpty else { return nil }
        return Muse(key: key)
    }

    /// `schema` (JSON Schema, strict subset) makes the reply text a JSON object that matches it. With `search`, Muse may
    /// search the web first; with `functions`, it may call them, each round's calls answered before it goes on. With
    /// `progress`, the answer streams: it gets Muse's summary of its thinking and the message being written, so far, as
    /// each piece arrives.
    func respond(_ parts: [Part], instructions: String? = nil, schema: Data? = nil, effort: Effort = .minimal, maxOutputTokens: Int = 4000,
                 search: Bool = false, functions: [Function] = [], progress: (@Sendable (_ thinking: String, _ text: String) -> Void)? = nil) async throws -> Reply {
        let content: [[String: String]] = parts.map {
            switch $0 {
            case .text(let text): ["type": "input_text", "text": text]
            case .png(let data): ["type": "input_image", "image_url": "data:image/png;base64," + data.base64EncodedString()]
            }
        }
        var input: [Any] = [["type": "message", "role": "user", "content": content]]
        var body: [String: Any] = [
            "model": model,
            "reasoning": progress == nil ? ["effort": effort.rawValue] : ["effort": effort.rawValue, "summary": "auto"],
            "max_output_tokens": maxOutputTokens,
            "store": false,  // Maple keeps its own threads; nothing needs to live on Meta's side
        ]
        if let instructions { body["instructions"] = instructions }
        if progress != nil { body["stream"] = true }
        if let schema {
            body["text"] = ["format": ["type": "json_schema", "name": "answer", "strict": true, "schema": try JSONSerialization.jsonObject(with: schema)]]
        }
        var tools: [[String: Any]] = try functions.map {
            ["type": "function", "name": $0.name, "description": $0.description, "strict": true,
             "parameters": try JSONSerialization.jsonObject(with: Data($0.parameters.utf8))]
        }
        if search { tools.append(["type": "web_search", "search_context_size": "low"]) }
        if !tools.isEmpty { body["tools"] = tools }
        // Nothing is stored on Meta's side, so each round sends the whole exchange so far: the question, Muse's output
        // items as they came, and Maple's answers to its calls.
        var searched = false, called: [String] = []
        for _ in 0...Self.maxCalls {
            body["input"] = input
            let data = try await post(body, progress: progress)
            let items = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["output"] as? [[String: Any]] ?? []
            searched = searched || items.contains { $0["type"] as? String == "web_search_call" }
            let calls = items.filter { $0["type"] as? String == "function_call" }
            guard !calls.isEmpty else {
                var reply = try Self.reply(from: data)
                (reply.searched, reply.called) = (searched, called)
                return reply
            }
            input += items
            for call in calls {
                let name = call["name"] as? String ?? "", arguments = Data((call["arguments"] as? String ?? "{}").utf8)
                let output: String
                if let function = functions.first(where: { $0.name == name }) {
                    do { output = try function.run(arguments) } catch { output = "error: \(error.localizedDescription)" }
                } else {
                    output = "error: there's no function \(name)"
                }
                called.append(name)
                input.append(["type": "function_call_output", "call_id": call["call_id"] as? String ?? "", "output": output])
            }
        }
        throw Failure("Muse kept calling functions without answering")
    }

    /// The response as JSON. Streamed, with `progress`, it's read from the server-sent events as they come, and the
    /// `response.completed` event's response is what a plain call returns.
    private func post(_ body: [String: Any], progress: (@Sendable (String, String) -> Void)?) async throws -> Data {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 120)  // high effort can think for 30 s or more
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard let progress else {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else { throw Self.failure(response, data) }
            return data
        }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw Self.failure(response, data)
        }
        // Each event is one `data:` line of JSON, as Meta sends them. The text being written grows by its deltas and
        // starts over with each new message item, so commentary before a call is never taken for the answer.
        var thinking = "", text = ""
        for try await line in bytes.lines where line.hasPrefix("data: ") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
                  let type = event["type"] as? String else { continue }  // "data: [DONE]" ends the stream
            switch type {
            case "response.output_item.added" where (event["item"] as? [String: Any])?["type"] as? String == "message": text = ""
            case "response.output_text.delta":
                text += event["delta"] as? String ?? ""
                progress(thinking, text)
            case "response.reasoning_summary_part.added" where !thinking.isEmpty: thinking += "\n"
            case "response.reasoning_summary_text.delta":
                thinking += event["delta"] as? String ?? ""
                progress(thinking, text)
            case "response.completed", "response.failed", "response.incomplete":
                return try JSONSerialization.data(withJSONObject: event["response"] ?? [:])
            case "error": throw Failure("Muse returned an error: \(event["message"] as? String ?? "unknown")")
            default: break
            }
        }
        throw Failure("Muse's stream ended early")
    }

    private static func failure(_ response: URLResponse, _ data: Data) -> Failure {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let message = (try? decoder.decode(Response.self, from: data).error?.message) ?? String(decoding: data.prefix(300), as: UTF8.self)
        return Failure("Muse returned \(status): \(message)")
    }

    /// The answer is the `output_text` of the last `message` item. The `reasoning` items hold the model's thinking, and
    /// earlier messages are commentary, like "I'll search for that" before a search.
    static func reply(from data: Data) throws -> Reply {
        let response = try decoder.decode(Response.self, from: data)
        if let message = response.error?.message { throw Failure(message) }
        guard response.status == "completed" else {
            throw Failure("Muse stopped early (\(response.incompleteDetails?.reason ?? response.status ?? "unknown"))")
        }
        let text = response.output.filter { $0.type == "message" }
            .map { ($0.content ?? []).filter { $0.type == "output_text" }.compactMap(\.text).joined() }
            .last { !$0.isEmpty } ?? ""
        guard !text.isEmpty else { throw Failure("Muse returned no text") }
        return Reply(text: text, outputTokens: response.usage?.outputTokens ?? 0,
                     reasoningTokens: response.usage?.outputTokensDetails?.reasoningTokens ?? 0)
    }

    private struct Response: Decodable {
        let status: String?
        let error: Problem?
        let incompleteDetails: Problem?
        let output: [Item]
        let usage: Usage?

        struct Problem: Decodable { let message: String?, reason: String? }
        struct Item: Decodable { let type: String, content: [Content]? }
        struct Content: Decodable { let type: String, text: String? }
        struct Usage: Decodable {
            let outputTokens: Int
            let outputTokensDetails: Details?
            struct Details: Decodable { let reasoningTokens: Int? }
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
