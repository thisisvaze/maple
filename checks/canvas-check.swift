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
    static func main() throws {
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
        let drawing = PKDrawing(strokes: [AgentPen.stroke([anchor, CGPoint(x: 2100, y: 3000)], width: 3, step: 2)])
        controller.marks.place(drawing, note: note, replacing: PKDrawing())
        let bubble = controller.marks.add(Bubble(anchor: anchor, zoom: 1.5, note: note))
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
        controller.undo()
        precondition(canvas.drawing.strokes.isEmpty, "rotation doesn't consume the drawing's undo")
        controller.redo()
        precondition(canvas.drawing.strokes.count == 1, "redo still restores ink")
        controller.saveNow()
        print("canvas ok: rotation pivot, coverage, overlays, old/new viewport, resize, undo/redo")
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
