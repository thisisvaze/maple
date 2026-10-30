// Runs marks through the app's own path on an iPad simulator: PencilKit strokes → Grouping → red crops → Jev → Muse → agent ink.
// Strokes are letter outlines from a handwriting font: "x² = 49 ?" (its dot last), then "triangle" with an empty box under it.
// Offline, a known answer is placed by Room and written by Handwriting beside the ?; with keys, Muse's own answer is too.
// Offline too, an edit: a login drawing and an answer with the edit brush's marks over them, what Muse would see, and the
// page before and after a canned result lands (edit-*.png, edit-targets.json).
// It runs inside a bare .app, because PencilKit saves drawing state to preferences and traps without a bundle ID.
//   S=$(mktemp -d); mkdir $S/Check.app; sed -n '1p;/^extension UIColor/,$p' Maple/MapleApp.swift > $S/Colors.swift
//   xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios26.0-simulator \
//     -swift-version 6 -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault -parse-as-library \
//     Maple/{Marks,Bubble,Written,Note,Page,History,Grouping,Agent,Muse,Drawing,Hershey,Handwriting,Room,AgentPen,Jev,Thinking}.swift \
//     $S/Colors.swift checks/pipeline-check.swift -o $S/Check.app/pipeline
//   plutil -create xml1 $S/Check.app/Info.plist; plutil -insert CFBundleIdentifier -string dev.maple.check $S/Check.app/Info.plist; cp Maple/*.jhf Maple/hand.json $S/Check.app/
//   SIMCTL_CHILD_MODEL_API_KEY=... SIMCTL_CHILD_TYPESAFE_API_KEY=... xcrun simctl spawn booted $S/Check.app/pipeline $S   # writes the PNGs there
import PencilKit

@main
struct Check {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        let start = Date(timeIntervalSince1970: 1_000_000)
        let question = handwriting("x² = 49 ?", at: CGPoint(x: 1000, y: 1000), size: 64, start: start)
        let (trigger, mark, nearPNG, aroundPNG) = await crops(question)
        precondition(trigger.count == 2, "the ? is its hook and dot: \(trigger.count) strokes")
        try nearPNG.write(to: out.appending(path: "near.png"))
        try aroundPNG.write(to: out.appending(path: "around.png"))
        print("crops ok: \(out.path)")
        let offline = try write("x = 7 or x = −7", beside: question, trigger: trigger, to: out.appending(path: "answer.png"))
        precondition(offline.kind == .sameLine, "an answer on an empty page goes on the ?'s line: \(offline.kind)")
        print("ink answer ok: answer.png")

        // A label, then an empty box drawn under it 2 s later.
        let label = handwriting("triangle", at: CGPoint(x: 1000, y: 2000), size: 56, start: start + 100)
        var box = AgentPen.stroke([CGPoint(x: 1000, y: 2040), CGPoint(x: 1360, y: 2040), CGPoint(x: 1360, y: 2280), CGPoint(x: 1000, y: 2280), CGPoint(x: 1000, y: 2040)], width: 2.5, step: 2)
        box.ink = PKInk(.pen, color: .black)
        box.path = PKStrokePath(controlPoints: Array(box.path), creationDate: (label.last?.path.creationDate ?? start) + 2)
        let boxed = await crops(label + [box])
        precondition(boxed.trigger == [Marks.id(box)], "the box alone is the mark")
        print("box crops ok")
        try await edit(to: out)

        let env = ProcessInfo.processInfo.environment
        guard let key = env["MODEL_API_KEY"], !key.isEmpty, let jevKey = env["TYPESAFE_API_KEY"], !jevKey.isEmpty else {
            return print("no MODEL_API_KEY or TYPESAFE_API_KEY: skipped Jev and Muse")
        }
        let agent = Agent(muse: Muse(key: key)), jev = Jev(key: jevKey)
        var clock = ContinuousClock.now
        let questionMark = try await jev.mark(nearPNG).mark
        precondition(questionMark == "question", "Jev sees the ?: \(questionMark)")
        let answer = try await agent.ask(near: nearPNG, around: aroundPNG, gesture: "question", threads: [], target: nil)
        print("\(answer) in \(clock.duration(to: .now))")
        precondition(answer.reply.contains("7"), "Muse answers the written ?")
        _ = mark
        if !answer.passage, Handwriting.answers.writable(answer.reply) != nil {
            let live = try write(answer.reply, beside: question, trigger: trigger, to: out.appending(path: "answer-live.png"))
            print("Muse's answer written \(live.kind.rawValue): answer-live.png")
        }

