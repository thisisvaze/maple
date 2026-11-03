// Recognition diagnostic on an iPad simulator: real PencilKit crops, rotated numbers, and a genuine 3D control.
// Arguments: output directory, optionally a saved page directory containing ink.drawing and notes.json.
// Without MODEL_API_KEY it only renders fixtures and checks geometry; with a key it records live readings in results.json.
//   CHECK_DIR=$(mktemp -d); mkdir "$CHECK_DIR/Check.app" "$CHECK_DIR/results"
//   sed -n '1p;/^extension UIColor/,$p' Maple/MapleApp.swift > "$CHECK_DIR/Colors.swift"
//   xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios26.0-simulator -swift-version 6 \
//     -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault -parse-as-library \
//     Maple/{Marks,Bubble,Written,Note,Page,History,Grouping,Agent,Muse,MuseImage,Drawing,Figure,Computed,Hershey,Handwriting,Room,AgentPen,Jev,Thinking}.swift \
//     "$CHECK_DIR/Colors.swift" checks/recognition-check.swift -o "$CHECK_DIR/Check.app/recognition-check"
//   plutil -create xml1 "$CHECK_DIR/Check.app/Info.plist"
//   plutil -insert CFBundleIdentifier -string dev.maple.recognition-check "$CHECK_DIR/Check.app/Info.plist"
//   cp Maple/*.jhf Maple/hand.json "$CHECK_DIR/Check.app/"
//   xcrun simctl spawn booted "$CHECK_DIR/Check.app/recognition-check" "$CHECK_DIR/results" [saved-page-directory]
// For live calls, export SIMCTL_CHILD_MODEL_API_KEY first. Only pass a saved page when its upload is authorized.
import PencilKit

@main
struct Check {
    struct Sample {
        var name, expected: String
        var drawing: PKDrawing
        var trigger: Set<String>
        var zoom: CGFloat = 1
    }

    struct Result: Codable {
        var sample, expected: String
        var degrees: Int
        var effort: String
        var attempt: Int
        var reading, confidence, reply: String
        var seconds: Double
        var error: String?
    }

    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        guard CommandLine.arguments.count >= 2 else { throw Muse.Failure("Give an output directory, then optionally a saved page directory.") }
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let cases = [("thirty", "30 ?"), ("letter-d", "3D ?"), ("sum", "10 + 20 ?"),
                     ("eighty", "80 - 8 ?"), ("equation", "300 + 50 - 30 ?")]
        var samples = cases.map { synthetic($0.0, $0.1) }
        if CommandLine.arguments.count > 2 {
            let folder = URL(fileURLWithPath: CommandLine.arguments[2])
            let notes = try JSONDecoder().decode([Note].self, from: Data(contentsOf: folder.appending(path: "notes.json")))
            guard let note = notes.first(where: { $0.reading == "300 + 50 - 30?" }) else {
                throw Muse.Failure("The saved page has no 300 + 50 - 30? sample.")
            }
            let drawing = try PKDrawing(data: Data(contentsOf: folder.appending(path: "ink.drawing")))
            let trigger = Set(note.trigger)
            let end = drawing.strokes.filter { trigger.contains(Marks.id($0)) }.map(\.path.creationDate).max()
            guard let end else { throw Muse.Failure("Saved question strokes are missing.") }
            let before = PKDrawing(strokes: drawing.strokes.filter {
                AgentPen.person($0) && $0.path.creationDate <= end && $0.path.creationDate >= end - 60
            })
            // This saved equation is about 45° uphill relative to its answer's stored orientation.
            let level = before.transformed(using: CGAffineTransform(rotationAngle: (note.turn ?? 0) + .pi / 4))
            let mark = level.strokes.filter { trigger.contains(Marks.id($0)) }.reduce(CGRect.null) { $0.union($1.renderBounds) }
            let local = level
                .transformed(using: CGAffineTransform(translationX: 1000 - mark.midX, y: 1000 - mark.midY))
            samples.append(Sample(name: "real-equation", expected: "300 + 50 - 30 ?", drawing: local, trigger: trigger, zoom: note.zoom))
        }

        // On a rotated page, writing made level on screen must produce the same crop coordinates and grouping.
        let base = samples[4]
        let baseline = grouping(base.drawing, turn: 0, zoom: 1)
        let area = base.drawing.bounds.insetBy(dx: -20, dy: -20)
        let pixels = UIImage(data: Marks.png(base.drawing, area))!.cgImage!.dataProvider!.data! as Data
        for degrees: CGFloat in [-90, -45, -23, 0, 23, 45, 90] {
            let angle = degrees * .pi / 180
            let page = base.drawing.transformed(using: CGAffineTransform(rotationAngle: -angle))
            let recent = grouping(page, turn: angle, zoom: 1)
            precondition(Grouping.candidate(recent) == Grouping.candidate(baseline), "rotation changed the grouped mark")
            for (a, b) in zip(baseline, recent) {
                precondition(abs(a.bounds.midX - b.bounds.midX) < 0.01 && abs(a.bounds.midY - b.bounds.midY) < 0.01,
                             "rotation displaced a letter")
                precondition(abs(a.bounds.width - b.bounds.width) < 0.01 && abs(a.bounds.height - b.bounds.height) < 0.01,
                             "rotation distorted a letter")
            }
            let upright = page.transformed(using: CGAffineTransform(rotationAngle: angle))
            let png = Marks.png(upright, area)
            precondition(UIImage(data: png)!.cgImage!.dataProvider!.data! as Data == pixels,
                         "rotation changed the upright pixels")
            try png.write(to: out.appending(path: "upright-\(Int(degrees)).png"))
        }
        print("geometry ok: seven page angles preserve letter bounds, mark grouping and every rendered pixel")

