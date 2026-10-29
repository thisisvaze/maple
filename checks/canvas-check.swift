// Run on a booted iPad simulator, without model keys:
//   CHECK_DIR=$(mktemp -d); mkdir "$CHECK_DIR/Check.app"
//   sed -n '1p;/^extension UIColor/,$p' Maple/MapleApp.swift > "$CHECK_DIR/Colors.swift"
//   xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios26.0-simulator -swift-version 6 \
//     -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault -parse-as-library \
//     Maple/{CanvasController,Marks,Bubble,Note,Page,Grouping,Agent,Muse,Drawing,Hershey,AgentPen,Jev,Thinking}.swift \
//     "$CHECK_DIR/Colors.swift" checks/canvas-check.swift -o "$CHECK_DIR/Check.app/canvas-check"
//   plutil -create xml1 "$CHECK_DIR/Check.app/Info.plist"
//   plutil -insert CFBundleIdentifier -string dev.maple.canvas-check "$CHECK_DIR/Check.app/Info.plist"
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
        controller.marks.apply(.init(add: [AgentPen.stroke([anchor, CGPoint(x: 2100, y: 3000)], width: 3, step: 2)], notes: [note]))
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
        print("canvas ok: rotation pivot, coverage, overlays, old/new viewport, resize, undo/redo, agent ink after reload, undo by id, writing while the pen rests, reading frame")
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

final class Rotation: UIRotationGestureRecognizer {
    var phase: UIGestureRecognizer.State = .changed
    var pivot = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { pivot }
}
