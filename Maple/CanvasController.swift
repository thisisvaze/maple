import PencilKit
import SwiftUI

struct Paper: UIViewControllerRepresentable {
    let page: Page
    func makeUIViewController(context: Context) -> CanvasController { CanvasController(page: page) }
    func updateUIViewController(_ controller: CanvasController, context: Context) {}
}

/// One page of paper: Apple Pencil writes, two fingers pan and pinch, two-finger tap undoes, three-finger tap redoes,
/// and double-tapping the Pencil swaps pen and eraser.
final class CanvasController: UIViewController, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    // Calibration knobs: tune by feel with a real Pencil.
    static let penWidth: CGFloat = 1.8  // fine handwriting
    static let eraserWidth: CGFloat = 41  // on screen; PencilKit clamps to 16.4–80.4 page points
    // ponytail: a fixed sheet stands in for an infinite one; recenter the ink if someone ever reaches an edge.
    static let sheet: CGFloat = 131_072

    let page: Page
    let canvas = PKCanvasView()
    let pen = PKInkingTool(.pen, color: .graphite, width: penWidth)
    var loadError: (any Error)?
    var dirty = false
    var laidOut = false
    var saveTask: Task<Void, Never>?
    var saveErrorShown = false
    let history = UndoManager()
    var marks: Marks!

    // PencilKit registers stroke undo with the responder chain's manager; own it so the finger taps can reach it.
    override var undoManager: UndoManager? { history }
    // Keep the system's three-finger editing menu from competing with redo.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    /// The pixel eraser rubs out only what it touches, eraserWidth wide on screen at any zoom.
    var eraser: PKEraserTool { PKEraserTool(.bitmap, width: Self.eraserWidth / canvas.zoomScale) }

    init(page: Page) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .paper  // the paper sits behind a clear canvas, so things can later go between them
        canvas.frame = view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(canvas)
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
            canvas.drawing = try page.load()
            notes = try page.loadNotes()
        } catch {
            loadError = error  // never save over a file we couldn't read
            canvas.isUserInteractionEnabled = false
        }
        canvas.delegate = self  // after loading, so the load itself isn't an edit
        marks = Marks(canvas: canvas, page: page, notes: notes)

        let undoTap = UITapGestureRecognizer(target: self, action: #selector(undo))
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        let redoTap = UITapGestureRecognizer(target: self, action: #selector(redo))
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        undoTap.require(toFail: redoTap)
        canvas.addGestureRecognizer(undoTap)
        canvas.addGestureRecognizer(redoTap)
        canvas.addInteraction(UIPencilInteraction(delegate: self))
        // Resign-active comes before the app switcher can kill us without a background notification.
        NotificationCenter.default.addObserver(self, selector: #selector(saveNow), name: UIApplication.willResignActiveNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // One finger or a palm never moves the paper. Set here: PencilKit resets it to 1 on joining a window.
        canvas.panGestureRecognizer.minimumNumberOfTouches = 2
        guard !laidOut, view.bounds.width > 0 else { return }
        laidOut = true
        let v = UserDefaults.standard.array(forKey: page.viewportKey) as? [Double] ?? []
        if v.count == 3 { show(CGPoint(x: v[0], y: v[1]), zoom: v[2]) } else { show(CGPoint(x: Self.sheet / 2, y: Self.sheet / 2), zoom: 1) }
        marks.layout()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
        marks.stop()
        saveNow()  // the gallery reads the file next, for the thumbnail
    }

    /// The page point in the middle of the screen; survives rotation and different screen sizes.
    var center: CGPoint {
        CGPoint(x: (canvas.contentOffset.x + canvas.bounds.width / 2) / canvas.zoomScale,
                y: (canvas.contentOffset.y + canvas.bounds.height / 2) / canvas.zoomScale)
    }

    func show(_ center: CGPoint, zoom: CGFloat) {
        canvas.zoomScale = zoom
        canvas.contentOffset = CGPoint(x: center.x * zoom - canvas.bounds.width / 2, y: center.y * zoom - canvas.bounds.height / 2)
    }

    @objc func undo() { if history.canUndo { history.undo() } }
    @objc func redo() { if history.canRedo { history.redo() } }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        canvas.tool = canvas.tool is PKEraserTool ? pen : eraser
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if canvas.tool is PKEraserTool { canvas.tool = eraser }  // keep its on-screen width
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { marks.layout() }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { marks.penDown() }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        if canvas.tool is PKInkingTool { marks.penUp() }  // erasing isn't a mark
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        dirty = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))  // write once the pen pauses
            if !Task.isCancelled { save() }
        }
    }

    func save() {
        UserDefaults.standard.set([center.x, center.y, canvas.zoomScale], forKey: page.viewportKey)
        guard dirty, loadError == nil else { return }
        dirty = false
        let drawing = canvas.drawing, url = page.ink  // copied here, encoded off the main thread
        Store.queue.async {
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
