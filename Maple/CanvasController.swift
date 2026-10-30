import PencilKit
import SwiftUI

struct Paper: UIViewControllerRepresentable {
    let page: Page
    var voiceEnabled = false
    func makeUIViewController(context: Context) -> CanvasController { CanvasController(page: page) }
    func updateUIViewController(_ controller: CanvasController, context: Context) { controller.setVoiceEnabled(voiceEnabled) }
}

/// One page of paper: Apple Pencil writes, two fingers pan, pinch and rotate, two-finger tap undoes, three-finger tap redoes,
/// and double-tapping the Pencil goes from pen to eraser to the edit brush and back to the pen.
final class CanvasController: UIViewController, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
    // Calibration knobs: tune by feel with a real Pencil.
    static let penWidth: CGFloat = 1.8  // fine handwriting
    static let eraserWidth: CGFloat = 41  // on screen; PencilKit clamps to 16.4–80.4 page points
    // On screen, for the edit brush's pen: heavier than penWidth, and handwriting with a 16 pt cap stays legible. PencilKit
    // holds a pen to 0.88–25.7 page points, so it keeps this width from zoom 0.12 to 3.4 (probed, 29 Oct).
    static let editWidth: CGFloat = 3
    // ponytail: a fixed sheet stands in for an infinite one; recenter the ink if someone ever reaches an edge.
    static let sheet: CGFloat = 131_072

    let page: Page
    let canvas = PKCanvasView()
    /// Turns the page; the canvas inside it stays upright. A PKCanvasView carrying a rotation itself drops ink tiles it
    /// still needs while zooming, so a turned page blinked blank mid-pinch (v1, 27 Oct sim film at 76°: 58 frames lost
    /// the ink with the canvas turned, 5 with a turner, 10 with the page straight).
    let turner = UIView()
    let pen = PKInkingTool(.pen, color: .graphite, width: penWidth)
    let toolName = UILabel()  // names the tool for a moment after a double-tap
    var loadError: (any Error)?
    var dirty = false
    var laidOut = false
    var rotation: CGFloat = 0
    var saveTask: Task<Void, Never>?
    var saveErrorShown = false
    let history = UndoManager()
    var marks: Marks!
    private(set) var voice: Voice?

    // PencilKit registers stroke undo with the responder chain's manager; own it so the finger taps can reach it.
    override var undoManager: UndoManager? { history }
    // Keep the system's three-finger editing menu from competing with redo.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    /// The pixel eraser rubs out only what it touches, eraserWidth wide on screen at any zoom.
    var eraser: PKEraserTool { PKEraserTool(.bitmap, width: Self.eraserWidth / canvas.zoomScale) }

    /// The edit brush, a deep-coral pen editWidth wide on screen: what it writes tells Maple what to change on the page.
    var brush: PKInkingTool { PKInkingTool(.pen, color: AgentPen.coral, width: Self.editWidth / canvas.zoomScale) }

    /// Whether the edit brush is in hand, told by its colour, as its marks are.
    var brushing: Bool { (canvas.tool as? PKInkingTool).map { AgentPen.edit(PKStroke(ink: $0.ink, path: PKStrokePath())) } ?? false }

    init(page: Page) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .paper  // the paper sits behind a clear canvas, so things can later go between them
        view.clipsToBounds = true
        turner.frame = view.bounds
        view.addSubview(turner)
        canvas.frame = turner.bounds
        turner.addSubview(canvas)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        canvas.drawingPolicy = .pencilOnly
        canvas.tool = pen
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.scrollsToTop = false  // a status-bar tap would fly to the sheet's top edge, far from any ink
        [canvas.topEdgeEffect, canvas.leftEdgeEffect, canvas.bottomEdgeEffect, canvas.rightEdgeEffect].forEach { $0.isHidden = true }
        canvas.showsHorizontalScrollIndicator = false
        canvas.showsVerticalScrollIndicator = false
        canvas.minimumZoomScale = 0.1
        canvas.maximumZoomScale = 6
        canvas.contentSize = CGSize(width: Self.sheet, height: Self.sheet)
        var notes: [Note] = []
        do {
            // Edit marks are instructions, never writing: any left when the page closed go now, and from its file at the next save.
            var drawing = try page.load()
            let count = drawing.strokes.count
            drawing.strokes.removeAll(where: AgentPen.edit)
            dirty = drawing.strokes.count < count
            canvas.drawing = drawing
            notes = try page.loadNotes()
        } catch {
            loadError = error  // never save over a file we couldn't read
            canvas.isUserInteractionEnabled = false
        }
        canvas.delegate = self  // after loading, so the load itself isn't an edit
        marks = Marks(canvas: canvas, page: page, notes: notes)
        marks.host = view

        let undoTap = UITapGestureRecognizer(target: self, action: #selector(undo))
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        let redoTap = UITapGestureRecognizer(target: self, action: #selector(redo))
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        undoTap.require(toFail: redoTap)
        canvas.addGestureRecognizer(undoTap)
        canvas.addGestureRecognizer(redoTap)
        let twist = UIRotationGestureRecognizer(target: self, action: #selector(rotate))
        twist.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        twist.delegate = self
        view.addGestureRecognizer(twist)  // its coordinate space stays still while the canvas turns
        canvas.addInteraction(UIPencilInteraction(delegate: self))
        toolName.font = .preferredFont(forTextStyle: .headline)
        toolName.adjustsFontForContentSizeCategory = true
        toolName.alpha = 0
        toolName.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleBottomMargin]
        view.addSubview(toolName)  // a label takes no touches
        // Resign-active comes before the app switcher can kill us without a background notification.
        NotificationCenter.default.addObserver(self, selector: #selector(saveNow), name: UIApplication.willResignActiveNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // One finger or a palm never moves the paper. Set here: PencilKit resets it to 1 on joining a window.
        canvas.panGestureRecognizer.minimumNumberOfTouches = 2
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        if laidOut {
            show(center, zoom: canvas.zoomScale)
        } else {
            laidOut = true
            let v = UserDefaults.standard.array(forKey: page.viewportKey) as? [Double] ?? []
            if (v.count == 3 || v.count == 4), v.allSatisfy(\.isFinite), v[2] > 0 {
                rotation = v.count == 4 ? v[3] : 0
                show(CGPoint(x: v[0], y: v[1]), zoom: v[2])
            } else {
                show(CGPoint(x: Self.sheet / 2, y: Self.sheet / 2), zoom: 1)
            }
        }
        marks.layout()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        instantTiles()
        if let loadError {
            let alert = UIAlertController(title: "Couldn't open this page", message: loadError.localizedDescription + " The saved file has been left untouched.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
        // PencilKit's tap menu (Select All, Insert Space) has no public off switch; without its edit-menu interaction it can't show.
        func strip(_ view: UIView) {
            view.interactions.filter { $0 is UIEditMenuInteraction }.forEach(view.removeInteraction)
            view.subviews.forEach(strip)
        }
        strip(canvas)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        voice?.cancel()
        marks.stop()
        saveNow()  // the gallery reads the file next, for the thumbnail
    }

    func setVoiceEnabled(_ enabled: Bool) {
        loadViewIfNeeded()
        if enabled, loadError == nil {
            if voice == nil { voice = Voice(controller: self) }
        } else {
            voice?.cancel()
            voice?.button.removeFromSuperview()
            voice = nil
        }
    }

    /// The page point in the middle of the screen; survives rotation and different screen sizes.
    var center: CGPoint {
        CGPoint(x: (canvas.contentOffset.x + canvas.bounds.width / 2) / canvas.zoomScale,
                y: (canvas.contentOffset.y + canvas.bounds.height / 2) / canvas.zoomScale)
    }

    func show(_ center: CGPoint, zoom: CGFloat) {
        let turn = CGAffineTransform(rotationAngle: rotation)
        // Cover every screen corner at any angle; resizing a transformed view's frame would distort it.
        turner.bounds.size = view.bounds.applying(turn.inverted()).size
        turner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        turner.transform = turn
        canvas.frame = turner.bounds
        canvas.zoomScale = zoom
        canvas.contentOffset = CGPoint(x: center.x * canvas.zoomScale - canvas.bounds.width / 2,
                                       y: center.y * canvas.zoomScale - canvas.bounds.height / 2)
    }

    @objc func rotate(_ gesture: UIRotationGestureRecognizer) {
        guard loadError == nil else { return }
        switch gesture.state {
        case .began, .changed:
            let pivot = gesture.location(in: view), before = canvas.convert(pivot, from: view)
            rotation = (rotation + gesture.rotation).remainder(dividingBy: 2 * .pi)
            gesture.rotation = 0
            show(center, zoom: canvas.zoomScale)
            let after = canvas.convert(pivot, from: view)
            canvas.contentOffset.x += before.x - after.x
            canvas.contentOffset.y += before.y - after.y
        case .ended, .cancelled: save()
        default: break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other === canvas.panGestureRecognizer || other === canvas.pinchGestureRecognizer
    }

    @objc func undo() { if history.canUndo { history.undo() } }
    @objc func redo() { if history.canRedo { history.redo() } }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        cycle()
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard UIPencilInteraction.preferredSqueezeAction != .ignore else {
            voice?.squeeze(.cancelled)
            return
        }
        voice?.squeeze(squeeze.phase)
    }

    /// Pen, then eraser, then the edit brush, then the pen again, named at the top of the screen for a moment.
    func cycle() {
        let (tool, name): (any PKTool, String) = if canvas.tool is PKEraserTool { (brush, "Edit") } else if brushing { (pen, "Pen") } else { (eraser, "Eraser") }
        canvas.tool = tool
        toolName.layer.removeAllAnimations()
        toolName.text = name
        toolName.textColor = brushing ? AgentPen.coral : .secondaryLabel
        toolName.sizeToFit()
        let safe = view.safeAreaLayoutGuide.layoutFrame
        toolName.frame.origin = CGPoint(x: (safe.midX - toolName.bounds.width / 2).rounded(), y: safe.minY + 12)
        toolName.alpha = 1
        UIView.animate(withDuration: 0.3, delay: 1) { self.toolName.alpha = 0 }
        UIAccessibility.post(notification: .announcement, argument: name)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        marks.layout()
        fitTool()
    }

    /// Keeps the eraser and the edit brush their width on screen at every zoom. Their widths are in page points, so one
    /// made zoomed out grows with the page zoomed in: an eraser could fill the screen. Fitted on every zoom change, not
    /// just when a pinch ends, since a twist sets the zoom mid-pinch and that end can be skipped.
    func fitTool() {
        if let tool = canvas.tool as? PKEraserTool, abs(tool.width - eraser.width) > 0.25 { canvas.tool = eraser }
        else if brushing, let tool = canvas.tool as? PKInkingTool, abs(tool.width - brush.width) > 0.05 { canvas.tool = brush }
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { instantTiles() }  // PencilKit may have made a new one

    /// PencilKit drops old ink tiles when a pinch changes the zoom, then fades the re-rendered ones in from nothing over
    /// 0.25 s, so every pinch dimmed patches of ink and brought them back (v1, 27 Oct device probe). Its tiles live in a
    /// plain view inside its private attachment view: run that view's clock 1000× fast and the fade lands within a frame.
    /// Not the attachment view itself: a zoom bounce animates its bounds, which must keep pace with the page. Found by
    /// class name; if it's ever missing, nothing changes.
    func instantTiles() {
        func find(_ v: UIView) -> UIView? { "\(type(of: v))" == "PKCanvasAttachmentView" ? v : v.subviews.lazy.compactMap(find).first }
        find(canvas)?.subviews.filter { type(of: $0) == UIView.self }.forEach { $0.layer.speed = 1000 }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { marks.penDown(editing: brushing) }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        marks.penUp(writing: canvas.tool is PKInkingTool, editing: brushing)  // erasing isn't a mark
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        marks.drawingChanged()
        dirty = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))  // write once the pen pauses
            if !Task.isCancelled { save() }
        }
    }

    func save() {
        UserDefaults.standard.set([center.x, center.y, canvas.zoomScale, rotation], forKey: page.viewportKey)
        guard dirty, loadError == nil else { return }
        dirty = false
        var drawing = canvas.drawing  // copied here, encoded off the main thread
        drawing.strokes.removeAll(where: AgentPen.edit)  // edit marks are instructions, never kept
        let url = page.ink
        Store.queue.async { [drawing] in
            do {
                try drawing.dataRepresentation().write(to: url, options: .atomic)
            } catch {
                Task { @MainActor in
                    self.dirty = true
                    self.reportSaveFailure()
                }
            }
        }
    }

    @objc func saveNow() {
        marks.flush()  // what Maple was waiting to write goes in now
        saveTask?.cancel()
        save()
        Store.queue.sync {}
    }

    func reportSaveFailure() {
        guard !saveErrorShown, view.window != nil, presentedViewController == nil else { return }
        saveErrorShown = true
        let alert = UIAlertController(title: "Couldn't save this page", message: "Your latest changes are still on screen. Keep this page open and try again.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { _ in
            self.saveErrorShown = false
            self.saveNow()
        })
        alert.addAction(UIAlertAction(title: "Keep editing", style: .cancel) { _ in self.saveErrorShown = false })
        present(alert, animated: true)
    }
}
