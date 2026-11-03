import PencilKit
import Testing
@testable import Maple

extension DeviceChecks {
    @Test func erasedFragmentsRecordAndReload() throws {
        let folder = URL.temporaryDirectory.appending(path: "maple-erase-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = Page(url: folder, edited: .now)
        var opened: [CanvasController] = []
        func open() throws -> CanvasController {
            let c = CanvasController(page: page)
            opened.append(c)
            c.loadViewIfNeeded()
            try #require(c.loadError == nil)
            c.setAIEnabled(false)
            return c
        }
        defer {
            for c in opened { c.marks.stop(); c.saveTask?.cancel(); c.turner.isHidden = true }
            Store.queue.sync {}
            UserDefaults.standard.removeObject(forKey: page.viewportKey)
            try? FileManager.default.removeItem(at: folder)
        }
        func stroke(_ y: CGFloat) -> PKStroke {
            let line = AgentPen.stroke([CGPoint(x: 100, y: y), CGPoint(x: 300, y: y)], width: 4, step: 2)
            return PKStroke(ink: PKInk(.pen, color: .black), path: line.path)
        }
        func erase(_ c: CanvasController, _ change: (inout [PKStroke]) -> Void) {
            c.canvas.tool = c.eraser
            c.canvasViewDidBeginUsingTool(c.canvas)
            var strokes = c.canvas.drawing.strokes
            change(&strokes)
            c.canvas.drawing = PKDrawing(strokes: strokes)
            c.canvasViewDidEndUsingTool(c.canvas)
            c.marks.settle()
            c.saveNow()
        }
        let under = stroke(100), original = stroke(130), over = stroke(160)
        let parts: [PKStroke]
        if #available(iOS 27, *) {
            parts = [original.substroke(range: 0...35), original.substroke(range: 65...100)]
        } else {
            parts = [CGRect(x: 95, y: 120, width: 75, height: 20), CGRect(x: 230, y: 120, width: 75, height: 20)].map {
                PKStroke(ink: original.ink, path: original.path, mask: UIBezierPath(rect: $0), randomSeed: original.randomSeed)
            }
        }
        try #require(parts.count == 2 && parts.allSatisfy { Marks.id($0) == Marks.id(original) }, "Erased fragments share the original logical stroke ID.")
        var c = try open()
        c.canvas.drawing = PKDrawing(strokes: [under, original, over])
        erase(c) { $0.replaceSubrange(1...1, with: parts) }
        #expect(c.history.past.last?.before.state.drawing.strokes.count == 1)
        #expect(c.history.past.last?.after.state.drawing.strokes.count == 2)
        c = try open()
        #expect(c.canvas.drawing.strokes.map(Marks.id) == [under, parts[0], parts[1], over].map(Marks.id))
        c.undo()
        #expect(c.canvas.drawing.strokes.map(Marks.id) == [under, original, over].map(Marks.id))
        c.redo()
        #expect(c.canvas.drawing.strokes.count == 4)
        // Changing only one piece must carry its unchanged sibling through the ID-based undo patch.
        erase(c) { $0[1].mask = UIBezierPath(rect: CGRect(x: 100, y: 120, width: 25, height: 20)) }
        #expect(c.history.past.last?.before.state.drawing.strokes.count == 2)
        #expect(c.history.past.last?.after.state.drawing.strokes.count == 2)
        c = try open()
        c.undo()
        #expect(c.canvas.drawing.strokes.count == 4 && c.canvas.drawing.strokes[1].mask?.cgPath == parts[0].mask?.cgPath)
        erase(c) { $0.remove(at: 1) }
        c = try open()
        #expect(c.canvas.drawing.strokes.count == 3)
        c.undo()
        #expect(c.canvas.drawing.strokes.count == 4)
        c.redo()
        #expect(c.canvas.drawing.strokes.count == 3)
        #expect(c.canvas.drawing.strokes.first.map(Marks.id) == Marks.id(under))
        #expect(c.canvas.drawing.strokes.last.map(Marks.id) == Marks.id(over))
        let replacements = parts.map { stroke in var s = stroke; s.ink.color = AgentPen.faded; return s }
        c.marks.apply(.init(add: replacements, remove: [Marks.id(original)]))
        #expect(c.canvas.drawing.strokes.count == 4, "AI changes keep every replacement fragment.")
        c.undo()
        #expect(c.canvas.drawing.strokes.count == 3)
        c.redo()
        c.saveNow()
        c = try open()
        #expect(c.canvas.drawing.strokes.count == 4)
    }

