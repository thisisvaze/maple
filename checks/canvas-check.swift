// Run on a booted iPad simulator, without model keys:
//   CHECK_DIR=$(mktemp -d); mkdir "$CHECK_DIR/Check.app"
//   sed -n '1p;/^extension UIColor/,$p' Maple/MapleApp.swift > "$CHECK_DIR/Colors.swift"
//   xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios26.0-simulator -swift-version 6 \
//     -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault -parse-as-library \
//     Maple/{CanvasController,Marks,Bubble,Written,Note,Page,Grouping,Agent,Muse,Drawing,Hershey,Handwriting,Room,AgentPen,Jev,Thinking}.swift \
//     "$CHECK_DIR/Colors.swift" checks/canvas-check.swift -o "$CHECK_DIR/Check.app/canvas-check"
//   plutil -create xml1 "$CHECK_DIR/Check.app/Info.plist"
//   plutil -insert CFBundleIdentifier -string dev.maple.canvas-check "$CHECK_DIR/Check.app/Info.plist"
//   cp Maple/*.jhf "$CHECK_DIR/Check.app/"
//   xcrun simctl spawn booted "$CHECK_DIR/Check.app/canvas-check"
import PencilKit

@main
struct Check {
    static func main() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = Page(url: folder, edited: .now)
        defer {
            Store.queue.sync {}
            UserDefaults.standard.removeObject(forKey: page.viewportKey)
            try? FileManager.default.removeItem(at: folder)
        }
        // Pages saved before rotation existed still open at the same center and zoom.
        UserDefaults.standard.set([2000.0, 3000.0, 1.5], forKey: page.viewportKey)
        let controller = CanvasController(page: page)
        controller.loadViewIfNeeded()
        controller.view.bounds.size = CGSize(width: 820, height: 1180)
        controller.viewDidLayoutSubviews()
        near(controller.center, CGPoint(x: 2000, y: 3000))
        precondition(controller.rotation == 0 && controller.canvas.zoomScale == 1.5)

        let canvas = controller.canvas, pivot = CGPoint(x: 190, y: 730)
        let anchor = CGPoint(x: 2000, y: 3000)
        let note = Note(mark: "question", trigger: [], anchor: anchor, zoom: 1.5, reading: "test", reply: "test")
        let drawn = AgentPen.stroke([anchor, CGPoint(x: 2100, y: 3000)], width: 3, step: 2)
        controller.marks.apply(.init(add: [drawn], notes: [note]))
        let bubble = controller.marks.add(Bubble(anchor: anchor, zoom: 1.5, turn: 0, note: note))
        let ink = canvas.drawing.dataRepresentation()
        let twist = Rotation()
        twist.pivot = pivot

        for delta: CGFloat in [.pi / 4, .pi / 2, -.pi * 7 / 6, .pi * 6] {
            let before = canvas.convert(pivot, from: controller.view)
            twist.rotation = delta
            controller.rotate(twist)
            near(canvas.convert(pivot, from: controller.view), before)
            precondition(twist.rotation == 0, "rotation deltas are consumed once")
            coversScreen(controller)
            near(bubble.convert(.zero, to: controller.view), canvas.convert(CGPoint(x: anchor.x * canvas.zoomScale, y: anchor.y * canvas.zoomScale), to: controller.view))
        }
        precondition(canvas.drawing.dataRepresentation() == ink, "turning the view never rewrites ink")
        let installed = controller.view.gestureRecognizers!.first { $0 is UIRotationGestureRecognizer }!
        precondition(installed.delegate === controller)
        precondition(controller.gestureRecognizer(installed, shouldRecognizeSimultaneouslyWith: canvas.panGestureRecognizer))
        precondition(controller.gestureRecognizer(installed, shouldRecognizeSimultaneouslyWith: canvas.pinchGestureRecognizer!))
        precondition(!controller.gestureRecognizer(installed, shouldRecognizeSimultaneouslyWith: UITapGestureRecognizer()))

        // Zooming, panning and a window resize keep the rotated page and its overlays aligned.
        controller.show(CGPoint(x: 2300, y: 3200), zoom: 2)
        controller.scrollViewDidZoom(canvas)
        let middle = controller.center
        controller.view.bounds.size = CGSize(width: 1180, height: 820)
        controller.viewDidLayoutSubviews()
        near(controller.center, middle)
        coversScreen(controller)
        near(bubble.convert(.zero, to: controller.view), canvas.convert(CGPoint(x: anchor.x * 2, y: anchor.y * 2), to: controller.view))

        twist.phase = .ended
        controller.rotate(twist)
        controller.saveNow()
        let reopened = CanvasController(page: page)
        reopened.loadViewIfNeeded()
        reopened.view.bounds.size = CGSize(width: 820, height: 1180)
        reopened.viewDidLayoutSubviews()
        near(reopened.center, middle)
        precondition(reopened.rotation == controller.rotation && reopened.canvas.zoomScale == 2)
        coversScreen(reopened)
        // Maple's ink stays Maple's after a reload, though PencilKit reads it back as another ink type.
        let reread = reopened.canvas.drawing.strokes
        precondition(reread.count == 1 && AgentPen.wrote(reread[0]) && !AgentPen.person(reread[0]), "agent ink survives a reload")
        precondition(Marks.id(reread[0]) == Marks.id(drawn), "a stroke keeps its id and date through a reload")
        let older = PKInk(.pen, color: UIColor(red: 0x2F / 255, green: 0x5D / 255, blue: 0xB8 / 255, alpha: 1))
        precondition(AgentPen.wrote(PKStroke(ink: older, path: reread[0].path)), "pages from before the darker blue")
        let mine = PKStroke(ink: controller.pen.ink, path: reread[0].path)
        precondition(!AgentPen.wrote(mine) && AgentPen.person(mine), "the person's pen is theirs")
        controller.undo()
        precondition(canvas.drawing.strokes.isEmpty, "rotation doesn't consume the drawing's undo")
        controller.redo()
        precondition(canvas.drawing.strokes.count == 1, "redo still restores ink")
        controller.saveNow()