        let key = ProcessInfo.processInfo.environment["MODEL_API_KEY"]
        var results: [Result] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for sample in samples {
            for degrees in [0, 23, 45, 90, -45] {
                let angle = CGFloat(degrees) * .pi / 180
                let (near, around) = await crops(sample, turn: angle)
                let name = "\(sample.name)-\(degrees)"
                try near.write(to: out.appending(path: name + "-near.png"))
                try around.write(to: out.appending(path: name + "-around.png"))
                guard let key, !key.isEmpty else { continue }
                let efforts: [Muse.Effort] = sample.name == "real-equation" ? [.minimal, .low] : [.minimal]
                for effort in efforts {
                    for attempt in 1...(sample.name == "real-equation" ? 2 : 1) {
                        let started = Date()
                        var result = Result(sample: sample.name, expected: sample.expected, degrees: degrees, effort: effort.rawValue,
                                            attempt: attempt, reading: "", confidence: "", reply: "", seconds: 0)
                        do {
                            // Same messages, instructions, schema and tools as Agent.ask; only effort is varied.
                            let response = try await Muse(key: key).respond([.png(near), .png(around), .text(#"{"gesture":"question","threads":[]}"#)],
                                instructions: Agent.instructions, schema: Agent.schema, effort: effort, search: true, functions: [Agent.calculate])
                            let answer = try JSONDecoder().decode(Agent.Answer.self, from: Data(response.text.utf8))
                            (result.reading, result.confidence, result.reply) = (answer.reading, answer.confidence, answer.reply)
                        } catch { result.error = error.localizedDescription }
                        result.seconds = Date().timeIntervalSince(started)
                        results.append(result)
                        try encoder.encode(results).write(to: out.appending(path: "results.json"), options: .atomic)
                        print("\(name) \(effort.rawValue) #\(attempt): \(result.reading.debugDescription) [\(result.confidence)] → \(result.reply.debugDescription)\(result.error.map { " ERROR: \($0)" } ?? "")")
                    }
                }
            }
        }
        print("recognition diagnostic complete: \(results.count) live calls, fixtures and results in \(out.path)")
    }

    static func synthetic(_ name: String, _ text: String) -> Sample {
        let lines = Hershey.pen.lines(text, at: CGPoint(x: 1000, y: 1000), height: 24)
        precondition(!lines.isEmpty, "hand.json must be bundled")
        let strokes = lines.enumerated().map { i, line in
            var stroke = AgentPen.stroke(line, width: 2.9, step: 1, date: Date(timeIntervalSince1970: 1_000_000 + Double(i) * 0.4))
            stroke.ink = PKInk(.pen, color: .black)
            return stroke
        }
        let drawing = PKDrawing(strokes: strokes)
        let trigger = Set(Grouping.candidate(grouping(drawing, turn: 0, zoom: 1)))
        precondition(!trigger.isEmpty && trigger.count < strokes.count, "need a marked question and dark context")
        return Sample(name: name, expected: text, drawing: drawing, trigger: trigger)
    }

    static func grouping(_ drawing: PKDrawing, turn: CGFloat, zoom: CGFloat) -> [Grouping.Stroke] {
        drawing.strokes.suffix(12).map { stroke in
            let started = stroke.path.creationDate.timeIntervalSince1970
            return Grouping.Stroke(id: Marks.id(stroke), bounds: Marks.bounds(stroke, turn: turn, zoom: zoom),
                                   started: started, ended: started + (stroke.path.last?.timeOffset ?? 0))
        }
    }

    static func crops(_ sample: Sample, turn: CGFloat) async -> (Data, Data) {
        let marked = PKDrawing(strokes: sample.drawing.strokes.map { original in
            var stroke = original
            if sample.trigger.contains(Marks.id(stroke)) { stroke.ink = PKInk(.pen, color: .systemRed) }
            return stroke
        })
        let mark = marked.strokes.filter { sample.trigger.contains(Marks.id($0)) }
            .reduce(CGRect.null) { $0.union(Marks.bounds($1, turn: turn, zoom: sample.zoom)) }
        let side = max(mark.width, mark.height) + 2 * Marks.nearPad
        let near = CGRect(x: mark.midX - side / 2, y: mark.midY - side / 2, width: side, height: side)
        // shortcut: saved notes lack the original viewport, use a centered iPad-sized view until capture fixtures exist.
        let turned = marked.transformed(using: CGAffineTransform(rotationAngle: turn))
        let around = CGRect(x: mark.midX - 410 / sample.zoom, y: mark.midY - 590 / sample.zoom,
                            width: 820 / sample.zoom, height: 1180 / sample.zoom).union(near).union(turned.bounds.insetBy(dx: -20, dy: -20))
        return await Marks.crops(turned, near, around)
    }
}