        clock = .now
        let boxMark = try await jev.mark(boxed.near).mark
        precondition(boxMark == "frame", "Jev sees an empty box: \(boxMark)")
        let drawing = try await agent.draw(near: boxed.near, around: boxed.around, size: boxed.mark.size, threads: [])
        let ink = try drawing.lines(in: boxed.mark.size).map { line in
            AgentPen.stroke(line.map { CGPoint(x: boxed.mark.minX + $0.x, y: boxed.mark.minY + $0.y) }, width: AgentPen.width(at: 1), step: 2)
        }
        print("box: \(drawing.kind), \(ink.count) strokes, \(drawing.say.debugDescription) in \(clock.duration(to: .now))")
        let page = PKDrawing(strokes: label + [box] + ink)
        try page.image(from: boxed.mark.insetBy(dx: -60, dy: -90), scale: 2).pngData()!.write(to: out.appending(path: "box.png"))
        precondition(!ink.isEmpty && ink.allSatisfy { boxed.mark.insetBy(dx: -4, dy: -4).contains($0.renderBounds) }, "the drawing sits inside its box")
        print("pipeline ok: box.png in \(out.path)")
    }

    /// An edit through the app's own path, offline: Maple's drawing of a login screen, drawn while the page was turned
    /// 14°, and its answer to a ?; the edit brush's marks over them, made with the page level (a circle round the button
    /// and "Log in"; a line through the answer and "±7"); what Muse would see of them; and the page before and after a
    /// canned result lands.
    static func edit(to out: URL) async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let screen = UIView(frame: CGRect(x: 0, y: 0, width: 820, height: 1180)), canvas = PKCanvasView(frame: screen.bounds)
        screen.addSubview(canvas)
        canvas.contentSize = CGSize(width: 4000, height: 4000)
        canvas.contentOffset = CGPoint(x: 600, y: 1400)  // an iPad screen at zoom 1 over page points (600, 1400) to (1420, 2580)
        let marks = Marks(canvas: canvas, page: Page(url: folder, edited: .now), notes: [])
        let start = Date(timeIntervalSince1970: 2_000_000), hand = Hershey.pen
        func brushed(_ lines: [[CGPoint]]) -> [PKStroke] {  // the brush's coral pen, 3 points at zoom 1: points made here draw 2 × (size − 2)
            lines.filter { $0.count > 1 }.map { PKStroke(ink: PKInk(.pen, color: AgentPen.coral), path: AgentPen.stroke($0, width: 3.5, step: 2).path) }
        }

        // The person's label and box, and Maple's drawing in it, in parts, all level in the page turned by `turn`.
        let turn: CGFloat = 0.25, page = CGAffineTransform(rotationAngle: -turn)
        let box = CGRect(origin: CGPoint(x: 700, y: 1560).applying(page.inverted()), size: CGSize(width: 300, height: 360))
        let none = Drawing.Graph(expression: "", xMin: 0, xMax: 0, yMin: 0, yMax: 0)
        func rect(_ r: CGRect) -> [[Double]] { [[r.minX, r.minY], [r.maxX, r.minY], [r.maxX, r.maxY], [r.minX, r.maxY], [r.minX, r.minY]].map { $0.map { Double($0) } } }
        let signIn = Drawing.Part(name: "sign in button", strokes: [rect(CGRect(x: 70, y: 250, width: 160, height: 50))],
                                  labels: [Drawing.Label(text: "Sign in", x: 105, y: 268, size: 16)])
        let login = Drawing(reading: "login screen", kind: "ink", say: "A login screen with email and password fields and a Sign in button", parts: [
            Drawing.Part(name: "title", strokes: [], labels: [Drawing.Label(text: "Welcome", x: 66, y: 34, size: 24)]),
            Drawing.Part(name: "email field", strokes: [rect(CGRect(x: 30, y: 100, width: 240, height: 40))], labels: [Drawing.Label(text: "Email", x: 40, y: 114, size: 12)]),
            Drawing.Part(name: "password field", strokes: [rect(CGRect(x: 30, y: 165, width: 240, height: 40))], labels: [Drawing.Label(text: "Password", x: 40, y: 179, size: 12)]),
            signIn], plot: none)
        let label = handwriting("login screen", at: CGPoint(x: 0, y: -30), size: 40, start: start).map { stroke in
            var turned = stroke
            turned.transform = CGAffineTransform(translationX: box.minX, y: box.minY).concatenating(page)
            return turned
        }
        var frame = AgentPen.stroke([box.origin, CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY), box.origin].map {
            $0.applying(page)
        }, width: 2.5, step: 2)
        frame.ink = PKInk(.pen, color: .black)
        let drawnAt = start + 100
        canvas.drawing = PKDrawing(strokes: label + [frame])
        marks.apply(.init(add: try Marks.drawn(login, in: box, turn: turn, zoom: 1, date: drawnAt),
                          notes: [Note(mark: "frame", trigger: [Marks.id(frame)], anchor: Marks.anchor(box, 1).applying(page), zoom: 1, reading: login.reading,
                                       reply: login.say, turn: turn, rect: box, inked: drawnAt, source: login)]))
        // A question, answered in ink beside it as Marks.write does.
        let question = handwriting("x² = 49 ?", at: CGPoint(x: 700, y: 2100), size: 56, start: start + 200)
        let (trigger, _, _, _) = await crops(question)
        canvas.drawing.strokes += question
        let asked = Note(mark: "question", trigger: trigger, anchor: .zero, zoom: 1, reading: "x² = 49 ?", reply: "x = 7", turn: 0)
        marks.apply(marks.write("x = 7", note: asked, view: (screen: marks.screen, avoid: []), bubble: nil)!)
        let answer = marks.notes.first { $0.id == asked.id }!, block = answer.rect!
        func points(_ strokes: [PKStroke]) -> Set<[[CGFloat]]> { Set(strokes.map { $0.path.map { [$0.location.x, $0.location.y] } }) }
        func written(_ text: String, x: CGFloat) throws -> Set<[[CGFloat]]> {
            let part = Drawing.Part(name: "", strokes: [], labels: [Drawing.Label(text: text, x: x, y: 268, size: 16)])
            return points(try Marks.drawn(Drawing(reading: "", kind: "ink", say: "", parts: [part], plot: none), in: box, turn: turn, zoom: 1, date: .now))
        }
        let drawing = marks.notes.first { $0.mark == "frame" }!, oldInk = points(marks.strokes(of: drawing))

        // The edit brush's marks, and what Muse would see of them.
        let button = CGPoint(x: box.minX + 150, y: box.minY + 275).applying(page)  // its middle
        let circle = brushed([(0 ... 48).map { CGPoint(x: button.x + 100 * cos(CGFloat($0) * .pi / 24), y: button.y + 44 * sin(CGFloat($0) * .pi / 24)) }])
        let logIn = brushed(hand.lines("Log in", at: CGPoint(x: button.x + 125, y: button.y - 30), height: 28))
        let strike = brushed([[CGPoint(x: block.minX - 6, y: block.midY + 4), CGPoint(x: block.maxX + 6, y: block.midY - 4)]])
        let plusMinus = brushed(Hershey.bundled("greek").lines("+", at: CGPoint(x: block.minX + 30, y: block.maxY + 14), height: 28)
                                + hand.lines("-7", at: CGPoint(x: block.minX + 30, y: block.maxY + 36), height: 28))
        let edits = circle + logIn + strike + plusMinus
        canvas.drawing.strokes += edits
        let area = canvas.drawing.bounds.insetBy(dx: -30, dy: -30)
        func png(_ name: String) throws {
            var image = UIImage()
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent { image = canvas.drawing.image(from: area, scale: 2) }
            try UIGraphicsImageRenderer(size: image.size).pngData { context in
                UIColor.paper.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).setFill()
                context.fill(CGRect(origin: .zero, size: image.size))
                image.draw(at: .zero)
            }.write(to: out.appending(path: name))
        }
        try png("edit-before.png")
        let batch = marks.batch(Set(edits.map(Marks.id)))!
        precondition(Set(batch.targets.map(\.id)) == [drawing.id, answer.id], "the marks point at the drawing and the answer")
        let (near, around, targets) = await marks.request(batch)
        try near.write(to: out.appending(path: "edit-near.png"))
        try around.write(to: out.appending(path: "edit-around.png"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(targets).write(to: out.appending(path: "edit-targets.json"))

        // A canned result lands: the button says Log in, the answer x = ±7, and the marks leave the page.
        func id(_ note: Note) -> String { String(batch.targets.firstIndex { $0.id == note.id }! + 1) }
        let result = Agent.Edits(reading: "Log in; x = ±7", edits: [
            Agent.Edit(target: id(drawing), reply: "", parts: [Drawing.Part(name: "Sign in button", strokes: signIn.strokes,
                                                                             labels: [Drawing.Label(text: "Log in", x: 112, y: 268, size: 16)])],
                       plot: none, say: "A login screen with email and password fields and a Log in button"),
            Agent.Edit(target: id(answer), reply: "x = ±7", parts: [], plot: none, say: "")])
        try marks.land(result, batch)
        marks.flush()
        try png("edit-after.png")
        let redrawn = marks.notes.first { $0.id == drawing.id }!, rewritten = marks.notes.first { $0.id == answer.id }!
        let newInk = points(marks.strokes(of: redrawn)), (signed, logged) = (try written("Sign in", x: 105), try written("Log in", x: 112))
        precondition(oldInk.subtracting(newInk) == signed && newInk.subtracting(oldInk) == logged && redrawn.rect == box, "only the button's label changes")
        precondition(!canvas.drawing.strokes.contains(where: AgentPen.edit) && rewritten.reply == "x = ±7" && !marks.strokes(of: rewritten).isEmpty, "edited")
        print("edit ok: edit-before.png, edit-near.png, edit-around.png, edit-targets.json, edit-after.png")
    }

    /// Places and writes `reply` beside the mark at the end of `strokes` as Marks.write does, on an iPad screen at zoom 1, and
    /// saves the page around it.
    static func write(_ reply: String, beside strokes: [PKStroke], trigger: [String], to file: URL) throws -> Room.Placement {
        let pen = Handwriting.answers
        guard let text = pen.writable(reply) else { throw Plot.Failure("not writable: \(reply)") }
        let mark = strokes.filter { trigger.contains(Marks.id($0)) }.reduce(CGRect.null) { $0.union($1.renderBounds) }
        let screen = CGRect(x: mark.midX - 410, y: mark.midY - 590, width: 820, height: 1180)
        let corners = [CGPoint(x: screen.minX, y: screen.minY), CGPoint(x: screen.maxX, y: screen.minY),
                       CGPoint(x: screen.maxX, y: screen.maxY), CGPoint(x: screen.minX, y: screen.maxY)]
        let ink = strokes.flatMap { stroke in
            Marks.points(stroke, every: 2).map { Room.Stroke(points: $0, person: true, mark: trigger.contains(Marks.id(stroke))) }
        }
        let request = Room.Request(strokes: ink, doubleDot: false, screen: corners, avoid: [], screenAngle: 0, zoom: 1, nib: nil)
        guard let place = Room.place(request, layout: { cap, width in
            let lines = pen.wrap(text, cap: cap, width: width)
            return (pen.extent(lines, cap: cap), lines.count)
        }) else { throw Plot.Failure("no room for \(reply)") }
        let lines = pen.wrap(text, cap: place.cap, width: place.width)
        let page = CGAffineTransform(rotationAngle: -place.angle), date = Date()
        let answer = (place.leader + pen.pen(lines, at: place.origin, cap: place.cap).map { $0.map { $0.applying(page) } }).map {
            AgentPen.stroke($0, width: AgentPen.width(at: 1), step: 2, date: date)
        }
        let drawing = PKDrawing(strokes: strokes + answer)
        try drawing.image(from: mark.union(place.rect).insetBy(dx: -80, dy: -60), scale: 2).pngData()!.write(to: file)
        return place
    }

    /// The app's crops for the mark at the end of `strokes`: the mark in red, a close-up and an iPad screen around it.
    static func crops(_ strokes: [PKStroke]) async -> (trigger: [String], mark: CGRect, near: Data, around: Data) {
        let recent = strokes.suffix(12).map { stroke in
            let started = stroke.path.creationDate.timeIntervalSince1970
            return Grouping.Stroke(id: Marks.id(stroke), bounds: stroke.renderBounds, started: started, ended: started + (stroke.path.last?.timeOffset ?? 0))
        }
        let trigger = Grouping.candidate(recent)
        // Built whole: mutating a PKDrawing's strokes needs an app bundle (PencilKit saves replica state to preferences).
        let marked = PKDrawing(strokes: strokes.map { stroke in
            var stroke = stroke
            if trigger.contains(Marks.id(stroke)) { stroke.ink = PKInk(stroke.ink.inkType, color: .systemRed) }
            return stroke
        })
        let mark = marked.strokes.filter { trigger.contains(Marks.id($0)) }.reduce(CGRect.null) { $0.union($1.renderBounds) }
        let side = max(mark.width, mark.height) + 2 * Marks.nearPad
        let near = CGRect(x: mark.midX - side / 2, y: mark.midY - side / 2, width: side, height: side)
        let around = CGRect(x: mark.midX - 410, y: mark.midY - 590, width: 820, height: 1180).union(near)  // an iPad screen at zoom 1
        let (nearPNG, aroundPNG) = await Marks.crops(marked, near, around)
        return (trigger, mark, nearPNG, aroundPNG)
    }

    /// `text` as pen strokes: each glyph's outline contours, written 0.3 s apart, the last contour (a ?'s dot) 1 s late.
    static func handwriting(_ text: String, at origin: CGPoint, size: CGFloat, start: Date) -> [PKStroke] {
        let font = CTFontCreateWithName("Noteworthy-Bold" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var strokes: [PKStroke] = [], time = start
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                for contour in contours(path) where contour.count > 1 {
                    // Glyph space has y up; the page has y down.
                    let points = contour.map { CGPoint(x: origin.x + position.x + $0.x, y: origin.y - $0.y) }
                    let samples = points.enumerated().map { i, p in
                        PKStrokePoint(location: p, timeOffset: Double(i) * 0.004, size: CGSize(width: 2.5, height: 2.5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                    }
                    strokes.append(PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: samples, creationDate: time)))
                    time += 0.3
                }
            }
        }
        if let dot = strokes.popLast() {  // the ?'s dot, after a pause
            strokes.append(PKStroke(ink: dot.ink, path: PKStrokePath(controlPoints: Array(dot.path), creationDate: time + 1)))
        }
        return strokes
    }

    /// A path's closed contours as points, curves sampled every 1/8.
    static func contours(_ path: CGPath) -> [[CGPoint]] {
        var all: [[CGPoint]] = [], current: [CGPoint] = []
        path.applyWithBlock { element in
            let e = element.pointee, p = e.points
            func sample(_ f: (CGFloat) -> CGPoint) { current += (1...8).map { f(CGFloat($0) / 8) } }
            switch e.type {
            case .moveToPoint: if !current.isEmpty { all.append(current) }; current = [p[0]]
            case .addLineToPoint: current.append(p[0])
            case .addQuadCurveToPoint:
                let a = current.last!
                sample { t in CGPoint(x: (1-t)*(1-t)*a.x + 2*(1-t)*t*p[0].x + t*t*p[1].x, y: (1-t)*(1-t)*a.y + 2*(1-t)*t*p[0].y + t*t*p[1].y) }
            case .addCurveToPoint:
                let a = current.last!
                sample { t in
                    let u = 1 - t
                    return CGPoint(x: u*u*u*a.x + 3*u*u*t*p[0].x + 3*u*t*t*p[1].x + t*t*t*p[2].x, y: u*u*u*a.y + 3*u*u*t*p[0].y + 3*u*t*t*p[1].y + t*t*t*p[2].y)
                }
            case .closeSubpath: if let first = current.first { current.append(first) }
            @unknown default: break
            }
        }
        if !current.isEmpty { all.append(current) }
        return all
    }
}
