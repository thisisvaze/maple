import CoreGraphics
import Foundation

/// Meta's Muse Image paints and repaints pictures: https://dev.meta.ai/docs/ Foundation only, like Muse.
nonisolated struct MuseImage: Sendable {
    static let endpoint = URL(string: "https://api.meta.ai/v1/images")!
    static let strength = "low"  // calibration knob: 11 s a picture, against 24 s at high (29 Oct)
    static let longSide = 1536.0  // calibration knob: pixels asked for; what comes back drifts from this
    var key: String
    var model = "muse-image-1.0"

    /// The key built into the app from Secrets.xcconfig, if there is one.
    static var bundled: MuseImage? { Muse.bundled.map { MuseImage(key: $0.key) } }

    /// A picture of `prompt` at about `ratio`, as WebP. With `search`, it may look up what something really looks like.
    func paint(_ prompt: String, ratio: CGSize, search: Bool = false) async throws -> Data {
        try await post("generations", ["prompt": prompt, "size": Self.size(ratio), "tool_enablement": Self.tools(search)])
    }

    /// What Maple traces into an ink drawing (see Trace): black lines and flat colour in its four fill pencils, on white,
    /// with no text, which image models garble; Muse writes the labels.
    static let lineArt = "Simple, clean line drawing, like a careful notebook sketch: confident black outlines of even width, and flat colour fills only in pale yellow (#F7DC6E), soft green (#7FC48E), light blue (#86B4EC) or pink (#F09BBD) where colour helps; everything else white. White background. No shading, gradients, texture or shadows, and no text, letters or numbers."

    /// Line art of `subject`, as Muse Spark describes it for an ink drawing, at about `ratio`.
    func lineArt(_ subject: String, ratio: CGSize) async throws -> Data {
        try await post("generations", ["prompt": subject + ". " + Self.lineArt, "size": Self.size(ratio), "tool_enablement": Self.tools(false)])
    }

    /// `ratio` as the size Muse Image is asked for: it sets the shape, not the pixels that come back.
    static func size(_ ratio: CGSize) -> String {
        let scale = longSide / max(ratio.width, ratio.height, 1)
        return "\(Int(max(ratio.width * scale, longSide / 16)))x\(Int(max(ratio.height * scale, longSide / 16)))"
    }

    /// `images`, PNGs, changed as `instruction` says. There are no masks: a copy with the part marked shows where.
    func repaint(_ images: [Data], _ instruction: String) async throws -> Data {
        try await post("edits", ["prompt": instruction, "tool_enablement": Self.tools(false),
                                 "images": images.map { ["image_url": "data:image/png;base64," + $0.base64EncodedString()] }])
    }

    static func tools(_ search: Bool) -> [String: Bool] {
        ["enable_web_search": search, "enable_image_search": search, "enable_shell": false]
    }

    private func post(_ path: String, _ fields: [String: Any], retrying: Bool = true) async throws -> Data {
        var request = URLRequest(url: Self.endpoint.appending(path: path), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = fields
        (body["model"], body["n"], body["output_format"], body["response_format"], body["reasoning_strength"]) = (model, 1, "webp", "b64_json", Self.strength)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 503, retrying {
            try await Task.sleep(for: .seconds(2))
            return try await post(path, fields, retrying: false)
        }
        struct Reply: Decodable {
            struct Picture: Decodable { let b64_json: String? }
            struct Problem: Decodable { let code: String?, message: String? }
            let data: [Picture]?
            let error: Problem?
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        if reply?.error?.code == "content_policy_violation" { throw Muse.Failure("Muse Image won't paint that") }
        guard status == 200, let encoded = reply?.data?.first?.b64_json, let picture = Data(base64Encoded: encoded) else {
            throw Muse.Failure("Muse Image returned \(status): \(reply?.error?.message ?? String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return picture
    }
}
