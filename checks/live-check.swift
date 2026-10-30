// Parses a recorded Muse reply, checks Jev's thresholds and the schemas offline, then makes live calls in the app's order
// (a few cents): Jev reads each mark, and Muse answers a written ? and a double dot, draws in two boxes (a diagram, in
// named parts, and a graph), and takes two edits: a drawing's button relabelled, and an answer rewritten. The drawings
// are saved as PNGs to the folder given, or the temporary folder.
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
        for schema in [Agent.schema, Agent.drawSchema, Agent.editSchema] { _ = try JSONSerialization.jsonObject(with: schema) }
        print("schemas ok")

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
        precondition(question.reply.contains("7") && !question.passage, "a written ? is answered, in ink")

        start = .now
        let sum = picture([("17.3 × 2.9 + √41 ", false), ("?", true)])  // 56.573…
        let worked = try await agent.ask(near: sum, around: sum, gesture: "question", threads: [], target: nil)
        print("worked out: \(worked) in \(start.duration(to: .now))")
        precondition(worked.calculated > 0 && worked.reply.contains("56.57"), "the app works the number out for Muse")

        start = .now
        let news = picture([("latest F1 race winner ", false), ("?", true)])
        let current = try await agent.ask(near: news, around: news, gesture: "question", threads: [], target: nil)
        print("current: \(current) in \(start.duration(to: .now))")
        precondition(current.searched, "something current is searched for")

        start = .now
        let named = picture([("Gettysburg Address ", false), ("?", true)])  // fits the 640 px picture
        let quote = try await agent.ask(near: named, around: named, gesture: "question", threads: [], target: nil)
        print("exact text: \(quote) in \(start.duration(to: .now))")
        precondition(quote.passage && quote.reply.contains("Four score"), "exact text is marked, so it stays a quiet dot")

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
            print("box \(label.debugDescription): \(drawing.kind), \(lines.count) lines in parts \(drawing.parts.map(\.name)), say \(drawing.say.debugDescription) in \(start.duration(to: .now))")
            precondition(drawing.kind == kind, "expected \(kind)")
            precondition(kind == "plot" || drawing.parts.count > 1 && drawing.parts.allSatisfy { !$0.name.isEmpty }, "drawn in named parts")
            try render(lines, box).write(to: out.appending(path: "box-\(kind).png"))
        }

        // The edit brush, in red: a circle round a login screen's button and "Log in" beside it change that part only.
        let none = Drawing.Graph(expression: "", xMin: 0, xMax: 0, yMin: 0, yMax: 0), box = CGSize(width: 300, height: 360), corner = CGPoint(x: 60, y: 70)
        func rect(_ r: CGRect) -> [[Double]] { [[r.minX, r.minY], [r.maxX, r.minY], [r.maxX, r.maxY], [r.minX, r.maxY], [r.minX, r.minY]].map { $0.map { Double($0) } } }
        let button = CGRect(x: 70, y: 250, width: 160, height: 50)
        let login = Drawing(reading: "login screen", kind: "ink", say: "A login screen with email and password fields and a Sign in button", parts: [
            Drawing.Part(name: "title", strokes: [], labels: [Drawing.Label(text: "Welcome", x: 66, y: 34, size: 24)]),
            Drawing.Part(name: "email field", strokes: [rect(CGRect(x: 30, y: 100, width: 240, height: 40))], labels: [Drawing.Label(text: "Email", x: 40, y: 114, size: 12)]),
            Drawing.Part(name: "password field", strokes: [rect(CGRect(x: 30, y: 165, width: 240, height: 40))], labels: [Drawing.Label(text: "Password", x: 40, y: 179, size: 12)]),
            Drawing.Part(name: "sign in button", strokes: [rect(button)], labels: [Drawing.Label(text: "Sign in", x: 105, y: 268, size: 16)])], plot: none)
        let ink = try login.lines(in: box, font: font), red = CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        var said = CGRect.null
        let screen = closeUp(CGSize(width: 500, height: 500)) { context in
            _ = write("login screen", at: CGPoint(x: 60, y: 58), size: 28, color: CGColor(gray: 0.1, alpha: 1), in: context)
            context.setLineWidth(1.2)
            context.setStrokeColor(gray: 0.1, alpha: 1)
            context.stroke(CGRect(origin: corner, size: box))
            context.setStrokeColor(CGColor(red: 0x1F / 255, green: 0x45 / 255, blue: 0x96 / 255, alpha: 1))
            for line in ink { context.addLines(between: line.map { CGPoint(x: corner.x + $0.x, y: corner.y + $0.y) }) }
            context.strokePath()
            context.setStrokeColor(red)
            context.setLineWidth(2.4)
            context.strokeEllipse(in: button.insetBy(dx: -20, dy: -17).offsetBy(dx: corner.x, dy: corner.y))
            said = write("Log in", at: CGPoint(x: 372, y: 356), size: 30, color: red, in: context)
        }
        let marks = [button.insetBy(dx: -20, dy: -17), said.offsetBy(dx: -corner.x, dy: -corner.y)].map { [$0.minX, $0.minY, $0.width, $0.height].map { Double($0.rounded()) } }
        start = .now
        let drawingEdit = try await agent.edit(near: screen, around: screen, targets: [
            Agent.Target(id: "1", kind: "drawing", at: [120, 140, 600, 720], box: [300, 360], shows: "login screen — \(login.say)",
                         drawing: .init(kind: login.kind, parts: login.parts, plot: login.plot), marks: marks)])
        let parts = drawingEdit.edits.first?.parts ?? []
        print("edit drawing: read \(drawingEdit.reading.debugDescription), edits \(drawingEdit.edits.map { "\($0.target): \($0.parts.map(\.name)) \($0.parts.flatMap(\.labels).map(\.text)) say \($0.say.debugDescription)" }) in \(start.duration(to: .now))")
        precondition(drawingEdit.edits.count == 1 && drawingEdit.edits[0].target == "1" && parts.count == 1
                     && parts[0].name.trimmingCharacters(in: .whitespaces).lowercased() == "sign in button"
                     && parts[0].labels.contains { $0.text.lowercased().contains("log in") }, "the button part only, now Log in")
        let patched = login.patched(parts: parts, plot: drawingEdit.edits[0].plot, say: drawingEdit.edits[0].say)
        try screen.write(to: out.appending(path: "edit-near.png"))
        try render(try patched.lines(in: box, font: font), box).write(to: out.appending(path: "edit-drawing.png"))

        // ... and "both roots" under an answer rewrites it.
        var answer = CGRect.null
        let page = closeUp(CGSize(width: 500, height: 250)) { context in
            _ = write("x² = 49 ?", at: CGPoint(x: 20, y: 110), size: 40, color: CGColor(gray: 0.1, alpha: 1), in: context)
            answer = write("x = 7", at: CGPoint(x: 230, y: 110), size: 40, color: CGColor(red: 0x1F / 255, green: 0x45 / 255, blue: 0x96 / 255, alpha: 1), in: context)
            _ = write("both roots", at: CGPoint(x: 230, y: 180), size: 34, color: red, in: context)
        }
        start = .now
        let answerEdit = try await agent.edit(near: page, around: page, targets: [
            Agent.Target(id: "1", kind: "answer", at: [answer.minX, answer.minY, answer.width, answer.height].map { Double(($0 * 2).rounded()) },
                         question: "x² = 49 ?", answer: "x = 7")])
        print("edit answer: read \(answerEdit.reading.debugDescription), edits \(answerEdit.edits.map { "\($0.target): \($0.reply.debugDescription)" }) in \(start.duration(to: .now))")
        precondition(answerEdit.edits.count == 1 && answerEdit.edits[0].target == "1" && ["-7", "−7", "±7", "± 7"].contains { answerEdit.edits[0].reply.contains($0) },
                     "the answer, rewritten with both roots")
        print("live ok: drawings and edits in \(out.path)")
    }

    /// A close-up at 2× of `size` points, y down, drawn by `draw` on white, as a PNG.
    static func closeUp(_ size: CGSize, _ draw: (CGContext) -> Void) -> Data {
        let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
        context.translateBy(x: 0, y: size.height * 2)
        context.scaleBy(x: 2, y: -2)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // text upright in the y-down points
        context.setLineCap(.round)
        context.setLineJoin(.round)
        draw(context)
        return png(context)
    }

    /// Writes `text` by hand in `color`, its baseline starting at `at` in a close-up's points, and returns its box there.
    static func write(_ text: String, at: CGPoint, size: CGFloat, color: CGColor, in context: CGContext) -> CGRect {
        let font = CTFontCreateWithName("Bradley Hand" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): color]))
        context.textPosition = at
        CTLineDraw(line, context)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)  // y up from the baseline
        return CGRect(x: at.x + bounds.minX, y: at.y - bounds.maxY, width: bounds.width, height: bounds.height)
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
