// Parses a recorded Muse response, then asks Muse Spark to read a picture of "2 + 2 = ?" (one live call, under a cent).
//   swiftc -swift-version 6 -parse-as-library Maple/Muse.swift checks/muse-check.swift -o /tmp/muse-check
//   MODEL_API_KEY=... /tmp/muse-check
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct Check {
    static func main() async throws {
        // Trimmed from a real muse-spark-1.3 response, 28 Oct 2026.
        let recorded = Data("""
        {"model":"muse-spark-1.3","status":"completed","error":null,"incomplete_details":null,
         "output":[{"type":"reasoning","id":"rs_1","summary":[],"status":"completed"},
                   {"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hi, how are you today?","annotations":[]}]}],
         "usage":{"input_tokens":14,"output_tokens":678,"output_tokens_details":{"reasoning_tokens":662},"total_tokens":692}}
        """.utf8)
        let parsed = try Muse.reply(from: recorded)
        precondition(parsed.text == "Hi, how are you today?" && parsed.outputTokens == 678 && parsed.reasoningTokens == 662, "parse: \(parsed)")
        let cut = Data(#"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#.utf8)
        do { _ = try Muse.reply(from: cut); preconditionFailure("a cut-off answer must throw") } catch {}
        print("parse ok")

        guard let key = ProcessInfo.processInfo.environment["MODEL_API_KEY"], !key.isEmpty else { return print("no MODEL_API_KEY: skipped the live call") }
        let start = ContinuousClock.now
        let reply = try await Muse(key: key).respond([.text("What is the answer to what's written? Reply with the number only."), .png(picture("2 + 2 = ?"))])
        print("live: \(reply.text.debugDescription) in \(start.duration(to: .now)), \(reply.outputTokens) output tokens (\(reply.reasoningTokens) reasoning)")
        precondition(reply.text.contains("4"), "Muse didn't read the picture")
        print("live ok")
    }

    /// `text` in black on white, as a PNG.
    static func picture(_ text: String) -> Data {
        let context = CGContext(data: nil, width: 480, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 160))
        let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 40, y: 56)
        CTLineDraw(line, context)
        let data = NSMutableData()
        let png = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(png, context.makeImage()!, nil)
        CGImageDestinationFinalize(png)
        return data as Data
    }
}
