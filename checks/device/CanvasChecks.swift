import PencilKit
import Testing
@testable import Maple

extension DeviceChecks {
    @Test func canvasTravelsWithPaper() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let folder = URL.temporaryDirectory.appending(path: "maple-transition-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = Page(url: folder, edited: .now), c = CanvasController(page: Page(url: folder, edited: .now))
        let host = UIWindow(windowScene: scene)
        host.addSubview(c.view)
        c.view.frame = host.bounds
        c.viewDidLayoutSubviews()
        c.setAIEnabled(false)
        defer {
            c.marks.stop()
            c.saveTask?.cancel()
            c.turner.isHidden = true
            host.isHidden = true
            Store.queue.sync {}
            UserDefaults.standard.removeObject(forKey: page.viewportKey)
            try? FileManager.default.removeItem(at: folder)
        }
        c.rotation = 0.37
        c.show(c.center, zoom: 1.6)
        let stroke = AgentPen.stroke([CGPoint(x: 65500, y: 65500), CGPoint(x: 65600, y: 65500)], width: 3, step: 2)
        c.canvas.drawing = PKDrawing(strokes: [stroke])
        let ink = c.canvas.drawing.dataRepresentation(), center = c.center, transform = c.turner.transform
        let gestures = c.turner.gestureRecognizers ?? []
        c.viewIsAppearing(true)
        #expect(!(c.turner is UIWindow) && c.canvas.isDescendant(of: c.view), "Ink must travel inside the paper during its opening animation.")
        c.viewDidAppear(true)
        let opened = try #require(c.turner as? Turner)
        #expect(opened.windowScene === scene && !opened.isHidden && c.canvas.superview === opened)
        #expect(c.turner.transform == transform && c.center == center && c.canvas.zoomScale == 1.6)
        #expect(c.canvas.transform == .identity && c.canvas.drawing.dataRepresentation() == ink)
        #expect(gestures.allSatisfy { $0.view === opened }, "Navigation stays with the calibrated window.")
        c.viewWillDisappear(true)
        #expect(opened.isHidden && !(c.turner is UIWindow) && c.canvas.isDescendant(of: c.view), "Ink must return to the paper before its closing animation.")
        #expect(c.turner.transform == transform && c.center == center && c.canvas.zoomScale == 1.6)
        #expect(c.canvas.drawing.dataRepresentation() == ink && gestures.allSatisfy { $0.view === c.turner })
        #expect(c.navigation.view === c.turner && c.navigation.isEnabled)
        #expect(!c.canvas.panGestureRecognizer.isEnabled && c.canvas.pinchGestureRecognizer?.isEnabled == false)
    }

    @Test func queuedFrameReleasesOwner() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 820, height: 1180)), canvas = PKCanvasView()
        canvas.frame = host.bounds
        host.addSubview(canvas)
        host.layoutIfNeeded()
        let page = Page(url: URL.temporaryDirectory.appending(path: UUID().uuidString), edited: .now)
        var owner: Marks? = Marks(canvas: canvas, page: page, notes: [])
        owner?.host = host
        owner?.agent = Agent(muse: Muse(key: "offline"))
        owner?.setEnabled(true)
        owner?.penDown()
        _ = try #require(owner?.frame(.init(request: "A triangle", width: 200, height: 150), near: CGPoint(x: 200, y: 300), avoid: []))
        #expect(owner?.pending.count == 1)
        weak let queued = owner
        owner = nil
        #expect(queued == nil, "A queued drawing must not retain its owner while the pen is held down.")
    }

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
        let navigation = c.navigation!, event = UIEvent()
        let fingers = [FingerProbe(CGPoint(x: 300, y: 500)), FingerProbe(CGPoint(x: 500, y: 500))]
        let touches = Set<UITouch>(fingers)
        navigation.touchesBegan([fingers[0]], with: event)
        fingers[0].point.x += 20
        navigation.touchesMoved([fingers[0]], with: event)
        #expect(c.canvas.zoomScale == 1 && c.rotation == 0 && !c.marks.navigating, "One finger never moves the page.")
        fingers[0].point.x -= 20
        navigation.touchesBegan([fingers[1]], with: event)
        let line = [CGPoint(x: 65500, y: 65500), CGPoint(x: 65600, y: 65500)]
        let stroke = AgentPen.stroke(line, width: 3, step: 2)
        let note = Note(mark: "question", trigger: [], anchor: line[0], zoom: 1, reading: "test", reply: "Answer",
                        turn: 0, rect: CGRect(x: 65500, y: 65490, width: 100, height: 20), inked: stroke.path.creationDate)
        c.marks.enqueue { .init(add: [stroke], notes: [note]) }
        c.marks.flush()
        #expect(c.canvas.drawing.strokes.isEmpty && c.marks.pending.count == 1, "AI cannot replace a drawing during a pinch.")
        for (i, finger) in fingers.enumerated() {
            let side: CGFloat = i == 0 ? -1 : 1
            finger.point = CGPoint(x: 400 + side * 170 * cos(0.4), y: 500 + side * 170 * sin(0.4))
        }
        navigation.touchesMoved(touches, with: event)
        c.viewDidLayoutSubviews()
        #expect(abs(c.canvas.zoomScale - 1.7) < 0.001 && c.rotation == 0, "The page turns only once the fingers pass twistStart.")
        #expect(navigation.isEnabled && c.marks.navigating && c.canvas.isZooming, "PencilKit must use live zoom rendering during the gesture.")
        c.marks.flush()
        #expect(c.canvas.drawing.strokes.isEmpty)
        navigation.touchesBegan([FingerProbe(CGPoint(x: 600, y: 500))], with: event)
        #expect(!c.marks.navigating && !c.canvas.isZooming, "A third finger cancels navigation and live zoom rendering for the quick menu.")
        c.marks.flush()
        #expect(c.canvas.drawing.strokes.count == 1 && c.marks.pending.isEmpty)
        let written = try #require(c.marks.written.first)
        written.reveal([stroke], along: [line], letters: 80)
        #expect(!written.isUserInteractionEnabled)
        navigation.isEnabled = false
        navigation.isEnabled = true
        navigation.reset()  // direct touch probes don't drive UIKit's reset between gestures
        navigation.touchesBegan(touches, with: event)
        #expect(c.marks.navigating && navigation.isEnabled,
                "AI's writing reveal leaves pinch input enabled.")
        c.canvas.zoomScale = 2.1
        c.marks.layout()
        #expect(c.canvas.zoomScale == 2.1 && !written.isUserInteractionEnabled)
        navigation.touchesEnded([fingers[0]], with: event)
        #expect(!c.marks.navigating && !c.canvas.isZooming)
        let replacement = FingerProbe(CGPoint(x: 300, y: 500)), zoom = c.canvas.zoomScale
        navigation.touchesBegan([replacement], with: event)
        replacement.point.x -= 50
        navigation.touchesMoved([replacement], with: event)
        #expect(c.marks.navigating && abs(c.canvas.zoomScale - zoom) > 0.01, "Replacing a finger starts moving again without lifting both.")
        navigation.touchesCancelled([fingers[1], replacement], with: event)
        #expect(!c.marks.navigating && !c.canvas.isZooming, "An interruption releases queued AI ink and ends live zoom rendering.")
    }
}

private final class FingerProbe: UITouch {
    var point: CGPoint
    init(_ point: CGPoint) { self.point = point; super.init() }
    override func location(in view: UIView?) -> CGPoint { point }
    override var type: UITouch.TouchType { .direct }
    override var majorRadius: CGFloat { 12 }
}
