import Foundation

/// Muse Voice Transcribe's file endpoint: https://dev.meta.ai/docs/speech-to-text#transcribe-a-file
nonisolated struct Transcribe: Sendable {
    let key: String

    func transcribe(_ wav: Data) async throws -> String {
        try Task.checkCancellation()
        let (data, response) = try await URLSession.shared.data(for: request(wav))
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Muse.Failure("Voice transcription failed (HTTP \(status)). Please try again.") }
        return try Self.text(from: data)
    }

    func request(_ wav: Data) throws -> URLRequest {
        guard !key.isEmpty else { throw Muse.Failure("The Meta API key is missing.") }
        guard !wav.isEmpty, wav.count < 31_000_000 else { throw Muse.Failure("The recording is empty or too large.") }
        let boundary = UUID().uuidString
        let settings = #"{"model":"muse-voice-transcribe-1.0","mode":"PUSH_TO_TALK","audioEncoding":"WAV"}"#
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json\r\n\r\n\(settings)\r\n".utf8)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"question.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "https://api.meta.ai/v1/asr/transcribe")!, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    static func text(from data: Data) throws -> String {
        struct Reply: Decodable { var transcript: String }
        let text = try JSONDecoder().decode(Reply.self, from: data).transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Muse.Failure("No speech was heard. Please record your question again.") }
        return text
    }
}
