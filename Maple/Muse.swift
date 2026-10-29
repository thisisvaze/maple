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
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static let endpoint = URL(string: "https://api.meta.ai/v1/responses")!
    var key: String
    var model = "muse-spark-1.3"

    /// The key built into the app from Secrets.xcconfig, if there is one.
    static var bundled: Muse? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "MODEL_API_KEY") as? String, !key.isEmpty else { return nil }
        return Muse(key: key)
    }

    /// `schema` (JSON Schema, strict subset) makes the reply text a JSON object that matches it.
    func respond(_ parts: [Part], instructions: String? = nil, schema: Data? = nil, effort: Effort = .minimal, maxOutputTokens: Int = 4000) async throws -> Reply {
        let content: [[String: String]] = parts.map {
            switch $0 {
            case .text(let text): ["type": "input_text", "text": text]
            case .png(let data): ["type": "input_image", "image_url": "data:image/png;base64," + data.base64EncodedString()]
            }
        }
        var body: [String: Any] = [
            "model": model,
            "input": [["type": "message", "role": "user", "content": content]],
            "reasoning": ["effort": effort.rawValue],
            "max_output_tokens": maxOutputTokens,
            "store": false,  // Maple keeps its own threads; nothing needs to live on Meta's side
        ]
        if let instructions { body["instructions"] = instructions }
        if let schema {
            body["text"] = ["format": ["type": "json_schema", "name": "answer", "strict": true, "schema": try JSONSerialization.jsonObject(with: schema)]]
        }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 120)  // high effort can think for 30 s or more
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? Self.decoder.decode(Response.self, from: data).error?.message) ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw Failure("Muse returned \(status): \(message)")
        }
        return try Self.reply(from: data)
    }

    /// The answer is the `output_text` of the `message` item; the `reasoning` item before it holds the model's thinking.
    static func reply(from data: Data) throws -> Reply {
        let response = try decoder.decode(Response.self, from: data)
        if let message = response.error?.message { throw Failure(message) }
        guard response.status == "completed" else {
            throw Failure("Muse stopped early (\(response.incompleteDetails?.reason ?? response.status ?? "unknown"))")
        }
        let text = response.output.filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap(\.text).joined()
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
