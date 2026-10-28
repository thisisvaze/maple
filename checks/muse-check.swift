// Parses a recorded Muse response, then makes four live calls (a few cents): Muse reads "2 + 2 = ?" from a PNG, and the
// agent answers a written ?, ignores plain writing and answers a double dot.
//   swiftc -swift-version 6 -parse-as-library Maple/Muse.swift Maple/Agent.swift checks/muse-check.swift -o /tmp/muse-check
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

        guard let key = ProcessInfo.processInfo.environment["MODEL_API_KEY"], !key.isEmpty else { return print("no MODEL_API_KEY: skipped the live calls") }
        let muse = Muse(key: key), agent = Agent(muse: muse)
        var start = ContinuousClock.now
        let reply = try await muse.respond([.text("What is the answer to what's written? Reply with the number only."), .png(picture([("2 + 2 = ?", false)]))])
        print("read: \(reply.text.debugDescription) in \(start.duration(to: .now)), \(reply.outputTokens) output tokens")
        precondition(reply.text.contains("4"), "Muse didn't read the picture")

        start = .now
        let question = try await agent.ask(near: picture([("49 ", false), ("?", true)]), around: picture([("x² = 49 ", false), ("?", true)]), gesture: nil, threads: [], target: nil)
        print("question: \(question) in \(start.duration(to: .now))")
        precondition(question.mark == "question" && question.reply.contains("7") && question.steps.count == 2, "a written ? is answered, with a nudge and a hint")

        start = .now
        let writing = try await agent.ask(near: picture([("the cell ", false), ("wall", true)]), around: picture([("the cell ", false), ("wall", true)]), gesture: nil, threads: [], target: nil)
        print("writing: \(writing) in \(start.duration(to: .now))")
        precondition(writing.mark == "other" && writing.reply.isEmpty, "plain writing wakes nothing")

        start = .now
        let dots = try await agent.ask(near: picture([("mitochondria", false)]), around: picture([("mitochondria", false)]), gesture: "double_dot", threads: [], target: nil)
        print("double dot: \(dots) in \(start.duration(to: .now))")
        precondition(!dots.reply.isEmpty && dots.steps.isEmpty, "a double dot is answered")
        print("live ok")
    }

    /// Runs of text in black, or red for the newest ink, on white, as a PNG.
    static func picture(_ runs: [(String, red: Bool)]) -> Data {
        let context = CGContext(data: nil, width: 640, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 160))
        let font = CTFontCreateWithName("Bradley Hand" as CFString, 56, nil)
        let text = NSMutableAttributedString()
        for (run, red) in runs {
            let color = red ? CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1) : CGColor(gray: 0.1, alpha: 1)
            text.append(NSAttributedString(string: run, attributes: [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): color]))
        }
        context.textPosition = CGPoint(x: 30, y: 56)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let data = NSMutableData()
        let png = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(png, context.makeImage()!, nil)
        CGImageDestinationFinalize(png)
        return data as Data
    }
}