        // Maple's changes undo by stroke id: undoing an answer leaves the person's later writing and other answers alone.
        let marks = controller.marks!
        func ids() -> [String] { canvas.drawing.strokes.map(Marks.id) }
        func line(_ y: CGFloat) -> PKStroke { AgentPen.stroke([CGPoint(x: 2000, y: y), CGPoint(x: 2060, y: y)], width: 3, step: 2) }
        let (first, second, theirs) = (line(3100), line(3200), PKStroke(ink: controller.pen.ink, path: line(3300).path))
        let before = ids()
        func event() { RunLoop.main.run(until: .now + 0.02) }  // the undo manager closes a group at the end of each event
        event()
        marks.apply(.init(add: [first]))
        event()
        canvas.drawing.strokes.append(theirs)
        marks.apply(.init(add: [second]))
        event()
        controller.undo()
        precondition(ids() == before + [Marks.id(first), Marks.id(theirs)], "undo takes only the latest answer")
        controller.undo()
        precondition(ids() == before + [Marks.id(theirs)], "and then the one before, keeping the person's stroke")
        controller.redo()
        precondition(Set(ids()) == Set(before + [Marks.id(first), Marks.id(theirs)]), "redo brings it back")

        // Maple writes only once the pen has rested, and the page's closing writes what's still queued.
        let queued = line(3400)
        marks.penDown()
        marks.enqueue { .init(add: [queued]) }
        try await Task.sleep(for: .seconds(1.2))
        precondition(!ids().contains(Marks.id(queued)), "never while the pen is down")
        marks.penUp(writing: false)
        try await Task.sleep(for: .milliseconds(600))
        precondition(!ids().contains(Marks.id(queued)), "waits for the pen to rest")
        try await Task.sleep(for: .milliseconds(800))
        precondition(ids().contains(Marks.id(queued)), "written once the pen rested")

