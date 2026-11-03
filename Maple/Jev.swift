import Foundation

/// TypeSafe's Jev takes the first look at every mark: which gesture the newest ink makes, from the close-up, fast and
/// cheap. Muse is only asked when Jev sees a ? or an empty box. API: POST /v1/systemone, the image as a multipart part.
nonisolated struct Jev: Sendable {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    var key: String
    var model = "jev-1.13.0"

    /// The key built into the app from Secrets.xcconfig, if there is one.
    static var bundled: Jev? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "TYPESAFE_API_KEY") as? String, !key.isEmpty else { return nil }
        return Jev(key: key)
    }

    static let marks = [
        "question": "A handwritten question mark, alone or ending a sentence. A loosely curved hook and a dot or short dash below it count, even when drawn in separate pauses.",
        "circle": "A loop around existing words or a drawing.",
        "box": "A rectangle around existing words or a drawing.",
        "frame": "An empty rectangle under a label, waiting to be filled.",
        "underline": "One line under words.",
        "double_underline": "Two lines under words.",
        "strike": "A line crossing words out.",
        "scribble": "Dense scratching-out over ink.",
        "arrow": "A line with an arrowhead.",
        "dots": "An ellipsis: three dots in a row.",
        "check": "A check or tick.",
        "writing": "Ordinary writing without a question mark at its end.",
        "other": "Something else.",
    ]

    struct Verdict: Sendable {
        var mark: String  // what Maple acts on: one of `marks`, or "writing" when Jev isn't sure enough
        var top: String  // Jev's first choice
    }

    /// The gesture the red ink in `near` ends with.
    func mark(_ near: Data) async throws -> Verdict {
        let answer = try await ask(near, ["mark": ["type": "choice", "criteria": Self.marks,
            "instructions": "Red ink is the newest gesture; dark ink is context. What gesture does the red ink end with?"]])["mark"]
        let top = answer?.choice ?? "writing", probabilities = answer?.probabilities ?? [:]
        var confirmed = 0.0
        // Only an uncertain leading ? gets a second, focused look; ordinary writing keeps the fast path.
        if top == "question", let p = probabilities["question"], p >= 0.35, p < 0.75 {
            confirmed = try await ask(near, ["question": ["type": "noul", "instructions": """
                Does the newest red ink contain an intentional handwritten question mark? Look for a curved hook and its dot \
                or short dash below, allowing untidy handwriting. Letters, arrows, loops and an old black question mark do not \
                count. Red ink may also contain the end of the preceding word.
                """]])["question"]?.noul ?? 0
        }
        return Verdict(mark: Self.decide(top, probabilities, confirmedQuestion: confirmed), top: top)
    }

    // Calibration knobs: thresholds for real Pencil input, not a measured accuracy.
    /// A ? needs 0.35 from the first look and 0.85 from the focused one; any other gesture needs 0.75.
    static func decide(_ top: String, _ probabilities: [String: Double], confirmedQuestion: Double) -> String {
        if top == "question", probabilities["question", default: 0] >= 0.35, confirmedQuestion >= 0.85 { return "question" }
        return probabilities[top, default: 0] >= 0.75 ? top : "writing"
    }

    struct Answer: Decodable {
        var choice: String?
        var probabilities: [String: Double]?
        var noul: Double?
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// One systemOne call: `questions` about the image, sent as a multipart part the JSON names "near".
    func ask(_ near: Data, _ questions: [String: [String: Any]]) async throws -> [String: Answer] {
        let json = try JSONSerialization.data(withJSONObject: [
            "model": model, "state": "near", "questions": questions,
            "assets": ["near": ["type": "image", "part": "asset-0"]],
        ] as [String: Any])
        let boundary = UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json\r\n\r\n".utf8))
        body.append(json)
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"asset-0\"; filename=\"asset-0\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        body.append(near)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "TypeSafe-Danger-Zone-Images")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(errorDescription: "Jev returned \(status): \(String(decoding: data.prefix(300), as: UTF8.self))") }
        struct Response: Decodable { var answers: [String: Answer] }
        return try JSONDecoder().decode(Response.self, from: data).answers
    }
}
