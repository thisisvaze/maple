import PencilKit
import UIKit.UIGestureRecognizerSubclass

/// Procreate's QuickShape. Draw, and rest the pen where the stroke ends: after a moment it snaps into the line, arc, polyline,
/// ellipse, triangle or quadrilateral it was meant to be. Still holding, the pen turns and scales it, and a finger down
/// anywhere makes it regular, in fifteen-degree steps: a straight line at set angles, a circle, a square. Lifting the pen
/// leaves it as ink. This watches every touch and takes none, so PencilKit draws as usual until the snap.
final class QuickShape: UIGestureRecognizer, UIGestureRecognizerDelegate {
    // Calibration knobs: tune with a real Pencil.
    static let hold: Duration = .milliseconds(450)  // how long the pen rests before the stroke snaps; Procreate's "a moment"
    static let still: CGFloat = 4  // screen points the pen may drift and still be resting
    static let deadZone: CGFloat = 8  // screen points the pen moves from the snap before it drags the shape, so a hand's tremor can't tilt it
    static let smallest: CGFloat = 24  // screen points across for a stroke to be a shape: smaller is writing
    static let fingertip: CGFloat = 32  // screen points of contact radius; more is a resting palm, which doesn't count
    static let penType = UITouch.TouchType.pencil

    weak var controller: CanvasController?
    var pen: UITouch?
    var fingers: Set<UITouch> = []
    var points: [CGPoint] = []  // the stroke so far, in page points
    var started = Date()
    var resting: Task<Void, Never>?
    var rest = CGPoint.zero  // where the pen came to rest, in page points
    var snapped: (shape: Shape, hold: CGPoint)?
    var shape: Shape?  // as it stands, once snapped
    var dragging = false
    let preview = CAShapeLayer()
    lazy var feedback = controller.map { UICanvasFeedbackGenerator(view: $0.canvas) }

    init(controller: CanvasController) {
        self.controller = controller
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        requiresExclusiveTouchType = false  // a finger counts while the Pencil is down
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
        preview.fillColor = nil
        preview.lineCap = .round
        preview.lineJoin = .round
        preview.zPosition = 10
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }

    func page(_ touch: UITouch) -> CGPoint {
        guard let canvas = controller?.canvas else { return .zero }
        let p = touch.location(in: canvas)
        return CGPoint(x: p.x / canvas.zoomScale, y: p.y / canvas.zoomScale)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            if touch.type == Self.penType {
                guard pen == nil, let controller, controller.canvas.tool is PKInkingTool, !controller.brushing, controller.loadError == nil else { continue }
                pen = touch
                start(page(touch))
            } else if touch.majorRadius <= Self.fingertip {
                fingers.insert(touch)
                fingerChanged()
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let pen, touches.contains(pen) else { return }
        move((event.coalescedTouches(for: pen) ?? [pen]).map(page))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let pen, touches.contains(pen) { lift() }
        lifted(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let pen, touches.contains(pen) { clear() }
        lifted(touches)
    }

    func lifted(_ touches: Set<UITouch>) {
        fingers.subtract(touches)
        fingerChanged()
        if pen == nil, fingers.isEmpty { state = .failed }
    }

    override func reset() {
        super.reset()
        fingers.removeAll()
        if pen != nil { clear() }
    }

    /// The pen touched down at `point`.
    func start(_ point: CGPoint) {
        points = [point]
        started = Date()
        restAt(point)
    }

    /// The pen moved on through `moved`: more stroke, or once snapped, a drag of the shape.
    func move(_ moved: [CGPoint]) {
        guard let last = moved.last, let canvas = controller?.canvas else { return }
        if snapped != nil { return update(to: last) }
        points += moved
        if Shape.distance(last, rest) * canvas.zoomScale > Self.still { restAt(last) }
    }

    func restAt(_ point: CGPoint) {
        rest = point
        resting?.cancel()
        resting = Task { [weak self] in
            try? await Task.sleep(for: Self.hold)
            if !Task.isCancelled { self?.rested() }
        }
    }

    /// The pen has rested: if the stroke clearly is a shape, it stops being a stroke.
    func rested() {
        guard let controller, snapped == nil, points.count > 1 else { return }
        let canvas = controller.canvas, size = Shape.box(points)
        guard hypot(size.width, size.height) * canvas.zoomScale >= Self.smallest, let found = Shape.recognize(points, level: controller.marks.turn) else { return }
        // A disabled recognizer cancels the stroke under way, and the pen's touch stays with this one.
        canvas.drawingGestureRecognizer.isEnabled = false
        canvas.drawingGestureRecognizer.isEnabled = true
        controller.navigation.isEnabled = false  // a second finger constrains the shape, it doesn't move the page
        snapped = (found, rest)
        shape = found
        dragging = false
        canvas.layer.addSublayer(preview)
        draw()
        feedback?.alignmentOccurred(at: CGPoint(x: rest.x * canvas.zoomScale, y: rest.y * canvas.zoomScale))
    }

    func fingerChanged() {
        guard snapped != nil, let last = lastPen else { return }
        update(to: last)
        guard let canvas = controller?.canvas else { return }
        feedback?.alignmentOccurred(at: CGPoint(x: last.x * canvas.zoomScale, y: last.y * canvas.zoomScale))
    }

    var penAt: CGPoint?  // where the pen is, once snapped
    var lastPen: CGPoint? { penAt ?? snapped?.hold }
    var regular: Bool { !fingers.isEmpty }

    /// The shape as the pen at `point` and any finger have it now.
    func update(to point: CGPoint) {
        guard let snapped, let controller else { return }
        penAt = point
        if Shape.distance(point, snapped.hold) * controller.canvas.zoomScale > Self.deadZone { dragging = true }
        shape = dragging || regular ? snapped.shape.dragged(from: snapped.hold, to: dragging ? point : snapped.hold, regular: regular, level: controller.marks.turn) : snapped.shape
        draw()
    }

    func draw() {
        guard let shape, let canvas = controller?.canvas else { return }
        let zoom = canvas.zoomScale, path = CGMutablePath()
        path.addLines(between: shape.outline(spacing: 2 / zoom).map { CGPoint(x: $0.x * zoom, y: $0.y * zoom) })
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.path = path
        preview.lineWidth = 2 * ((controller?.inkPoint ?? CanvasController.penPoint) - 2) * zoom  // how thick a stroke of that size draws
        preview.strokeColor = PKInkingTool.convertColor(.graphite, from: .light, to: canvas.traitCollection.userInterfaceStyle).cgColor
        CATransaction.commit()
    }

    /// The pen left the paper: a shape lands as ink, and a stroke was PencilKit's all along.
    func lift() {
        let landed = shape, base = snapped?.shape, drawn = points, began = started
        clear()
        if let landed, let base { controller?.place(landed, snapped: base, drawn: drawn, drawnSince: began) }
    }

    func clear() {
        resting?.cancel()
        pen = nil
        snapped = nil
        shape = nil
        penAt = nil
        points = []
        preview.removeFromSuperlayer()
        controller?.navigation.isEnabled = true
    }
}