        // Writing over an answer fades it where it is; it comes back once that writing is gone. Scratching it out takes it
        // and the scratching away as one step of undo, and erasing it takes it from VoiceOver.
        let date = Date()
        var answer = Note(mark: "question", trigger: [], anchor: CGPoint(x: 2000, y: 3600), zoom: 2, reading: "", reply: "seven")
        (answer.inked, answer.rect, answer.turn) = (date, CGRect(x: 2000, y: 3600, width: 60, height: 20), 0)
        let written = [3600, 3610, 3620].map { AgentPen.stroke([CGPoint(x: 2000, y: $0), CGPoint(x: 2060, y: $0)], width: 3, step: 2, date: date) }
        func red(_ stroke: PKStroke) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            stroke.ink.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return r
        }
        func reads() -> Bool { marks.written.contains { $0.note.id == answer.id } }
        event()
        marks.apply(.init(add: written, notes: [answer]))
        event()
        precondition(Set(written.map(Marks.id)).count == written.count && reads(), "an answer's strokes each have their own id")
        let over = PKStroke(ink: controller.pen.ink, path: line(3610).path)
        canvas.drawing.strokes.append(over)
        let order = ids()
        marks.fadedBy[answer.id] = [Marks.id(over)]
        marks.fade(answer, false)
        marks.flush()
        precondition(ids() == order && marks.strokes(of: answer).count == 3 && marks.strokes(of: answer).allSatisfy { red($0) > 0.7 },
                     "faded in place, under the writing")
        canvas.drawing.strokes.removeAll { Marks.id($0) == Marks.id(over) }
        marks.flush()
        precondition(marks.strokes(of: answer).allSatisfy { red($0) < 0.2 } && marks.fadedBy.isEmpty, "back once the writing is gone")
        let scribble = PKStroke(ink: controller.pen.ink, path: line(3612).path)
        canvas.drawing.strokes.append(scribble)
        let kept = Set(ids())
        event()
        marks.scratch(answer, [Marks.id(scribble)])
        marks.flush()
        precondition(kept.subtracting(ids()) == Set(written.map(Marks.id) + [Marks.id(scribble)]) && !reads()
                     && !marks.notes.contains { $0.id == answer.id }, "scratched out")
        event()
        controller.undo()
        precondition(Set(ids()) == kept && reads(), "undo brings the answer and the scratching back")
        marks.penDown()
        marks.penUp(writing: false)
        canvas.drawing.strokes.removeAll { written.map(Marks.id).contains(Marks.id($0)) }
        precondition(!reads(), "an erased answer leaves VoiceOver")
        let last = line(3500)
        marks.penDown()
        marks.enqueue { .init(add: [last]) }
        marks.stop()
        precondition(ids().contains(Marks.id(last)) && marks.closed, "closing writes what's queued")

        // On a turned page, marks are measured level: a stroke written level on screen has a flat box in the reading frame,
        // and overlays read level too.
        let turn = controller.rotation, level = AgentPen.stroke([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)].map {
            CGPoint(x: 2000 + $0.x, y: 3000 + $0.y).applying(CGAffineTransform(rotationAngle: -turn))
        }, width: 3, step: 1)
        let box = Marks.bounds(level, turn: turn, zoom: 2)
        precondition(abs(box.width - 100 - 3) < 1 && box.height < 4, "level in the reading frame: \(box)")
        let grid = Thinking(style: .pixels)
        canvas.addSubview(grid)
        grid.place(over: CGRect(x: 2000, y: 3000, width: 80, height: 40), turn: turn, zoom: canvas.zoomScale)
        let corner = CGPoint(x: 2080, y: 3000).applying(CGAffineTransform(rotationAngle: -turn))
        near(grid.convert(CGPoint(x: 80, y: 0), to: canvas), CGPoint(x: corner.x * canvas.zoomScale, y: corner.y * canvas.zoomScale))
        let a = grid.convert(CGPoint.zero, to: controller.view), b = grid.convert(CGPoint(x: 80, y: 0), to: controller.view)
        precondition(abs(a.y - b.y) < 0.5, "the grid reads level on screen")
        let turned = controller.marks.add(Bubble(anchor: CGPoint(x: 2000, y: 3000), zoom: 2, turn: turn))
        let c = turned.convert(CGPoint.zero, to: controller.view), d = turned.convert(CGPoint(x: 20, y: 0), to: controller.view)
        precondition(abs(c.y - d.y) < 0.5, "a bubble reads level on screen")
        try await brush()
        print("canvas ok: rotation pivot, coverage, overlays, old/new viewport, resize, undo/redo, agent ink after reload, undo by id, writing while the pen rests, fading and scratching out answers, reading frame, edit brush")
    }

    /// The edit brush: the Pencil's double-tap cycle, its marks told apart and never kept, when an edit runs, what it
    /// points at, an edit failing through its own path with Muse offline, and one landing (from a canned result) as one
    /// step of undo.
    static func brush() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let page = Page(url: folder, edited: .now), spare = Page(url: folder.appending(path: "spare"), edited: .now)
        try FileManager.default.createDirectory(at: spare.url, withIntermediateDirectories: true)
        defer {
            Store.queue.sync {}
            [page, spare].forEach { UserDefaults.standard.removeObject(forKey: $0.viewportKey) }
            try? FileManager.default.removeItem(at: folder)
        }
        UserDefaults.standard.set([2000.0, 3000.0, 1.0], forKey: page.viewportKey)
        let controller = CanvasController(page: page)
        controller.loadViewIfNeeded()
        controller.view.bounds.size = CGSize(width: 820, height: 1180)
        controller.viewDidLayoutSubviews()
        let canvas = controller.canvas, marks = controller.marks!
        // Muse, offline: an edit runs its own path, through edit(), request(), Agent.edit and land(), on Offline's replies.
        URLProtocol.registerClass(Offline.self)
        marks.agent = Agent(muse: Muse(key: "offline"))
        func ids() -> Set<String> { Set(canvas.drawing.strokes.map(Marks.id)) }
        func event() { RunLoop.main.run(until: .now + 0.02) }  // the undo manager closes a group at the end of each event
        func until(_ seconds: Double, _ done: () -> Bool) async throws -> Bool {
            let end = Date() + seconds
            while !done(), Date() < end { try await Task.sleep(for: .milliseconds(40)) }
            return done()
        }
        // The brush draws editWidth on screen; points made here draw 2 × (size − 2) thick (AgentPen.width), so 3.5 at zoom 1.
        func brushed(_ points: [CGPoint]) -> PKStroke { PKStroke(ink: PKInk(.pen, color: AgentPen.coral), path: AgentPen.stroke(points, width: 3.5, step: 2).path) }
        func theirs(_ points: [CGPoint]) -> PKStroke { PKStroke(ink: controller.pen.ink, path: AgentPen.stroke(points, width: 3, step: 2).path) }

        // Double-tapping the Pencil goes pen, eraser, edit brush, pen, naming each at the top of the screen.
        let pencil = canvas.interactions.compactMap { $0 as? UIPencilInteraction }[0]
        let tap = class_createInstance(UIPencilInteraction.Tap.self, 0) as! UIPencilInteraction.Tap  // apps may not init one
        func doubleTap() {
            if UIPencilInteraction.preferredTapAction == .ignore { controller.cycle() } else { controller.pencilInteraction(pencil, didReceiveTap: tap) }
        }
        doubleTap()
        precondition(canvas.tool is PKEraserTool && controller.toolName.text == "Eraser", "pen to eraser")
        doubleTap()
        let tool = canvas.tool as! PKInkingTool, named = controller.toolName, safe = controller.view.safeAreaLayoutGuide.layoutFrame
        precondition(controller.brushing && tool.inkType == .pen && AgentPen.edit(PKStroke(ink: tool.ink, path: PKStrokePath())), "eraser to the edit brush, a coral pen")
        precondition(named.text == "Edit" && named.textColor == AgentPen.coral && abs(named.frame.midX - safe.midX) < 1 && named.frame.minY < safe.minY + 20
                     && !named.isUserInteractionEnabled, "named in coral at the top centre, taking no touches")
        doubleTap()
        precondition((canvas.tool as? PKInkingTool)?.inkType == .pen && !controller.brushing && named.text == "Pen", "and back to the pen")
        // The brush keeps its width on screen as the page zooms.
        doubleTap()
        doubleTap()
        for zoom: CGFloat in [3, 2, 0.5, 1] {
            controller.show(controller.center, zoom: zoom)
            controller.scrollViewDidEndZooming(canvas, with: nil, atScale: zoom)
            let width = (canvas.tool as! PKInkingTool).width * canvas.zoomScale
            precondition(controller.brushing && abs(width - CanvasController.editWidth) < 0.01, "the brush is editWidth wide on screen at zoom \(zoom): \(width)")
        }
        doubleTap()

        // Edit marks are told apart by their colour, as Maple's ink is, even when a reload calls them a pen, and are never
        // the person's writing; nor are the brush's first, lighter coral marks.
        let mark = brushed([CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0)]), reread = PKStroke(ink: PKInk(.pen, color: AgentPen.coral), path: mark.path)
        let first = PKStroke(ink: PKInk(.marker, color: UIColor(red: 1, green: 0x7F / 255, blue: 0x50 / 255, alpha: 1)), path: mark.path)
        precondition([mark, reread, first].allSatisfy { AgentPen.edit($0) && !AgentPen.person($0) && !AgentPen.wrote($0) }, "edit marks")
        let pen = theirs([CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0)])
        precondition(AgentPen.person(pen) && !AgentPen.edit(pen) && !AgentPen.edit(AgentPen.stroke([.zero, CGPoint(x: 9, y: 9)], width: 3, step: 2)), "nor others' ink")

        // A page closed with edit marks on it loses them as it opens, and from its file at the next save.
        try PKDrawing(strokes: [pen, mark]).dataRepresentation().write(to: spare.ink)
        let saved = try spare.load().strokes
        precondition(saved.count == 2 && AgentPen.edit(saved[1]), "a saved edit mark keeps its coral")
        let opened = CanvasController(page: spare)
        opened.loadViewIfNeeded()
        precondition(opened.canvas.drawing.strokes.map(Marks.id) == [Marks.id(pen)] && opened.dirty, "stripped as the page opens")
        opened.saveNow()
        let resaved = try spare.load().strokes
        precondition(resaved.map(Marks.id) == [Marks.id(pen)], "and from the file at the next save")
        opened.canvas.drawing.strokes.append(mark)
        opened.dirty = true
        opened.saveNow()
        let filed = try spare.load().strokes
        precondition(filed.map(Marks.id) == [Marks.id(pen)] && opened.canvas.drawing.strokes.count == 2, "a save never writes one, though it stays on the page")

        // Only the brush's own pen-up starts the edit pause, and it never reads the person's newest strokes as a mark:
        // here a double dot, which the pen's pen-up does read. Marks that point at nothing of Maple's then fade away,
        // not as a step of undo.
        controller.history.removeAllActions()
        let now = Date().timeIntervalSince1970
        let taps = [0, 0.25].map { t in
            PKStroke(ink: controller.pen.ink, path: PKStrokePath(controlPoints: [0, 1].map {
                PKStrokePoint(location: CGPoint(x: 2400 + t * 4 + Double($0) / 2, y: 3500), timeOffset: Double($0) / 100, size: CGSize(width: 3, height: 3),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }, creationDate: Date(timeIntervalSince1970: now + t)))
        }
        let lone = brushed([CGPoint(x: 1800, y: 2800), CGPoint(x: 1850, y: 2850)])
        canvas.drawing.strokes += taps + [lone]
        marks.penDown(editing: true)
        marks.penUp(writing: true, editing: true)
        precondition(marks.waiting?.isCancelled != false && marks.lastTrigger.isEmpty, "the brush's pen-up never starts reading a mark")
        try await Task.sleep(for: .seconds(1.2))
        precondition(ids().contains(Marks.id(lone)), "not before the edit pause")
        try await Task.sleep(for: .seconds(0.8))
        precondition(!ids().contains(Marks.id(lone)) && !controller.history.canUndo && marks.lastTrigger.isEmpty && Offline.requests == 0,
                     "marks pointing at nothing fade, not as a step of undo")
        let kept = brushed([CGPoint(x: 1800, y: 2800), CGPoint(x: 1850, y: 2850)])
        canvas.drawing.strokes.append(kept)
        marks.penDown()
        marks.penUp(writing: true)
        try await Task.sleep(for: .seconds(2))
        precondition(ids().contains(Marks.id(kept)) && marks.lastTrigger == taps.map(Marks.id) && Offline.requests == 1,
                     "the pen's pen-up starts no edit, though it reads the double dot: \(marks.lastTrigger), \(Offline.requests) requests")
        canvas.drawing.strokes.removeAll { taps.map(Marks.id).contains(Marks.id($0)) }
        marks.bubbles.forEach(marks.remove)  // the double dot's orb, orange once offline Muse failed it
        marks.penDown(editing: true)
        marks.penUp(writing: true, editing: true)
        try await Task.sleep(for: .seconds(0.5))
        marks.penDown()
        marks.penUp(writing: false)
        try await Task.sleep(for: .seconds(1.5))
        precondition(!ids().contains(Marks.id(kept)), "nor does the eraser's pen-down stop one")
        let again = brushed([CGPoint(x: 1800, y: 2800), CGPoint(x: 1850, y: 2850)])
        canvas.drawing.strokes.append(again)
        marks.penDown(editing: true)
        marks.penUp(writing: true, editing: true)
        try await Task.sleep(for: .seconds(1))
        marks.penDown(editing: true)
        try await Task.sleep(for: .seconds(0.2))
        marks.penUp(writing: true, editing: true)
        try await Task.sleep(for: .seconds(1.3))
        precondition(ids().contains(Marks.id(again)), "the brush's pen-down puts it off")
        try await Task.sleep(for: .seconds(0.7))
        precondition(!ids().contains(Marks.id(again)), "until the brush rests again")

        // Maple's drawing of a login screen in parts, in a box the person drew; its answer beside a ?; and a quiet one.
        let box = CGRect(x: 1650, y: 2500, width: 300, height: 360), none = Drawing.Graph(expression: "", xMin: 0, xMax: 0, yMin: 0, yMax: 0)
        func rect(_ r: CGRect) -> [[Double]] { [[r.minX, r.minY], [r.maxX, r.minY], [r.maxX, r.maxY], [r.minX, r.maxY], [r.minX, r.minY]].map { $0.map { Double($0) } } }
        func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) -> Drawing.Label { Drawing.Label(text: text, x: x, y: y, size: size) }
        let signIn = Drawing.Part(name: "Sign in button", strokes: [rect(CGRect(x: 70, y: 240, width: 160, height: 50))], labels: [label("Sign in", 105, 258, 16)])
        let login = Drawing(reading: "login screen", kind: "ink", say: "A login screen", parts: [
            Drawing.Part(name: "title", strokes: [], labels: [label("Welcome", 80, 30, 24)]),
            Drawing.Part(name: "email field", strokes: [rect(CGRect(x: 30, y: 90, width: 240, height: 40))], labels: [label("Email", 40, 104, 12)]),
            Drawing.Part(name: "password field", strokes: [rect(CGRect(x: 30, y: 150, width: 240, height: 40))], labels: [label("Password", 40, 164, 12)]),
            signIn], plot: none)
        let frame = theirs([CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.minX, y: box.minY)])
        let hook = theirs([CGPoint(x: 2100, y: 2600), CGPoint(x: 2112, y: 2596), CGPoint(x: 2118, y: 2606), CGPoint(x: 2108, y: 2616), CGPoint(x: 2108, y: 2624)])
        let dot = theirs([CGPoint(x: 2108, y: 2632), CGPoint(x: 2109, y: 2633)])
        canvas.drawing.strokes += [frame, hook, dot]
        let drawnAt = Date()
        let drawing = Note(mark: "frame", trigger: [Marks.id(frame)], anchor: Marks.anchor(box, 1), zoom: 1, reading: login.reading, reply: login.say,
                           turn: 0, rect: box, inked: drawnAt, source: login)
        marks.apply(.init(add: try Marks.drawn(login, in: box, turn: 0, zoom: 1, date: drawnAt), notes: [drawing]))
        let asked = Note(mark: "question", trigger: [Marks.id(hook), Marks.id(dot)], anchor: CGPoint(x: 2124, y: 2596), zoom: 1, reading: "x² = 49 ?", reply: "x = 7", turn: 0)
        marks.apply(marks.write("x = 7", note: asked, view: (screen: marks.screen, avoid: [marks.pagesCorner]), bubble: nil)!)
        let answer = marks.notes.first { $0.id == asked.id }!, block = answer.rect!
        let quiet = Note(mark: "question", trigger: [], anchor: CGPoint(x: 2100, y: 3300), zoom: 1, reading: "why", reply: "Because.")
        marks.apply(.init(notes: [quiet]))
        precondition(answer.inked != nil && marks.bubbles.contains { $0.note?.id == quiet.id }, "an inked answer, and a quiet one with its dot")

        // An edit points at the drawings and answers whose ink a mark touches, a drawing whose box a mark is in, and
        // what a loop goes round; never a quiet dot, nor ink further than editReach, nor all a long stroke's box holds.
        let button = CGRect(x: box.minX + 70, y: box.minY + 240, width: 160, height: 50)
        let circle = brushed((0 ... 48).map { CGPoint(x: button.midX + 100 * cos(CGFloat($0) * .pi / 24), y: button.midY + 42 * sin(CGFloat($0) * .pi / 24)) })
        let cross = brushed([CGPoint(x: block.minX - 4, y: block.midY), CGPoint(x: block.maxX + 4, y: block.midY + 6)])
        let around = block.insetBy(dx: -40, dy: -40)
        let loop = brushed([CGPoint(x: around.minX, y: around.minY), CGPoint(x: around.maxX, y: around.minY), CGPoint(x: around.maxX, y: around.maxY),
                            CGPoint(x: around.minX, y: around.maxY), CGPoint(x: around.minX, y: around.minY)])
        let far = brushed([CGPoint(x: box.minX + 310, y: box.minY + 100), CGPoint(x: box.minX + 310, y: box.minY + 180)])  // 40 pt from the fields
        let near = brushed([CGPoint(x: box.minX + 286, y: box.minY + 100), CGPoint(x: box.minX + 286, y: box.minY + 180)])  // 16 pt
        let dotted = brushed([CGPoint(x: 2096, y: 3296), CGPoint(x: 2112, y: 3312)])
        let inside = brushed([CGPoint(x: box.minX + 130, y: box.minY + 330), CGPoint(x: box.minX + 170, y: box.minY + 330)])  // 40 pt under the button
        let diagonal = brushed([CGPoint(x: box.minX + 250, y: box.minY + 50), CGPoint(x: box.minX + 850, y: box.minY + 700)])  // its box holds the answer
        canvas.drawing.strokes += [circle, cross, loop, far, near, dotted, inside, diagonal]
        func targets(_ strokes: [PKStroke]) -> [String] { marks.batch(Set(strokes.map(Marks.id)))?.targets.map(\.id) ?? [] }
        precondition(targets([circle]) == [drawing.id], "a circle round the button picks the drawing")
        precondition(targets([cross]) == [answer.id], "a mark through the answer picks it")
        precondition(targets([loop]) == [answer.id], "a loop round the answer, clear of its ink, picks it")
        precondition(targets([far]).isEmpty && targets([near]) == [drawing.id], "editReach: \(targets([far])) \(targets([near]))")
        precondition(targets([inside]) == [drawing.id], "a mark in the drawing's box picks it, beyond editReach of its ink")
        precondition(targets([diagonal]) == [drawing.id], "a long stroke picks what it reaches, not all its box holds: \(targets([diagonal]))")
        precondition(targets([dotted]).isEmpty, "a quiet dot is never a target")
        precondition(Set(targets([circle, cross])) == [drawing.id, answer.id], "one edit can change both")
        // A drawing the person partly erased is theirs, as an answer is: a stroke gone or cut by the eraser.
        let slot = canvas.drawing.strokes.firstIndex { AgentPen.wrote($0) && $0.path.creationDate == drawnAt }!, whole = canvas.drawing.strokes[slot]
        canvas.drawing.strokes.remove(at: slot)
        precondition(targets([circle]).isEmpty, "a drawing missing a stroke isn't a target")
        var cut = whole
        cut.mask = UIBezierPath(rect: whole.renderBounds.insetBy(dx: whole.renderBounds.width / 3, dy: -2))
        canvas.drawing.strokes.insert(cut, at: slot)
        precondition(targets([circle]).isEmpty, "nor one the eraser cut")
        canvas.drawing.strokes[slot] = whole
        precondition(targets([circle]) == [drawing.id], "whole again, it is")
        // Marks on what's being edited wait for the next edit, never fading unread; marks on something else go on.
        marks.editing = [drawing.id]
        precondition(marks.batch([Marks.id(circle)]) == nil && targets([circle, cross]) == [answer.id], "marks on a drawing being edited wait")
        marks.edit([Marks.id(circle)])
        marks.flush()
        precondition(ids().contains(Marks.id(circle)), "and never fade unread")
        marks.editing = []
        canvas.drawing.strokes.removeAll { [loop, far, near, dotted, inside, diagonal].map(Marks.id).contains(Marks.id($0)) }

        // A result that can't be used, or changes nothing, fails before anything is queued.
        let batch = marks.batch(Set([circle, cross].map(Marks.id)))!
        func n(_ note: Note) -> String { String(batch.targets.firstIndex { $0.id == note.id }! + 1) }
        let scribble = Drawing.Part(name: "scribble", strokes: [(0 ..< 1000).map { [Double($0 % 2) * 280 + 10, Double($0) * 0.3] }], labels: [])
        for bad: [Agent.Edit] in [[], [Agent.Edit(target: "9", reply: "x", parts: [], plot: none, say: "")], [Agent.Edit(target: n(answer), reply: " ", parts: [], plot: none, say: "")],
                                  [Agent.Edit(target: n(drawing), reply: "", parts: [], plot: none, say: "Still a login screen")],
                                  [Agent.Edit(target: n(drawing), reply: "", parts: [scribble], plot: none, say: "")]] {
            precondition((try? marks.land(Agent.Edits(reading: "unclear", edits: bad), batch)) == nil && marks.pending.isEmpty, "unusable: \(bad.map(\.target))")
        }

        // Marks erased while Muse works take the instruction back: nothing changes, and they're free for the next edit.
        let logIn = Drawing.Part(name: " SIGN IN BUTTON", strokes: [rect(CGRect(x: 60, y: 236, width: 180, height: 58))], labels: [label("Log in", 112, 258, 16)])
        let edits = Agent.Edits(reading: "Log in; both roots", edits: [
            Agent.Edit(target: n(drawing), reply: "", parts: [logIn], plot: none, say: "A login screen with a Log in button"),
            Agent.Edit(target: n(answer), reply: "x = ±7", parts: [], plot: none, say: "")])
        let unchanged = ids()
        marks.editing.formUnion(batch.ids)
        try marks.land(edits, batch)
        canvas.drawing.strokes.removeAll { Marks.id($0) == Marks.id(cross) }
        marks.flush()
        precondition(ids() == unchanged.subtracting([Marks.id(cross)]) && marks.editing.isEmpty && marks.notes.contains { $0.id == answer.id && $0.reply == "x = 7" },
                     "taken back")
        canvas.drawing.strokes.append(cross)

        // Through the edit's own path: Muse changing nothing is a failed edit, as Muse failing is. The grids go and the
        // marks stay, free for the next edit, with an orange dot by them that tries them again. The dot goes once an edit
        // takes them, or they're erased.
        func orange() -> [Bubble] { marks.bubbles.filter { $0.retry != nil } }
        let corner = Marks.anchor(batch.marks.reduce(CGRect.null) { $0.union(Marks.bounds($1, turn: 0, zoom: 1)) }, 1)
        controller.history.removeAllActions()
        Offline.reply(#"{"reading": "a circle and a line, no words", "edits": []}"#)
        marks.penDown(editing: true)
        marks.penUp(writing: true, editing: true)
        let reading = try await until(2.5) { !marks.grids.isEmpty }
        precondition(reading && marks.grids.count == 2 && marks.editing.isSuperset(of: batch.ids), "a grid over each target while Muse reads")
        let failed = try await until(2) { !orange().isEmpty }, retry = orange().first
        precondition(failed && orange().count == 1 && retry?.anchor == corner && marks.grids.isEmpty && marks.editing.isEmpty && !controller.history.canUndo
                     && ids().isSuperset(of: [circle, cross].map(Marks.id)) && marks.notes.contains { $0.id == answer.id && $0.inked == answer.inked },
                     "no edits: the marks stay, with a dot by them to try again")
        _ = retry?.accessibilityActivate()  // Offline has nothing queued: it fails
        precondition(!marks.bubbles.contains { $0 === retry } && marks.editing.isSuperset(of: batch.ids), "the dot goes as it tries them again")
        let refailed = try await until(2) { orange().count == 1 }, next = orange().first
        marks.penDown(editing: true)
        marks.penUp(writing: true, editing: true)
        let taken = try await until(2.5) { !marks.bubbles.contains { $0 === next } }
        precondition(refailed && taken && marks.editing.isSuperset(of: batch.ids), "the next edit takes the marks, and their dot")
        let third = try await until(2) { orange().count == 1 }
        canvas.drawing.strokes.removeAll { [circle, cross].map(Marks.id).contains(Marks.id($0)) }
        marks.penDown()
        marks.penUp(writing: false)  // the eraser
        let erased = try await until(1) { orange().isEmpty }
        precondition(third && erased && Offline.requests == 4, "erased, their dot goes: \(Offline.requests) requests")
        canvas.drawing.strokes += [circle, cross]

        // The edit lands as one step of undo: only the button's strokes change, the answer is rewritten where it was,
        // and the marks fade off the page, pictured in its colours over it, turned and zoomed.
        func points(_ stroke: PKStroke) -> [[CGFloat]] { stroke.path.map { [$0.location.x, $0.location.y] } }
        func ink(_ part: Drawing.Part) throws -> Set<[[CGFloat]]> {
            Set(try Marks.drawn(Drawing(reading: "", kind: "ink", say: "", parts: [part], plot: none), in: box, turn: 0, zoom: 1, date: .now).map(points))
        }
        let before = ids(), oldInk = Set(marks.strokes(of: drawing).map(points)), oldAnswer = Set(marks.strokes(of: answer).map(Marks.id))
        let (oldButton, newButton) = (try ink(signIn), try ink(logIn))
        let middle = controller.center
        controller.rotation = 0.4
        controller.show(middle, zoom: 1.5)
        canvas.overrideUserInterfaceStyle = .dark
        canvas.updateTraitsIfNeeded()  // off screen, traits wait for the next update
        precondition(canvas.traitCollection.userInterfaceStyle == .dark)
        event()
        try marks.land(edits, batch)
        marks.flush()
        event()
        let redrawn = marks.notes.first { $0.id == drawing.id }!, rewritten = marks.notes.first { $0.id == answer.id }!
        let newInk = Set(marks.strokes(of: redrawn).map(points))
        let names = redrawn.source?.parts.map { $0.name } ?? []
        precondition(redrawn.inked != drawing.inked && names == ["title", "email field", "password field", " SIGN IN BUTTON"]
                     && redrawn.reply == "A login screen with a Log in button" && redrawn.rect == box, "the drawing, redrawn in its box: \(names)")
        let (gone, came) = (oldInk.subtracting(newInk), newInk.subtracting(oldInk))
        precondition(gone == oldButton, "only the old button's strokes go: \(gone.count) of \(oldButton.count)")
        precondition(came == newButton, "only the new button's strokes come: \(came.count) of \(newButton.count)")
        precondition(rewritten.reply == "x = ±7" && rewritten.inked != answer.inked && !marks.strokes(of: rewritten).isEmpty
                     && ids().isDisjoint(with: oldAnswer) && rewritten.rect!.origin == block.origin, "the answer, rewritten through Room where it was: \(rewritten.rect!) \(block)")
        precondition(ids().isDisjoint(with: [Marks.id(circle), Marks.id(cross)]) && marks.editing.isEmpty, "the marks leave the page")
        let view = marks.written.first { $0.note.id == answer.id }!
        precondition(view.accessibilityLabel == rewritten.reply && view.note.inked == rewritten.inked, "VoiceOver reads the new answer")
        let lay = [circle, cross].reduce(CGRect.null) { $0.union($1.renderBounds) }
        let picture = canvas.subviews.compactMap { $0 as? UIImageView }.first { view in
            [view.frame.minX - lay.minX * 1.5, view.frame.minY - lay.minY * 1.5, view.frame.width - lay.width * 1.5, view.frame.height - lay.height * 1.5].allSatisfy { abs($0) < 0.01 }
        }
        var dark = UIImage(), light = UIImage()
        let scale = min(canvas.traitCollection.displayScale * 1.5, 2048 / max(lay.width, lay.height))
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent { dark = PKDrawing(strokes: [circle, cross]).image(from: lay, scale: scale) }
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { light = PKDrawing(strokes: [circle, cross]).image(from: lay, scale: scale) }
        precondition(picture?.image?.pngData() == dark.pngData() && dark.pngData() != light.pngData(), "the marks fade where they lay, in the page's colours")
        let after = ids()
        controller.undo()
        precondition(ids() == before && marks.notes.contains { $0.id == drawing.id && $0.inked == drawing.inked && $0.reply == "A login screen" }
                     && marks.notes.contains { $0.id == answer.id && $0.inked == answer.inked && $0.reply == "x = 7" }
                     && marks.written.first { $0.note.id == answer.id }?.accessibilityLabel == "x = 7", "one undo brings back the old drawing, answer and marks")
        controller.redo()
        precondition(ids() == after && marks.notes.contains { $0.id == drawing.id && $0.inked == redrawn.inked }
                     && marks.written.first { $0.note.id == answer.id }?.accessibilityLabel == rewritten.reply, "redo makes the edit again")

        // Scratching out the answer as Jev saw it before the edit landed takes the answer as it is now, new ink and all.
        let over = theirs((0 ... 8).map { CGPoint(x: rewritten.rect!.minX + CGFloat($0) * rewritten.rect!.width / 8, y: rewritten.rect!.minY + CGFloat($0 % 2) * 20) })
        canvas.drawing.strokes.append(over)
        event()
        marks.scratch(answer, [Marks.id(over)])
        marks.flush()
        precondition(marks.strokes(of: rewritten).isEmpty && !marks.notes.contains { $0.id == answer.id } && !ids().contains(Marks.id(over)),
                     "scratched out with its new ink, leaving none without a note")
        event()
        controller.undo()
        precondition(!marks.strokes(of: rewritten).isEmpty && marks.notes.contains { $0.id == answer.id && $0.inked == rewritten.inked }, "undo brings it back")

        // An answer the pen can't write becomes a quiet dot where it was; undo writes it back.
        let strike = brushed([CGPoint(x: rewritten.rect!.minX, y: rewritten.rect!.midY), CGPoint(x: rewritten.rect!.maxX, y: rewritten.rect!.midY)])
        canvas.drawing.strokes.append(strike)
        let second = marks.batch([Marks.id(strike)])!
        precondition(second.targets.map(\.id) == [answer.id], "the rewritten answer is the target")
        event()
        try marks.land(Agent.Edits(reading: "", edits: [Agent.Edit(target: "1", reply: "日本", parts: [], plot: none, say: "")]), second)
        marks.flush()
        event()
        let quieted = marks.notes.first { $0.id == answer.id }!
        precondition(quieted.inked == nil && quieted.reply == "日本" && quieted.anchor == rewritten.anchor && marks.strokes(of: rewritten).isEmpty
                     && marks.bubbles.contains { $0.note?.id == answer.id } && !marks.written.contains { $0.note.id == answer.id }, "a quiet dot where it was")
        controller.undo()
        precondition(!marks.bubbles.contains { $0.note?.id == answer.id } && marks.written.contains { $0.note.id == answer.id }
                     && !marks.strokes(of: rewritten).isEmpty, "undo writes it back")

        // Marks brought back by undo never run by themselves, but join the next edit: with Maple's ink erased, they point
        // at nothing, so all of them fade with the next one.
        controller.undo()
        precondition(ids().isSuperset(of: [circle, cross, strike].map(Marks.id)), "undo brings the marks back")
        try await Task.sleep(for: .seconds(2))
        precondition(ids().isSuperset(of: [circle, cross, strike].map(Marks.id)) && marks.editing.isEmpty && Offline.requests == 4,
                     "marks brought back by undo never run by themselves")
        canvas.drawing.strokes.removeAll(where: AgentPen.wrote)
        canvas.drawing.strokes.append(brushed([CGPoint(x: 1600, y: 3400), CGPoint(x: 1640, y: 3420)]))
        marks.penDown(editing: true)
        marks.penUp(writing: true, editing: true)
        try await Task.sleep(for: .seconds(2))
        precondition(!canvas.drawing.strokes.contains(where: AgentPen.edit) && Offline.requests == 4, "they join the next edit")
        marks.stop()
    }

    static func near(_ a: CGPoint, _ b: CGPoint) {
        precondition(hypot(a.x - b.x, a.y - b.y) < 0.75, "\(a) != \(b)")  // PencilKit rounds scroll offsets to pixels.
    }

    static func coversScreen(_ controller: CanvasController) {
        let screen = controller.view.bounds
        for x in [screen.minX, screen.maxX] {
            for y in [screen.minY, screen.maxY] {
                let point = controller.canvas.convert(CGPoint(x: x, y: y), from: controller.view)
                precondition(controller.canvas.bounds.insetBy(dx: -0.01, dy: -0.01).contains(point), "uncovered screen corner")
            }
        }
    }
}

/// Muse, offline: each request gets the next queued reply a moment later, or a failure when none is queued.
nonisolated final class Offline: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var queued: [String] = []
    nonisolated(unsafe) static var served = 0
    static var requests: Int { lock.withLock { served } }
    static func reply(_ text: String) { lock.withLock { queued.append(text) } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == Muse.endpoint.host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let text: String? = Self.lock.withLock {
            Self.served += 1
            return Self.queued.isEmpty ? nil : Self.queued.removeFirst()
        }
        let body = text.map { try! JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": $0]]]]]) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: body == nil ? 500 : 200, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body ?? Data(#"{"error": {"message": "offline"}, "output": []}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

final class Rotation: UIRotationGestureRecognizer {
    var phase: UIGestureRecognizer.State = .changed
    var pivot = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { pivot }
}
