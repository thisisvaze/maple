// Parses a recorded Muse reply and checks Jev's thresholds offline, then makes live calls in the app's order (a few
// cents): Jev reads each mark, and Muse answers a written ? and a double dot, and draws in two boxes (a diagram and a
// graph), saved as PNGs to the folder given, or the temporary folder.
//   swiftc -swift-version 6 -parse-as-library Maple/{Muse,Agent,Drawing,Hershey,Jev}.swift checks/live-check.swift -o /tmp/live-check
//   MODEL_API_KEY=... TYPESAFE_API_KEY=... /tmp/live-check [folder]
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

        // Jev's rule: a ? needs 0.35, then 0.85 from the focused look; anything else needs 0.75, or it's plain writing.
        precondition(Jev.decide("question", ["question": 0.5], confirmedQuestion: 0.9) == "question", "an unsure ? confirmed")
        precondition(Jev.decide("question", ["question": 0.5], confirmedQuestion: 0.6) == "writing", "an unsure ? not confirmed")
        precondition(Jev.decide("frame", ["frame": 0.8], confirmedQuestion: 0) == "frame", "a sure box")
        precondition(Jev.decide("frame", ["frame": 0.6], confirmedQuestion: 0) == "writing", "an unsure box")
        print("thresholds ok")

        let env = ProcessInfo.processInfo.environment
        guard let key = env["MODEL_API_KEY"], !key.isEmpty, let jevKey = env["TYPESAFE_API_KEY"], !jevKey.isEmpty else {
            return print("no MODEL_API_KEY or TYPESAFE_API_KEY: skipped the live calls")
        }
        let muse = Muse(key: key), agent = Agent(muse: muse), jev = Jev(key: jevKey)
        var start = ContinuousClock.now
        let reply = try await muse.respond([.text("What is the answer to what's written? Reply with the number only."), .png(picture([("2 + 2 = ?", false)]))])
        print("read: \(reply.text.debugDescription) in \(start.duration(to: .now)), \(reply.outputTokens) output tokens")
        precondition(reply.text.contains("4"), "Muse didn't read the picture")

        start = .now
        let questionNear = picture([("49 ", false), ("?", true)])
        let questionMark = try await jev.mark(questionNear).mark
        let jevMs = start.duration(to: .now)
        precondition(questionMark == "question", "Jev sees the ?: \(questionMark)")
        let question = try await agent.ask(near: questionNear, around: picture([("x² = 49 ", false), ("?", true)]), gesture: "question", threads: [], target: nil)
        print("question: Jev \(jevMs), then \(question) in \(start.duration(to: .now))")
        precondition(question.reply.contains("7"), "a written ? is answered")

        start = .now
        let writing = try await jev.mark(picture([("the cell ", false), ("wall", true)])).mark
        print("writing: Jev says \(writing) in \(start.duration(to: .now))")
        precondition(writing != "question" && writing != "frame", "plain writing wakes nothing")

        start = .now
        let dots = try await agent.ask(near: picture([("mitochondria", false)]), around: picture([("mitochondria", false)]), gesture: "double_dot", threads: [], target: nil)
        print("double dot: \(dots) in \(start.duration(to: .now))")
        precondition(!dots.reply.isEmpty, "a double dot is answered")

        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        let font = Hershey(try String(contentsOfFile: "Maple/futural.jhf", encoding: .ascii))
        for (label, kind) in [("water cycle", "ink"), ("y = x^2 - 4", "plot")] {
            start = .now
            let box = CGSize(width: 360, height: 240), image = boxed(label)
            let mark = try await jev.mark(image).mark
            precondition(mark == "frame", "an empty box under \(label) is a frame: \(mark)")
            let drawing = try await agent.draw(near: image, around: image, size: box, threads: [])
            let lines = try drawing.lines(in: box, font: font)
            print("box \(label.debugDescription): \(drawing.kind), \(lines.count) lines, say \(drawing.say.debugDescription) in \(start.duration(to: .now))")
            precondition(drawing.kind == kind, "expected \(kind)")
            try render(lines, box).write(to: out.appending(path: "box-\(kind).png"))
        }
        print("live ok: drawings in \(out.path)")
    }

    /// A handwritten label with an empty red box under it, as the close-up shows a new box.
    static func boxed(_ label: String) -> Data {
        let context = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        let font = CTFontCreateWithName("Bradley Hand" as CFString, 44, nil)
        let text = NSAttributedString(string: label, attributes: [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)])
        context.textPosition = CGPoint(x: 140, y: 400)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.setStrokeColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.setLineWidth(4)
        context.stroke(CGRect(x: 140, y: 60, width: 360, height: 240))
        return png(context)
    }

    /// The agent's pen lines in Maple's blue on white, at 2× the box.
    static func render(_ lines: [[CGPoint]], _ box: CGSize) -> Data {
        let context = CGContext(data: nil, width: Int(box.width * 2), height: Int(box.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: box.width * 2, height: box.height * 2))
        context.translateBy(x: 0, y: box.height * 2)
        context.scaleBy(x: 2, y: -2)  // box points are y-down
        context.setStrokeColor(CGColor(red: 0x2F / 255, green: 0x5D / 255, blue: 0xB8 / 255, alpha: 1))
        context.setLineWidth(1.4)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for line in lines { context.addLines(between: line) }
        context.strokePath()
        return png(context)
    }

    static func png(_ context: CGContext) -> Data {
        let data = NSMutableData()
        let png = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(png, context.makeImage()!, nil)
        CGImageDestinationFinalize(png)
        return data as Data
    }

    /// Runs of text in black, or red for the newest ink, on white, as a PNG.
    static func picture(_ runs: [(String, red: Bool)]) -> Data {
        let context = CGContext(data: nil, width: 640, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 320))
        let font = CTFontCreateWithName("Bradley Hand" as CFString, 56, nil)
        let text = NSMutableAttributedString()
        for (run, red) in runs {
            let color = red ? CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1) : CGColor(gray: 0.1, alpha: 1)
            text.append(NSAttributedString(string: run, attributes: [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): color]))
        }
        context.textPosition = CGPoint(x: 30, y: 136)  // Jev takes 300 to 1568 px a side
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let data = NSMutableData()
        let png = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(png, context.makeImage()!, nil)
        CGImageDestinationFinalize(png)
        return data as Data
    }
}