    @Test func navigationDefersAIInk() throws {
        let folder = URL.temporaryDirectory.appending(path: "maple-navigation-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = Page(url: folder, edited: .now), c = CanvasController(page: Page(url: folder, edited: .now))
        c.loadViewIfNeeded()
        c.setAIEnabled(true)
        c.view.bounds.size = CGSize(width: 1032, height: 1376)
        c.viewDidLayoutSubviews()
        defer {
            c.marks.stop()
            c.turner.isHidden = true
            c.saveTask?.cancel()
            Store.queue.sync {}
            UserDefaults.standard.removeObject(forKey: page.viewportKey)
            try? FileManager.default.removeItem(at: folder)
        }
        let pinch = PinchProbe(), rotation = RotationProbe()
        c.turner.addGestureRecognizer(rotation)
        pinch.phase = .began
        c.navigationChanged(pinch)
        let line = [CGPoint(x: 65500, y: 65500), CGPoint(x: 65600, y: 65500)]
        let stroke = AgentPen.stroke(line, width: 3, step: 2)
        let note = Note(mark: "question", trigger: [], anchor: line[0], zoom: 1, reading: "test", reply: "Answer",
                        turn: 0, rect: CGRect(x: 65500, y: 65490, width: 100, height: 20), inked: stroke.path.creationDate)
        c.marks.enqueue { .init(add: [stroke], notes: [note]) }
        c.marks.flush()
        #expect(c.canvas.drawing.strokes.isEmpty && c.marks.pending.count == 1, "AI cannot replace a drawing during a pinch.")
        c.canvas.zoomScale = 1.7
        c.rotation = 0.4
        c.turn()
        c.viewDidLayoutSubviews()
        #expect(c.canvas.zoomScale == 1.7 && c.rotation == 0.4)
        #expect(c.canvas.panGestureRecognizer.isEnabled && c.canvas.pinchGestureRecognizer?.isEnabled == true)
        rotation.phase = .changed
        c.navigationChanged(rotation)
        pinch.phase = .ended
        c.navigationChanged(pinch)
        #expect(c.marks.navigating, "Ending a pinch does not release an ongoing rotation.")
        c.marks.flush()
        #expect(c.canvas.drawing.strokes.isEmpty)
        rotation.phase = .cancelled
        c.navigationChanged(rotation)
        #expect(!c.marks.navigating)
        c.marks.flush()
        #expect(c.canvas.drawing.strokes.count == 1 && c.marks.pending.isEmpty)
        let written = try #require(c.marks.written.first)
        written.reveal([line], letters: 80)
        #expect(!written.isUserInteractionEnabled)
        pinch.phase = .began
        c.navigationChanged(pinch)
        #expect(c.marks.navigating && c.canvas.pinchGestureRecognizer?.isEnabled == true,
                "AI's writing reveal leaves pinch input enabled.")
        c.canvas.zoomScale = 2.1
        c.marks.layout()
        #expect(c.canvas.zoomScale == 2.1 && !written.isUserInteractionEnabled)
        pinch.phase = .ended
        c.navigationChanged(pinch)
    }
}

private final class PinchProbe: UIPinchGestureRecognizer {
    var phase = UIGestureRecognizer.State.possible
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
}

private final class RotationProbe: UIRotationGestureRecognizer {
    var phase = UIGestureRecognizer.State.possible
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
}
