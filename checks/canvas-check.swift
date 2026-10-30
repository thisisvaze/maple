// Run on a booted iPad simulator, without model keys:
//   CHECK_DIR=$(mktemp -d); mkdir "$CHECK_DIR/Check.app"
//   sed -n '1p;/^extension UIColor/,$p' Maple/MapleApp.swift > "$CHECK_DIR/Colors.swift"
//   xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios26.0-simulator -swift-version 6 \
//     -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault -parse-as-library \
//     Maple/{CanvasController,QuickShape,Shape,Voice,Transcribe,Marks,Bubble,Written,Note,Page,History,Memory,Grouping,Agent,Muse,MuseImage,Drawing,Figure,Computed,Hershey,Handwriting,Room,AgentPen,Jev,Thinking}.swift \
//     "$CHECK_DIR/Colors.swift" checks/canvas-check.swift -o "$CHECK_DIR/Check.app/canvas-check"
//   plutil -create xml1 "$CHECK_DIR/Check.app/Info.plist"
//   plutil -insert CFBundleIdentifier -string dev.maple.canvas-check "$CHECK_DIR/Check.app/Info.plist"
//   cp Maple/*.jhf Maple/hand.json "$CHECK_DIR/Check.app/"
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
        let controller = open(page)
        near(controller.center, CGPoint(x: 2000, y: 3000))
        precondition(controller.rotation == 0 && controller.canvas.zoomScale == 1.5)

        let canvas = controller.canvas, pivot = CGPoint(x: 190, y: 730)
        precondition(canvas.undoManager === controller.history, "strokes undo in the page, though its canvas has a window of its own")
        precondition(controller.view.interactions.contains { $0 is UIPencilInteraction }, "the Pencil's taps go to the key window, not the page's")
        let anchor = CGPoint(x: 2000, y: 3000)
        let note = Note(mark: "question", trigger: [], anchor: anchor, zoom: 1.5, reading: "test", reply: "test")
        let drawn = AgentPen.stroke([anchor, CGPoint(x: 2100, y: 3000)], width: 3, step: 2)
        controller.marks.apply(.init(add: [drawn], notes: [note]))
        let bubble = controller.marks.add(Bubble(anchor: anchor, zoom: 1.5, turn: 0, note: note))
        let ink = canvas.drawing.dataRepresentation()
        let twist = Rotation()
        twist.pivot = pivot
        controller.rotate(twist)  // the first sight of the fingers turns nothing
        precondition(controller.rotation == 0)

        for delta: CGFloat in [.pi / 4, .pi / 2, -.pi * 7 / 6, .pi * 6] {
            let before = canvas.convert(pivot, from: controller.view)
            let turned = controller.rotation
            twist.angle += delta
            controller.rotate(twist)
            near(canvas.convert(pivot, from: controller.view), before)
            precondition(abs((controller.rotation - turned - delta).remainder(dividingBy: 2 * .pi)) < 0.001, "the page turns as the fingers do")
            coversScreen(controller)
            near(bubble.convert(.zero, to: controller.view), canvas.convert(CGPoint(x: anchor.x * canvas.zoomScale, y: anchor.y * canvas.zoomScale), to: controller.view))
        }
        precondition(canvas.drawing.dataRepresentation() == ink, "turning the view never rewrites ink")
        func shadow() -> Bool? {
            ((NSClassFromString("PKHoverSettings") as? NSObject.Type)?.perform(NSSelectorFromString("sharedSettings"))?.takeUnretainedValue() as? NSObject)?.value(forKey: "toolShadowActive") as? Bool
        }
        precondition(abs(controller.rotation) > CanvasController.straight && shadow() == false, "no Pencil shadow on a turned page, where it would fall in the wrong place")
        let lying = controller.rotation
        controller.rotation = CanvasController.straight / 2
        controller.show(controller.center, zoom: canvas.zoomScale)
        precondition(shadow() == true, "and it's back on a straight one")
        controller.rotation = lying
        controller.show(controller.center, zoom: canvas.zoomScale)
        precondition(canvas.transform == .identity && controller.turner.transform != .identity, "the canvas stays upright; its turner turns")
        controller.scrollViewWillBeginZooming(canvas, with: nil)
        func attachment(_ v: UIView) -> UIView? { "\(type(of: v))" == "PKCanvasAttachmentView" ? v : v.subviews.lazy.compactMap(attachment).first }
        let tiles = attachment(canvas)?.subviews.filter { type(of: $0) == UIView.self } ?? []
        precondition(!tiles.isEmpty && tiles.allSatisfy { $0.layer.speed == 1000 }, "PencilKit's tiles are where instantTiles looks, and fade in at once")
        controller.canvasViewDidBeginUsingTool(canvas)
        precondition(tiles.allSatisfy { $0.layer.speed == 1 }, "the pen coming down puts PencilKit back at its own pace")
        controller.canvasViewDidEndUsingTool(canvas)
        let installed = controller.turner.gestureRecognizers!.first { $0 is UIRotationGestureRecognizer }!
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
        let reopened = open(page)
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
        try await boxes()
        try me()
        try snapping()
        try savedHistory()
        try voicePlacement()
        print("canvas ok: rotation pivot, coverage, overlays, old/new viewport, resize, undo/redo, agent ink after reload, undo by id, writing while the pen rests, fading and scratching out answers, reading frame, edit brush")
    }

    static func savedHistory() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString), page = Page(url: folder, edited: .now)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            Store.queue.sync {}
            UserDefaults.standard.removeObject(forKey: page.viewportKey)
            try? FileManager.default.removeItem(at: folder)
        }
        func stroke(_ i: Int) -> PKStroke {
            let drawn = AgentPen.stroke([CGPoint(x: 2000, y: 3000 + i), CGPoint(x: 2060, y: 3000 + i)], width: 3, step: 2)
            return PKStroke(ink: PKInk(.pen, color: .black), path: drawn.path)
        }
        func gesture(_ c: CanvasController, _ edit: (inout PKDrawing) -> Void) {
            c.canvasViewDidBeginUsingTool(c.canvas)
            var drawing = c.canvas.drawing
            edit(&drawing)
            c.canvas.drawing = drawing
            c.canvasViewDidEndUsingTool(c.canvas)
            c.marks.settle()
            c.marks.waiting?.cancel()  // no model calls in a persistence check
        }
        // A legacy page gains history from this opening onward. 105 additions retain the last 100, as single-stroke deltas.
        try PKDrawing(strokes: [stroke(0)]).dataRepresentation().write(to: page.ink)
        var c = open(page)
        for i in 1...105 { gesture(c) { $0.strokes.append(stroke(i)) } }
        precondition(c.history.undoCount == 100 && c.history.redoCount == 0)
        precondition(c.history.past.allSatisfy { $0.before.empty && $0.after.state.drawing.strokes.count == 1 }, "history stores changes, not whole pages")
        c.saveNow()
        c = open(page)
        precondition(c.loadError == nil && c.canvas.drawing.strokes.count == 106 && c.history.undoCount == 100, "100 steps survive a reload")
        for _ in 0..<40 { c.undo() }
        c.saveNow()
        c = open(page)
        precondition(c.canvas.drawing.strokes.count == 66 && c.history.undoCount == 60 && c.history.redoCount == 40, "both stacks survive")
        for _ in 0..<40 { c.redo() }
        for _ in 0..<100 { c.undo() }
        precondition(c.canvas.drawing.strokes.count == 6 && !c.history.canUndo && c.history.redoCount == 100, "oldest five edits stay beyond the retained history")
        c.saveNow()
        c = open(page)
        for _ in 0..<100 { c.redo() }
        precondition(c.canvas.drawing.strokes.count == 106 && !c.history.canRedo)
        c.undo()
        gesture(c) { $0.strokes.append(stroke(200)) }
        precondition(!c.history.canRedo, "new writing discards the old redo branch")

        // Pixel erasure changes a stroke without changing its ID. Undo restores its mask and depth after reopening.
        let original = c.canvas.drawing.strokes.map(Marks.id)
        gesture(c) { $0.strokes[2].mask = UIBezierPath(rect: CGRect(x: 2010, y: 2990, width: 20, height: 30)) }
        precondition(c.history.past.last?.before.state.drawing.strokes.count == 1 && c.history.past.last?.after.state.drawing.strokes.count == 1)
        c.saveNow()
        c = open(page)
        precondition(c.canvas.drawing.strokes[2].mask != nil)
        c.undo()
        precondition(c.canvas.drawing.strokes.map(Marks.id) == original && c.canvas.drawing.strokes[2].mask == nil, "erased ink returns to its layer")
        c.redo()

        // A whole answer and its note undo together. Red edit instructions never enter the saved history.
        let answer = stroke(300), note = Note(mark: "question", trigger: [], anchor: .zero, zoom: 1, reading: "test", reply: "answer")
        var brush = stroke(301)
        brush.ink = PKInk(.pen, color: AgentPen.coral)
        c.canvas.drawing.strokes.insert(brush, at: 0)
        c.marks.apply(.init(add: [answer], remove: [Marks.id(brush)], notes: [note]))
        c.saveNow()
        c = open(page)
        c.undo()
        precondition(c.marks.notes.isEmpty && !c.canvas.drawing.strokes.contains(where: AgentPen.edit))
        c.redo()
        precondition(c.marks.notes == [note] && c.canvas.drawing.strokes.last.map(Marks.id) == Marks.id(answer))

        // An invalid archive is not silently opened as an older page and overwritten.
        let bad = Data("broken archive".utf8)
        try bad.write(to: page.stateFile, options: .atomic)
        let broken = open(page)
        precondition(broken.loadError != nil && !broken.canvas.isUserInteractionEnabled)
        broken.dirty = true
        broken.saveNow()
        let untouched = try Data(contentsOf: page.stateFile)
        precondition(untouched == bad)
        print("history ok: 100 compact steps, reload, redo branch, pixel erasure, answer notes, edit cleanup, corrupt-file protection")
    }

    static func voicePlacement() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString), page = Page(url: folder, edited: .now)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            Store.queue.sync {}
            UserDefaults.standard.removeObject(forKey: page.viewportKey)
            try? FileManager.default.removeItem(at: folder)
        }
        let c = open(page), marks = c.marks!
        c.rotation = 0.4
        c.show(c.center, zoom: 1.7)
        let line = marks.onPage(CGRect(x: 200, y: 600, width: 180, height: 0))
        let ink = AgentPen.stroke(Array(line.prefix(2)), width: 3, step: 2)
        c.canvas.drawing.strokes = [PKStroke(ink: c.pen.ink, path: ink.path)]
        let fallback = marks.onPage(CGRect(x: 24, y: 96, width: 0, height: 0))[0]
        let note = Note(mark: "voice", trigger: [], anchor: fallback, zoom: c.canvas.zoomScale, reading: "what is this?", reply: "This is your answer.", turn: marks.turn)
        let first = marks.add(marks.voiceBubble(for: note))
        let rect = first.convert(first.bounds, to: c.view)
        precondition(c.view.bounds.contains(rect) && rect.minY > 450 && !rect.intersects(CGRect(x: 197, y: 597, width: 186, height: 6)),
                     "voice reply stays visible near the latest ink, clear of it: \(rect)")
        let second = marks.add(marks.voiceBubble(for: note))
        let next = second.convert(second.bounds, to: c.view)
        precondition(c.view.bounds.contains(next) && !next.intersects(rect), "voice replies avoid existing bubbles")
        print("voice placement ok: nearby writing, rotation, zoom, screen bounds, existing replies")
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
        let controller = open(page)
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
        let pencil = controller.view.interactions.compactMap { $0 as? UIPencilInteraction }[0]
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
        // The eraser and the brush keep their width on screen as the page zooms, from any zoom change, not only a pinch's end.
        doubleTap()
        for zoom: CGFloat in [0.3, 3, 1] {
            controller.show(controller.center, zoom: zoom)
            controller.scrollViewDidZoom(canvas)
            let width = (canvas.tool as! PKEraserTool).width
            precondition(abs(width - controller.eraser.width) < 0.3 && width * zoom < 60, "the eraser fits the screen at zoom \(zoom): \(width * zoom) points")
        }
        doubleTap()
        for zoom: CGFloat in [3, 2, 0.5, 1] {
            controller.show(controller.center, zoom: zoom)
            controller.scrollViewDidZoom(canvas)
            let width = (canvas.tool as! PKInkingTool).width * canvas.zoomScale
            precondition(controller.brushing && abs(width - CanvasController.editWidth) < 0.06, "the brush is editWidth wide on screen at zoom \(zoom): \(width)")
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
                     && ids().isDisjoint(with: oldAnswer) && abs(rewritten.rect!.minX - block.minX) < 0.01 && abs(rewritten.rect!.maxY - block.maxY) < 1,
                     "the answer, rewritten through Room where it was, on the same line: \(rewritten.rect!) \(block)")
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

    /// Draw, rest the pen, and it snaps: the page's side of what checks/shape-check.swift reads.
    static func snapping() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = Page(url: folder, edited: .now)
        defer {
            Store.queue.sync {}
            UserDefaults.standard.removeObject(forKey: page.viewportKey)
            try? FileManager.default.removeItem(at: folder)
        }
        UserDefaults.standard.set([2150.0, 3100.0, 1.0], forKey: page.viewportKey)
        let controller = open(page), canvas = controller.canvas, quick = controller.quickShape!
        func wobbly(_ corners: [CGPoint]) -> [CGPoint] {
            zip(corners, corners.dropFirst()).flatMap { a, b in (0..<30).map { i in
                let t = CGFloat(i) / 30, w = sin(CGFloat(i) * 0.7) * 1.5
                return CGPoint(x: a.x + (b.x - a.x) * t + w, y: a.y + (b.y - a.y) * t - w)
            } } + [corners.last!]
        }
        func draw(_ points: [CGPoint]) {
            quick.start(points[0])
            quick.move(Array(points.dropFirst()))
        }
        precondition(canvas.gestureRecognizers?.contains { $0 === quick } == true && quick.cancelsTouchesInView == false, "it watches and takes nothing")

        // A hand-drawn box, the pen resting: a perfect box of the person's own ink, as one step of undo.
        let box = wobbly([CGPoint(x: 2000, y: 3000), CGPoint(x: 2300, y: 3004), CGPoint(x: 2298, y: 3200), CGPoint(x: 2002, y: 3197), CGPoint(x: 2000, y: 3000)])
        draw(box)
        quick.rested()
        guard case let .polygon(corners, true)? = quick.shape, corners.count == 4 else { preconditionFailure("a box: \(String(describing: quick.shape))") }
        precondition(quick.preview.superlayer === canvas.layer && !canvas.panGestureRecognizer.isEnabled, "shown, and fingers don't pan while it's held")
        quick.lift()
        precondition(canvas.drawing.strokes.count == 1 && AgentPen.person(canvas.drawing.strokes[0]) && canvas.panGestureRecognizer.isEnabled && quick.preview.superlayer == nil, "it lands as the person's ink")
        let drawn = canvas.drawing.strokes[0].path, xs = (0..<drawn.count).map { drawn[$0].location.x }, ys = (0..<drawn.count).map { drawn[$0].location.y }
        let left = xs.min()!, right = xs.max()!, top = ys.min()!, bottom = ys.max()!
        for i in 0..<drawn.count {
            let p = drawn[i].location, sideways = min(abs(p.x - left), abs(p.x - right)), upways = min(abs(p.y - top), abs(p.y - bottom))
            precondition(min(sideways, upways) < 0.01, "every point on a side of a true rectangle")
        }
        precondition(controller.history.canUndo, "a step of undo")
        controller.history.undo()
        precondition(canvas.drawing.strokes.isEmpty, "and undo takes it")

        // Writing stays writing, and a stroke not held isn't touched.
        let writing: [CGPoint] = (0..<200).map { (i: Int) -> CGPoint in
            let n = CGFloat(i), x = 2000 + n * 1.2 + sin(n / 4) * 8, y = 3000 + cos(n / 4) * 14 + sin(n / 11) * 6
            return CGPoint(x: x, y: y)
        }
        draw(writing)
        quick.rested()
        precondition(quick.shape == nil && quick.snapped == nil && canvas.panGestureRecognizer.isEnabled, "a pause in writing does nothing")
        quick.lift()
        precondition(canvas.drawing.strokes.isEmpty, "and nothing lands")
        draw(wobbly([CGPoint(x: 2000, y: 3000), CGPoint(x: 2010, y: 3002)]))
        quick.rested()
        precondition(quick.shape == nil, "a stroke too small for a shape is writing")
        quick.lift()

        // A hand's tremor at the snap doesn't tilt it; dragging does. A finger locks a line to fifteen-degree steps, by the screen.
        controller.rotation = 0.5
        controller.show(controller.center, zoom: 1)
        let line = wobbly([CGPoint(x: 2000, y: 3000), CGPoint(x: 2300, y: 3030)])
        draw(line)
        quick.rested()
        let snapped = quick.shape, end = line.last!
        quick.move([CGPoint(x: end.x + 2, y: end.y - 2)])
        precondition(quick.shape == snapped, "a tremor moves nothing")
        quick.move([CGPoint(x: end.x + 30, y: end.y + 90)])
        guard case let .line(from, free)? = quick.shape else { preconditionFailure("a line") }
        precondition(Shape.distance(free, CGPoint(x: end.x + 30, y: end.y + 90)) < 1e-6, "the end follows the pen")
        quick.fingers.insert(UITouch())
        quick.fingerChanged()
        guard case let .line(_, locked)? = quick.shape else { preconditionFailure("a line") }
        let on = (atan2(locked.y - from.y, locked.x - from.x) + controller.marks.turn) * 180 / .pi
        precondition(abs(on / 15 - (on / 15).rounded()) < 1e-6, "fifteen-degree steps on screen, though the page is turned: \(on)")
        quick.fingers.removeAll()
        quick.fingerChanged()
        guard case let .line(_, freed)? = quick.shape else { preconditionFailure("a line") }
        precondition(Shape.distance(freed, free) < 1e-6, "a finger lifted frees it")
        quick.lift()
        precondition(canvas.drawing.strokes.count == 1, "one stroke")

        // A finger on an oval makes a circle, and the shape lands as it shows.
        controller.history.undo()
        controller.rotation = 0
        controller.show(controller.center, zoom: 1)
        let oval: [CGPoint] = (0...120).map { (i: Int) -> CGPoint in
            let a = CGFloat(i) * 0.052
            return CGPoint(x: 2150 + 150 * cos(a), y: 3100 + 90 * sin(a))
        }
        draw(oval)
        quick.rested()
        quick.fingers.insert(UITouch())
        quick.fingerChanged()
        guard case let .ellipse(_, radii, _)? = quick.shape, radii.width == radii.height else { preconditionFailure("a circle: \(String(describing: quick.shape))") }
        quick.lift()
        quick.fingers.removeAll()
        let circle = canvas.drawing.strokes[0].path, c = Shape.middle((0..<circle.count).map { circle[$0].location })
        let radius = (0..<circle.count).map { Shape.distance(circle[$0].location, c) }
        precondition(radius.max()! - radius.min()! < 1, "a true circle: \(radius.max()! - radius.min()!)")
        print("snapping ok: perfect shapes as ink, undo, writing left alone, tremor, dragging, fifteen-degree steps on a turned page, circles")
    }

    /// What Maple remembers: learned on any page, shown in ink on the Me page, and forgotten by striking a line.
    static func me() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "me")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = Page(url: folder, edited: .now), memories = Memories.shared
        let elsewhere = Page(url: folder.deletingLastPathComponent().appending(path: "other"), edited: .now)
        try FileManager.default.createDirectory(at: elsewhere.url, withIntermediateDirectories: true)
        memories.change { $0 = Memory() }
        defer {
            Store.queue.sync {}
            memories.change { $0 = Memory() }
            [page, elsewhere].forEach { UserDefaults.standard.removeObject(forKey: $0.viewportKey) }
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
        }
        precondition(page.isMe && !elsewhere.isMe)

        // An empty Me page says what it's for, and that line is nothing Maple remembers.
        var controller = open(page), marks = controller.marks!
        precondition(marks.notes.count == 1 && marks.notes[0].memory == nil && !marks.strokes(of: marks.notes[0]).isEmpty, "it says what it's for")
        precondition(!controller.history.canUndo, "and that's not the person's to undo")
        controller.saveNow()
        marks.notes.removeAll()
        marks.canvas.drawing = PKDrawing()
        controller.saveNow()

        // Another page learns from what the person says, through Memory's check, and says so in the corner.
        let other = open(elsewhere).marks!
        func answer(_ text: String, _ because: String) -> Agent.Answer {
            Agent.Answer(reading: "", confidence: "high", reply: "", passage: false, remember: [.init(text: text, because: because)])
        }
        other.learn(answer("Is a nurse", "I'm a nurse"), evidence: "I'm a nurse, so what dose?")
        precondition(memories.memory.lines.map(\.text) == ["Is a nurse"] && other.lastTag?.text == "Noted: Is a nurse", "noted")
        other.learn(answer("Is a doctor", "I'm a doctor"), evidence: "I'm a nurse, so what dose?")
        precondition(memories.memory.lines.count == 1, "a claim that quotes nothing they said stays out")
        other.learn(answer("Prefers hints before answers", "hints first"), evidence: "hints first please")
        let nurse = memories.memory.entries[0], hints = memories.memory.entries[1]

        // The Me page shows each in ink, under what's there, in reach of the Pencil and out of the edit brush's.
        Store.queue.sync {}
        controller = open(page)
        marks = controller.marks!
        let canvas = controller.canvas
        precondition(marks.notes.compactMap(\.memory) == [nurse.id, hints.id] && marks.notes.allSatisfy { !marks.strokes(of: $0).isEmpty }, "a line of ink each")
        precondition(marks.notes[1].rect!.minY > marks.notes[0].rect!.maxY, "one under the other")
        func stroke(_ points: [CGPoint]) -> PKStroke { PKStroke(ink: controller.pen.ink, path: AgentPen.stroke(points, width: 3, step: 2).path) }
        let line = marks.notes[0].rect!
        let across = stroke([CGPoint(x: line.minX - 4, y: line.midY), CGPoint(x: line.maxX + 4, y: line.midY + 3)])
        canvas.drawing.strokes.append(across)
        let swept = Marks.bounds(across, turn: 0, zoom: 1)
        precondition(marks.batch([Marks.id(across)])?.targets.isEmpty == true, "the edit brush leaves memory to the person")

        // A straight line along it strikes it out; a word written over it doesn't.
        let word = stroke((0...24).map { CGPoint(x: line.minX + CGFloat($0) * 8, y: line.midY + ($0 % 2 == 0 ? -7 : 7)) })
        canvas.drawing.strokes.append(word)
        precondition(marks.struckLine(Marks.bounds(word, turn: 0, zoom: 1), by: [Marks.id(word)], turn: 0) == nil, "writing isn't a strike")
        canvas.drawing.strokes.removeAll { Marks.id($0) == Marks.id(word) }
        let short = stroke([CGPoint(x: line.minX, y: line.midY), CGPoint(x: line.minX + 10, y: line.midY)])
        precondition(marks.struckLine(Marks.bounds(short, turn: 0, zoom: 1), by: [Marks.id(short)], turn: 0) == nil, "nor is a tick on it")
        let struck = marks.struckLine(swept, by: [Marks.id(across)], turn: 0)
        precondition(struck?.memory == nurse.id, "a line along it is")
        marks.scratch(struck!, [Marks.id(across)])
        marks.flush()
        precondition(memories.memory.lines.map(\.id) == [hints.id] && marks.lastTag?.text == "Forgot: Is a nurse", "forgotten, at once")
        precondition(memories.memory.entries[0].gone == "struck" && !canvas.drawing.strokes.contains { Marks.id($0) == Marks.id(across) }, "and the strike goes with it")

        // Undo brings it back; what's struck stays struck across a reopening, and no agent can bring it back.
        controller.history.undo()
        precondition(memories.memory.lines.map(\.id) == [nurse.id, hints.id] && marks.notes.count == 2, "undone")
        marks.scratch(marks.notes[0], [])
        marks.flush()
        precondition(memories.memory.lines.map(\.id) == [hints.id], "struck again")
        controller.saveNow()
        Store.queue.sync {}
        let again = open(page)
        precondition(again.marks.notes.compactMap(\.memory) == [hints.id], "it isn't written again")
        other.learn(answer("Is a nurse", "I'm a nurse"), evidence: "I'm a nurse, really")
        precondition(memories.memory.lines.map(\.id) == [hints.id], "the person's strike wins")

        // A Me page that's lost its ink writes it again: losing the page never forgets anything.
        try? FileManager.default.removeItem(at: page.stateFile)
        try? FileManager.default.removeItem(at: page.ink)
        try? FileManager.default.removeItem(at: page.notesFile)
        let fresh = open(page)
        precondition(fresh.marks.notes.compactMap(\.memory) == [hints.id] && memories.memory.lines.map(\.id) == [hints.id], "written again")

        // What the person writes there stands as they wrote it.
        memories.change { $0.written(["Vegetarian"], page: "me") }
        precondition(memories.memory.lines.map(\.text) == [hints.text, "Vegetarian"], "theirs too")
        let reopened = open(page)
        precondition(reopened.marks.notes.compactMap(\.memory) == [hints.id], "their own line stays in their own ink")
        print("me ok: learning on any page, lines of ink, striking, undo, strikes staying, losing the page")
    }

    /// An empty box, filled every way but ink: a painted picture, a computed one, an exact figure, and a question first.
    static func boxes() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = Page(url: folder, edited: .now)
        defer {
            Store.queue.sync {}
            UserDefaults.standard.removeObject(forKey: page.viewportKey)
            try? FileManager.default.removeItem(at: folder)
        }
        UserDefaults.standard.set([2150.0, 3100.0, 1.0], forKey: page.viewportKey)
        let controller = open(page), canvas = controller.canvas, marks = controller.marks!, history = controller.history
        URLProtocol.registerClass(Offline.self)
        let agent = Agent(muse: Muse(key: "offline"))
        marks.agent = agent
        marks.painter = MuseImage(key: "offline")
        func ids() -> Set<String> { Set(canvas.drawing.strokes.map(Marks.id)) }
        func until(_ seconds: Double, _ done: () -> Bool) async throws -> Bool {
            let end = Date() + seconds
            while !done(), Date() < end { try await Task.sleep(for: .milliseconds(40)) }
            return done()
        }
        func theirs(_ points: [CGPoint]) -> PKStroke { PKStroke(ink: controller.pen.ink, path: AgentPen.stroke(points, width: 3, step: 2).path) }
        func drawing(_ kind: String, _ extra: String = "") -> String {
            #"{"reading": "the label", "kind": "\#(kind)", "say": "it shows this", "parts": [], "plot": {"expression": "", "xMin": 0, "xMax": 0, "yMin": 0, "yMax": 0}\#(extra)}"#
        }
        let box = CGRect(x: 2000, y: 3000, width: 300, height: 200), png = Data([0])
        let frame = theirs([CGPoint(x: 2000, y: 3000), CGPoint(x: 2300, y: 3000), CGPoint(x: 2300, y: 3200), CGPoint(x: 2000, y: 3200), CGPoint(x: 2000, y: 3000)])
        canvas.drawing.strokes.append(frame)
        let trigger = [Marks.id(frame)]
        func fill(asked: Note? = nil, reply: [String] = []) async {
            await marks.draw(agent, png, png, threads: [], trigger: trigger, box: box, turn: 0, zoom: 1, asked: asked, reply: reply)
            marks.flush()
        }

        // A picture lands in one step of undo, under the ink, with no ink of its own.
        Offline.reply(drawing("picture", #", "picture": {"prompt": "a yard in spring", "search": false}"#))
        await fill()
        let painted = marks.notes.last!
        precondition(painted.mark == "frame" && painted.picture?.hasSuffix(".webp") == true && marks.strokes(of: painted).isEmpty, "a picture has no strokes of its own")
        precondition(FileManager.default.fileExists(atPath: page.pictures.appending(path: painted.picture!).path), "it's kept with the page")
        let view = marks.pictures[0]
        precondition(view.superview === canvas && canvas.subviews.first === view, "under PencilKit's views, so ink shows over it")
        precondition(!view.isUserInteractionEnabled && view.contentMode == .scaleAspectFill && view.accessibilityLabel == "Picture: it shows this", "the Pencil writes through it")
        for (turned, zoom) in [(CGFloat(0), CGFloat(0.5)), (0, 2), (.pi / 6, 0.5), (.pi / 6, 2)] {
            controller.rotation = turned
            controller.show(CGPoint(x: 2150, y: 3100), zoom: zoom)
            controller.scrollViewDidZoom(canvas)
            let corner = view.convert(CGPoint(x: 300, y: 200), to: canvas)
            near(corner, CGPoint(x: 2300 * zoom, y: 3200 * zoom))
        }
        controller.rotation = 0
        controller.show(CGPoint(x: 2150, y: 3100), zoom: 1)
        controller.scrollViewDidZoom(canvas)
        history.undo()
        precondition(marks.notes.isEmpty && marks.pictures.isEmpty && view.superview == nil, "undo takes it away")
        history.redo()
        precondition(marks.notes.count == 1 && marks.pictures.count == 1 && canvas.subviews.first === marks.pictures[0], "redo brings it back, under the ink")

        // A scribble on it finds it, though it has no ink to touch, and takes it away as one step.
        let scribble = theirs([CGPoint(x: 2100, y: 3100), CGPoint(x: 2150, y: 3120), CGPoint(x: 2110, y: 3130)])
        canvas.drawing.strokes.append(scribble)
        precondition(marks.answer(touching: [Marks.id(scribble)])?.id == painted.id, "a mark on a picture touches it")
        let outside = theirs([CGPoint(x: 2400, y: 3400), CGPoint(x: 2450, y: 3420)])
        canvas.drawing.strokes.append(outside)
        precondition(marks.answer(touching: [Marks.id(outside)]) == nil, "a mark beside it doesn't")
        marks.scratch(painted, [Marks.id(scribble)])
        marks.flush()
        precondition(marks.pictures.isEmpty && !ids().contains(Marks.id(scribble)), "scratched out")
        history.undo()
        precondition(marks.pictures.count == 1 && ids().contains(Marks.id(scribble)), "and back")
        history.undo()  // the ink appended here isn't a step; this goes back past the picture
        history.redo()

        // The edit brush repaints a picture from a copy with the marks on it, in the same box and as one step of undo.
        canvas.drawing.strokes.removeAll { $0.ink.inkType == .pen && Marks.id($0) != Marks.id(frame) }
        let edit = #"{"reading": "make it pink", "edits": [{"target": "1", "reply": "", "parts": [], "plot": {"expression": "", "xMin": 0, "xMax": 0, "yMin": 0, "yMax": 0}, "say": "now pink", "repaint": "Make what's in the red ring pink."}]}"#
        let ring = PKStroke(ink: PKInk(.pen, color: AgentPen.coral), path: AgentPen.stroke([CGPoint(x: 2100, y: 3050), CGPoint(x: 2150, y: 3050), CGPoint(x: 2150, y: 3100), CGPoint(x: 2100, y: 3050)], width: 3.5, step: 2).path)
        canvas.drawing.strokes.append(ring)
        let batch = marks.batch([Marks.id(ring)])!
        precondition(batch.targets.map(\.id) == [painted.id], "a mark in a picture points at it")
        let copies = try marks.marked(batch.targets[0], batch)
        precondition(copies.count == 2 && copies[0] != copies[1], "the picture, and a copy with the marks in red")
        let (_, _, seen) = await marks.request(batch)
        precondition(seen[0].kind == "picture" && seen[0].drawing?.prompt == "a yard in spring", "Muse knows it as a picture, and its prompt")
        Offline.reply(edit)
        marks.edit([Marks.id(ring)])
        let repainted = try await until(4) { marks.notes.first?.reply == "now pink" || !marks.pending.isEmpty }
        marks.flush()
        precondition(repainted, "repainted")
        precondition(marks.notes.first?.picture != painted.picture && marks.pictures.first?.note.picture == marks.notes.first?.picture && !ids().contains(Marks.id(ring)), "the new picture replaces the old, and the marks go")
        history.undo()
        precondition(marks.notes.first?.picture == painted.picture, "undo brings the old picture back")
        history.redo()

        // It reloads with the page, and shows on its card.
        controller.saveNow()
        let reopened = open(page)
        precondition(reopened.marks.pictures.count == 1 && reopened.canvas.subviews.first === reopened.marks.pictures[0], "a picture comes back with its page")
        let card = await page.thumbnail(dark: false)
        precondition(card != nil, "a picture is on the page's card")
        marks.notes.removeAll()
        marks.sync()

        // A computed picture is the app's own: a picture from the equations, and ink for its lines.
        let region = #""xMin": -4, "xMax": 4, "yMin": -3, "yMax": 3"#
        Offline.reply(drawing("computed", #", "computed": {"field": "exp(-2*sqrt(x^2 + y^2))", "u": "", "v": "", "curves": [{"x": "2*cos(t)", "y": "2*sin(t)", "tMin": 0, "tMax": 6.3}], "labels": [], \#(region)}"#))
        await fill()
        let density = marks.notes.last!
        precondition(density.picture?.hasSuffix(".png") == true && marks.strokes(of: density).count == 1, "a computed picture, and its orbit in ink")
        precondition(UIImage(contentsOfFile: page.pictures.appending(path: density.picture!).path)?.size == CGSize(width: 600, height: 400), "at 2× its box")
        history.undo()

        // A figure is all ink, measured by the app; one that doesn't measure up goes back to Muse once, with the reason.
        let sides = #""points": [{"name": "A", "x": "0", "y": "0", "label": true}, {"name": "B", "x": "4", "y": "0", "label": true}, {"name": "C", "x": "0", "y": "3", "label": true}], "lines": [["A", "B", "C", "A"]], "circles": []"#
        let wrong = #", "figure": {\#(sides), "lengths": [{"from": "B", "to": "C", "expected": "6", "unit": ""}], "angles": []}"#
        let right = #", "figure": {\#(sides), "lengths": [{"from": "B", "to": "C", "expected": "5", "unit": "cm"}], "angles": [{"vertex": "A", "from": "B", "to": "C", "expected": "90"}]}"#
        let asked = Offline.requests
        Offline.reply(drawing("figure", wrong))
        Offline.reply(drawing("figure", right))
        await fill()
        precondition(Offline.requests == asked + 2, "sent back once")
        let figure = marks.notes.last!
        precondition(figure.picture == nil && marks.intact(figure.source!, marks.strokes(of: figure), in: figure.rect), "a figure is ink, and edits like a drawing")
        history.undo()

        // Two meanings: Maple writes the question beside the box, and the next mark in the box answers it.
        Offline.reply(drawing("ask", #", "question": "The planet or the element?""#))
        await fill()
        let question = marks.notes.last!
        precondition(question.mark == "ask" && question.reply == "The planet or the element?" && question.asked?.box == box && marks.grids.isEmpty, "asked: \(question)")
        precondition(!marks.strokes(of: question).isEmpty && question.inked != nil, "in ink beside the box, no bubble")
        let reply = theirs([CGPoint(x: 2050, y: 3050), CGPoint(x: 2120, y: 3060)])
        canvas.drawing.strokes.append(reply)
        let mark = Marks.bounds(reply, turn: 0, zoom: 1)
        precondition(marks.question(answeredBy: mark, turn: 0, zoom: 1)?.id == question.id, "a mark in its box answers it")
        precondition(marks.question(answeredBy: CGRect(x: 2900, y: 3900, width: 20, height: 20), turn: 0, zoom: 1) == nil, "a mark elsewhere doesn't")
        precondition(marks.batch([Marks.id(reply)])?.targets.isEmpty == true, "the edit brush leaves a question alone")
        let inkBefore = ids()
        let asking = Offline.requests
        Offline.reply(drawing("ask", #", "question": "Which?""#))
        await fill(asked: question, reply: [Marks.id(reply)])  // Muse may not ask twice
        precondition(Offline.requests == asking + 1 && marks.notes.contains { $0.id == question.id } && marks.bubbles.contains { $0.retry != nil }, "it stops with an orange dot")
        marks.bubbles.filter { $0.retry != nil }.forEach(marks.remove)
        Offline.reply(drawing("figure", right))
        await fill(asked: question, reply: [Marks.id(reply)])
        precondition(!marks.notes.contains { $0.id == question.id } && marks.notes.last?.mark == "frame", "the box is filled")
        precondition(!ids().contains(Marks.id(reply)) && ids().isDisjoint(with: Set(marks.strokes(of: question).map(Marks.id))) && inkBefore.subtracting(ids()).count > 1, "the question and the reply go")
        history.undo()
        precondition(ids() == inkBefore && marks.notes.contains { $0.id == question.id }, "one step of undo brings them back")
        print("boxes ok: pictures under ink, aligned, undo, scratching, repainting, reload, cards, computed, figures sent back, questions and replies")
    }

    static var windows: [UIWindow] = []  // a window with no scene lasts only as long as someone holds it

    /// The page as it opens, but for its turner: a process with no scene can't convert between windows, so here it sits in
    /// the page, where its center and transform mean the same.
    static func open(_ page: Page) -> CanvasController {
        let controller = CanvasController(page: page)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 820, height: 1180))
        windows.append(window)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = window.bounds
        controller.view.addSubview(controller.turner)
        controller.turner.isHidden = false
        controller.viewDidLayoutSubviews()
        return controller
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
        guard !request.url!.path.contains("/images/") else {  // Muse Image: a dot of a picture
            let dot = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["data": [["b64_json": dot]]]))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
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
    var angle: CGFloat = 0
    override var numberOfTouches: Int { 2 }
    override func location(ofTouch touchIndex: Int, in view: UIView?) -> CGPoint {
        let side: CGFloat = touchIndex == 0 ? 1 : -1
        return CGPoint(x: pivot.x + side * 60 * cos(angle), y: pivot.y + side * 60 * sin(angle))
    }
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { pivot }
}
