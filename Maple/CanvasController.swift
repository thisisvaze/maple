import PencilKit
import SwiftUI
import UIKit.UIGestureRecognizerSubclass

/// Keep PencilKit's sharp live tiles when Navigation drives zoomScale itself.
final class InkCanvas: PKCanvasView {
    weak var navigation: Navigation?
    override var isZooming: Bool { super.isZooming || navigation?.moving == true }
}

/// One pair of fingers moves, scales and turns the page together, measured on the still screen. UIKit's separate
/// pinch and rotation recognizers can stop recognizing after their window turns (3 Nov, physical iPad).
final class Navigation: UIGestureRecognizer {
    // Calibration knobs, from v1's device log, where pinches wobbled up to about 12°.
    static let twistStart: CGFloat = .pi / 12  // 15°: the fingers turn this far before the page turns with them
    static let snap: CGFloat = .pi / 18  // 10°: a turn let go this close to a right angle squares the page
    weak var controller: CanvasController?
    /// Each finger, where it was last seen moving on the still screen. The page's window turns under the fingers, so a
    /// finger held still keeps that spot rather than being read again through a turn it didn't make.
    private var fingers: [(touch: UITouch, at: CGPoint)] = []
    private var start: (a: CGPoint, b: CGPoint, zoom: CGFloat, anchor: CGPoint)?
    private var angle: CGFloat = 0
    private var turned: CGFloat = 0  // how far this pair has turned, until the page turns with it
    private var twisting = false
    var moving: Bool { start != nil && (state == .began || state == .changed) }

    init(controller: CanvasController) {
        self.controller = controller
        super.init(target: nil, action: nil)
        allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let c = controller, c.loadError == nil else { state = .failed; return }
        fingers += touches.map { ($0, $0.location(in: c.view)) }
        guard fingers.count == 2 else {
            if fingers.count > 2 { end(cancelled: true) }
            return
        }
        let a = fingers[0].at, b = fingers[1].at
        guard hypot(b.x - a.x, b.y - a.y) > 0 else { return }
        let p = c.canvas.convert(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), from: c.view)
        start = (a, b, c.canvas.zoomScale, CGPoint(x: p.x / c.canvas.zoomScale, y: p.y / c.canvas.zoomScale))
        angle = atan2(b.y - a.y, b.x - a.x)
        (turned, twisting) = (0, false)
        c.marks.navigating = true
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let c = controller else { return }
        for i in fingers.indices where touches.contains(fingers[i].touch) { fingers[i].at = fingers[i].touch.location(in: c.view) }
        guard let start, fingers.count == 2 else { return }
        let a = fingers[0].at, b = fingers[1].at
        // Leave a tap's small tremor alone; the first movement carries its whole distance, with no jump at the threshold.
        guard state != .possible || max(hypot(a.x - start.a.x, a.y - start.a.y), hypot(b.x - start.b.x, b.y - start.b.y)) > 4 else { return }
        if state == .possible { state = .began; c.instantTiles(true) } else { state = .changed }
        let next = atan2(b.y - a.y, b.x - a.x), delta = (next - angle).remainder(dividingBy: 2 * .pi)
        angle = next
        // A pinch's wobble leaves the page straight; past twistStart the page turns with the fingers from where they are.
        if twisting { c.rotation = (c.rotation + delta).remainder(dividingBy: 2 * .pi) } else {
            turned += delta
            twisting = abs(turned) > Self.twistStart
        }
        c.turn()
        let zoom = start.zoom * hypot(b.x - a.x, b.y - a.y) / hypot(start.b.x - start.a.x, start.b.y - start.a.y)
        c.canvas.zoomScale = min(c.canvas.maximumZoomScale, max(c.canvas.minimumZoomScale, zoom))
        let p = c.canvas.convert(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), from: c.view)
        c.canvas.contentOffset.x += start.anchor.x * c.canvas.zoomScale - p.x
        c.canvas.contentOffset.y += start.anchor.y * c.canvas.zoomScale - p.y
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        fingers.removeAll { touches.contains($0.touch) }
        start = nil
        stopped()
        if fingers.isEmpty { end(cancelled: false) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { end(cancelled: true) }

    private func end(cancelled: Bool) {
        stopped()
        guard state == .began || state == .changed, let c = controller else { state = .failed; return }
        state = cancelled ? .cancelled : .ended
        let square = (c.rotation / (.pi / 2)).rounded() * .pi / 2
        if twisting, abs(c.rotation - square) < Self.snap {
            c.rotation = square
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25) { c.turn() }
        }
        c.save()
    }

    override func reset() {
        super.reset()
        stopped()
        fingers = []
        start = nil
    }

    /// The fingers stopped moving the page: Maple may write again, and PencilKit draws the zoom the page settled on. It
    /// does that only in a layout pass, which setting zoomScale never brings, so it dropped its live tiles a moment later
    /// and the ink stayed blank until the drawing next changed (3 Nov, simulator film).
    private func stopped() {
        controller?.marks.navigating = false
        controller?.canvas.setNeedsLayout()
    }
}

/// The page's own window, over the app's, which turns it and keeps the paper, the buttons and the alerts level. Only a whole
/// window hides a turn from PencilKit: a canvas turned on screen any other way, by around 45°, keeps only samples 10 screen
/// points apart and ink comes out as dots joined by curves, at 51° through a parent view, its own transform or a sublayer
/// transform alike, against 1.5 here (30 Oct, iPad probes, gaps measured from stored strokes).
final class Turner: UIWindow {
    static let pagesButton: CGFloat = 66  // the Pages button's corner: 16 of padding and 44 of button, and a little more
    weak var controller: CanvasController?

    override func sendEvent(_ event: UIEvent) {
        super.sendEvent(event)
        guard let controller, let sound = controller.pencilSound else { return }
        for touch in event.allTouches ?? [] where touch.type == .pencil {
            guard touch.view?.isDescendant(of: controller.canvas) == true else { continue }
            let samples = touch.phase == .moved ? event.coalescedTouches(for: touch) ?? [touch] : [touch]
            for sample in samples { sound.touch(sample, in: controller.view, material: controller.soundMaterial) }
        }
    }

    override var undoManager: UndoManager? { controller?.undoManager }  // a window would otherwise answer with its own

    /// Touches go through to what sits on the page in the app's window: an alert, its own buttons, the Pages corner and the
    /// page's name beside it, so Scribble can write there. Those go by position: SwiftUI's window doesn't answer a hit test
    /// the same way twice for one touch.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let controller, let page = controller.view, controller.presentedViewController == nil else { return nil }
        let spot = convert(point, to: page), safe = page.safeAreaInsets
        let corner = CGRect(x: 0, y: 0, width: safe.left + Self.pagesButton, height: safe.top + Self.pagesButton)
            .union(controller.titleFrame.insetBy(dx: -6, dy: -6))
        return page.hitTest(spot, with: event) === page && !corner.contains(spot) ? super.hitTest(point, with: event) : nil
    }
}

struct Paper: UIViewControllerRepresentable {
    let page: Page
    var voiceEnabled = false
    var aiEnabled = true
    var titleFrame = CGRect.zero  // the page's name on screen, which takes touches from the paper
    func makeUIViewController(context: Context) -> CanvasController { CanvasController(page: page) }
    func updateUIViewController(_ controller: CanvasController, context: Context) {
        controller.titleFrame = titleFrame
        controller.setAIEnabled(aiEnabled)
        controller.setVoiceEnabled(voiceEnabled)
    }
}

/// One page of paper: Apple Pencil writes, two fingers pan, pinch and rotate, two-finger tap undoes, three-finger tap redoes,
/// and double-tapping the Pencil goes from pen to eraser to the edit brush and back to the pen.
final class CanvasController: UIViewController, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    // Calibration knobs: tune by feel with a real Pencil.
    static let penWidth: CGFloat = 1.8  // fine handwriting
    static let eraserWidth: CGFloat = 41  // on screen; PencilKit clamps to 16.4–80.4 page points
    // On screen, for the edit brush's pen: heavier than penWidth, and handwriting with a 16 pt cap stays legible. PencilKit
    // holds a pen to 0.88–25.7 page points, so it keeps this width from zoom 0.12 to 3.4 (probed, 29 Oct).
    static let editWidth: CGFloat = 3
    static let straight: CGFloat = .pi / 180  // a page turned less than this counts as straight
    static let penPoint: CGFloat = 2.72  // the point size PencilKit stores for a pen of penWidth (30 Oct: 2.66 to 2.83 on the iPad)
    // ponytail: a fixed sheet stands in for an infinite one; recenter the ink if someone ever reaches an edge.
    static let sheet = Page.sheet

    let page: Page
    var titleFrame = CGRect.zero
    let canvas = InkCanvas()
    /// Turns the page; the canvas inside it stays upright. A PKCanvasView carrying a rotation itself drops ink tiles it
    /// still needs while zooming, so a turned page blinked blank mid-pinch (v1, 27 Oct sim film at 76°: 58 frames lost
    /// the ink with the canvas turned, 5 with a turner, 10 with the page straight).
    var turner = UIView()  // travels with the paper during transitions; a Turner takes over once the page is open
    let pen = PKInkingTool(.pen, color: .graphite, width: penWidth)
    let toolName = StatusLabel()  // names the tool for a moment after a double-tap
    var loadError: (any Error)?
    var dirty = false
    var laidOutSize = CGSize.zero  // the screen the page was last laid out for
    var rotation: CGFloat = 0
    var navigation: Navigation!
    var saveTask: Task<Void, Never>?
    var saveErrorShown = false
    let history = History()
    var strokeStart: PKDrawing?
    var quickShape: QuickShape!
    var quickMenu: QuickMenu!
    var marks: Marks!
    private(set) var voice: Voice?
    let controls = UIStackView()
    let aiButton = MapleButton(minimumWidth: 94)
    let toolDock = UIStackView()
    let toolButtons = (0..<3).map { _ in MapleButton() }
    var pencilSound: PencilSound!

    // The responder chain and finger taps share the page's persistent history.
    override var undoManager: UndoManager? { history }
    // Keep the system's three-finger editing menu from competing with redo.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    /// The pixel eraser rubs out only what it touches, eraserWidth wide on screen at any zoom.
    var eraser: PKEraserTool { PKEraserTool(.bitmap, width: Self.eraserWidth / canvas.zoomScale) }

    /// The edit brush, a deep-coral pen editWidth wide on screen: what it writes tells Maple what to change on the page.
    var brush: PKInkingTool { PKInkingTool(.pen, color: AgentPen.coral, width: Self.editWidth / canvas.zoomScale) }

    /// Whether the edit brush is in hand, told by its colour, as its marks are.
    var brushing: Bool { (canvas.tool as? PKInkingTool).map { AgentPen.edit(PKStroke(ink: $0.ink, path: PKStrokePath())) } ?? false }

    var soundMaterial: PencilSynth.Material { canvas.tool is PKEraserTool ? .eraser : brushing ? .edit : .pencil }

    init(page: Page) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .paper  // the paper sits behind a clear canvas, so things can later go between them
        view.clipsToBounds = true
        turner.backgroundColor = .clear  // the paper is in the app's window, under this one
        turner.isOpaque = false
        turner.addSubview(canvas)
        view.insertSubview(turner, at: 0)
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
            let archive = try page.loadArchive()
            var drawing = try archive?.current.drawing ?? page.load()
            let count = drawing.strokes.count
            drawing.strokes.removeAll(where: AgentPen.edit)
            dirty = drawing.strokes.count < count
            canvas.drawing = drawing
            notes = try archive?.current.notes ?? page.loadNotes()
            history.past = archive?.past ?? []
            history.future = archive?.future ?? []
        } catch {
            loadError = error  // never save over a file we couldn't read
            canvas.isUserInteractionEnabled = false
        }
        canvas.delegate = self  // after loading, so the load itself isn't an edit
        marks = Marks(canvas: canvas, page: page, notes: notes)
        marks.host = view
        marks.persist = { [weak self] in self?.changed() }
        marks.settled = { [weak self] in self?.finishStroke() }
        if let memory = marks.writeMemory() { marks.apply(memory) }
        history.prepare = { [weak self] in
            guard let self, !marks.penOn else { return false }
            finishStroke()
            return true
        }
        history.restore = { [weak self] step, backwards in
            guard let self else { return }
            let state = step.applying(to: History.State(drawing: canvas.drawing, notes: marks.notes), backwards: backwards)
            canvas.drawing = state.drawing
            marks.notes = state.notes
            marks.sync()
            changed()
        }

        let undoTap = UITapGestureRecognizer(target: self, action: #selector(undo))
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        let redoTap = UITapGestureRecognizer(target: self, action: #selector(redo))
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        undoTap.require(toFail: redoTap)
        canvas.addGestureRecognizer(undoTap)
        canvas.addGestureRecognizer(redoTap)
        canvas.panGestureRecognizer.isEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        navigation = Navigation(controller: self)
        canvas.navigation = navigation
        turner.addGestureRecognizer(navigation)
        undoTap.require(toFail: navigation)
        redoTap.require(toFail: navigation)
        quickShape = QuickShape(controller: self)
        canvas.addGestureRecognizer(quickShape)
        quickMenu = QuickMenu(controller: self)
        pencilSound = PencilSound()
        controls.spacing = 3
        controls.alignment = .center
        controls.isLayoutMarginsRelativeArrangement = true
        controls.layoutMargins = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        MapleStyle.surface(controls, radius: 19)
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        controls.addArrangedSubview(aiButton)
        marks.statusAnchor = controls
        NSLayoutConstraint.activate([
            controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            aiButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        aiButton.accessibilityIdentifier = "ai-toggle"
        aiButton.addAction(UIAction { [weak self] _ in self?.toggleAI() }, for: .primaryActionTriggered)
        setAIEnabled(Marks.aiEnabled)
        toolDock.spacing = 3
        toolDock.isLayoutMarginsRelativeArrangement = true
        toolDock.layoutMargins = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        toolDock.translatesAutoresizingMaskIntoConstraints = false
        MapleStyle.surface(toolDock, radius: 19)
        view.addSubview(toolDock)
        for (index, button) in toolButtons.enumerated() {
            toolDock.addArrangedSubview(button)
            button.addAction(UIAction { [weak self] _ in
                guard let self, !marks.penOn else { return }
                switch index {
                case 0: canvas.tool = pen; nameTool("Pen")
                case 1: canvas.tool = eraser; nameTool("Eraser")
                default: guard marks.enabled else { return }; canvas.tool = brush; nameTool("Edit")
                }
                updateTools()
            }, for: .primaryActionTriggered)
        }
        // Same buttons and margins as the Maple pill, so the same height; level with it, centered on the screen.
        NSLayoutConstraint.activate([
            toolDock.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            toolDock.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
        ])
        marks.statusClear = toolDock
        updateTools()
        view.addInteraction(UIPencilInteraction(delegate: self))  // in the key window: the Pencil's taps reach no other (30 Oct probe)
        toolName.alpha = 0
        toolName.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 18, weight: .semibold))
        toolName.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleBottomMargin]
        view.addSubview(toolName)  // a label takes no touches
        // Resign-active comes before the app switcher can kill us without a background notification.
        NotificationCenter.default.addObserver(self, selector: #selector(saveNow), name: UIApplication.willResignActiveNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // PencilKit can reenable these on joining a window; only Navigation moves the paper.
        if canvas.panGestureRecognizer.isEnabled { canvas.panGestureRecognizer.isEnabled = false }
        if canvas.pinchGestureRecognizer?.isEnabled == true { canvas.pinchGestureRecognizer?.isEnabled = false }
        // Only a new screen size moves the page: a label or button laid out mid-pinch, like Jev's tag, must not reset the zoom.
        guard view.bounds.width > 0, view.bounds.height > 0, view.bounds.size != laidOutSize else { return }
        if laidOutSize != .zero {
            laidOutSize = view.bounds.size
            show(center, zoom: canvas.zoomScale)
        } else {
            laidOutSize = view.bounds.size
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
        if !(turner is Turner), let scene = view.window?.windowScene {
            let window = Turner(windowScene: scene)
            window.controller = self
            window.windowLevel = .normal + 1
            moveCanvas(to: window)
            window.isHidden = false
        }
        if let loadError {
            let alert = UIAlertController(title: "Couldn't open this page", message: loadError.localizedDescription + " Your saved page is untouched.", preferredStyle: .alert)
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
        pencilSound.stop()
        voice?.cancel()
        marks.stop()
        saveNow()  // the gallery reads the file next, for the thumbnail
        if turner is Turner {
            let paper = UIView()
            view.insertSubview(paper, at: 0)
            moveCanvas(to: paper)
        }
    }

    /// Keep the real canvas on the paper while it zooms; only a settled page needs its own window for Pencil sampling.
    func moveCanvas(to surface: UIView) {
        let previous = turner
        surface.bounds = previous.bounds
        surface.center = previous.center
        surface.transform = previous.transform
        surface.backgroundColor = .clear
        surface.isOpaque = false
        surface.addSubview(canvas)
        for gesture in previous.gestureRecognizers ?? [] where gesture === navigation || gesture === quickMenu.swipe {
            surface.addGestureRecognizer(gesture)
        }
        turner = surface
        previous.isHidden = true
        previous.removeFromSuperview()
        canvas.panGestureRecognizer.isEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
    }

    func setVoiceEnabled(_ enabled: Bool) {
        loadViewIfNeeded()
        if enabled, loadError == nil {
            if voice == nil { voice = Voice(controller: self) }
            voice?.button.isEnabled = marks.enabled
        } else {
            voice?.cancel()
            voice?.button.removeFromSuperview()
            voice = nil
        }
    }

    func toggleAI() {
        let enabled = !marks.enabled
        UserDefaults.standard.set(enabled, forKey: "aiEnabled")
        setAIEnabled(enabled)
    }

    func setAIEnabled(_ enabled: Bool) {
        loadViewIfNeeded()
        marks.setEnabled(enabled)
        if !enabled {
            voice?.cancel()
            if brushing { canvas.tool = pen }
        }
        voice?.button.isEnabled = enabled
        aiButton.display(enabled ? "Maple on" : "Maple off", mark: enabled ? .orb : .symbol("pause.fill"), color: enabled ? MapleStyle.green : .secondaryLabel, filled: enabled)
        aiButton.accessibilityLabel = "Maple"
        aiButton.accessibilityValue = enabled ? "On" : "Off"
        aiButton.accessibilityHint = enabled ? "Turns off all AI actions and cancels pending requests." : "Turns on AI assistance."
        updateTools()
    }

    /// The page point in the middle of the screen; survives rotation and different screen sizes.
    var center: CGPoint {
        CGPoint(x: (canvas.contentOffset.x + canvas.bounds.width / 2) / canvas.zoomScale,
                y: (canvas.contentOffset.y + canvas.bounds.height / 2) / canvas.zoomScale)
    }

    /// The page is a square as wide as the screen's diagonal, centred on it, so it covers every corner at any angle and
    /// turning it never resizes it. Resizing a transformed view's frame would distort it.
    func show(_ center: CGPoint, zoom: CGFloat) {
        let side = hypot(view.bounds.width, view.bounds.height).rounded(.up)
        turner.bounds.size = CGSize(width: side, height: side)
        turner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        canvas.frame = turner.bounds
        turn()
        canvas.zoomScale = zoom
        canvas.contentOffset = CGPoint(x: center.x * canvas.zoomScale - canvas.bounds.width / 2,
                                       y: center.y * canvas.zoomScale - canvas.bounds.height / 2)
    }

    func turn() {
        Self.pencilShadow(abs(rotation) < Self.straight)
        turner.transform = CGAffineTransform(rotationAngle: rotation)
    }

    /// PencilKit's hover shadow can't see the page's turn, which is what Turner hides from it, so on a turned page it fell
    /// away from the Pencil (30 Oct, on the iPad). It's off there; the ink preview at the nib stays. The setting is private:
    /// found by name, and if it's ever missing, nothing changes.
    static func pencilShadow(_ on: Bool) {
        guard let kind = NSClassFromString("PKHoverSettings") as? NSObject.Type, kind.responds(to: NSSelectorFromString("sharedSettings")),
              let settings = kind.perform(NSSelectorFromString("sharedSettings"))?.takeUnretainedValue() as? NSObject,
              settings.responds(to: NSSelectorFromString("toolShadowActive")), settings.value(forKey: "toolShadowActive") as? Bool != on else { return }
        settings.setValue(on, forKey: "toolShadowActive")
    }

    @objc func undo() { history.undo(); updateTools() }
    @objc func redo() { history.redo(); updateTools() }

    func updateTools() {
        let active = canvas.tool is PKEraserTool ? 1 : brushing ? 2 : 0
        for (i, symbol) in ["pencil.tip", "eraser", "scribble.variable"].enumerated() {
            let selected = i == active
            toolButtons[i].display("", mark: .symbol(symbol), color: selected ? (i == 2 ? AgentPen.coral : Marks.ink) : .secondaryLabel, filled: selected)
            toolButtons[i].accessibilityLabel = ["Pen", "Eraser", "Edit brush"][i]
            toolButtons[i].accessibilityTraits = selected ? [.button, .selected] : .button
        }
        toolButtons[2].isEnabled = marks?.enabled == true
    }

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
        let (tool, name): (any PKTool, String) = if canvas.tool is PKEraserTool { marks.enabled ? (brush, "Edit") : (pen, "Pen") } else if brushing { (pen, "Pen") } else { (eraser, "Eraser") }
        canvas.tool = tool
        nameTool(name)
        updateTools()
    }

    func nameTool(_ name: String) {
        toolName.layer.removeAllAnimations()
        toolName.text = name
        toolName.textColor = brushing ? AgentPen.coral : .secondaryLabel
        toolName.sizeToFit()
        let safe = view.safeAreaLayoutGuide.layoutFrame
        toolName.frame.origin = CGPoint(x: (safe.midX - toolName.bounds.width / 2).rounded(), y: toolDock.frame.maxY + 8)  // under the tools
        toolName.alpha = 1
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.28, delay: 1) { self.toolName.alpha = 0 }
        UIAccessibility.post(notification: .announcement, argument: name)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        marks.layout()
        fitTool()
    }

    /// Keeps the eraser and the edit brush their width on screen at every zoom. Their widths are in page points, so one
    /// made zoomed out grows with the page zoomed in: an eraser could fill the screen. Fitted on every zoom change.
    func fitTool() {
        if let tool = canvas.tool as? PKEraserTool, abs(tool.width - eraser.width) > 0.25 { canvas.tool = eraser }
        else if brushing, let tool = canvas.tool as? PKInkingTool, abs(tool.width - brush.width) > 0.05 { canvas.tool = brush }
    }

    /// PencilKit drops old ink tiles when a pinch changes the zoom, then fades the re-rendered ones in from nothing over
    /// 0.25 s, so every pinch dimmed patches of ink and brought them back (v1, 27 Oct device probe). Its tiles live in a
    /// plain view inside its private attachment view: run that view's clock 1000× fast and the fade lands within a frame.
    /// Only from navigation until the pen comes down: at that speed the ink being written drew as dots joined by curves
    /// (29 Oct, on the iPad). Not the attachment view itself: a zoom bounce animates its bounds, which must keep pace with
    /// the page. Found by class name; if it's ever missing, nothing changes.
    func instantTiles(_ on: Bool) {
        func find(_ v: UIView) -> UIView? { "\(type(of: v))" == "PKCanvasAttachmentView" ? v : v.subviews.lazy.compactMap(find).first }
        find(canvas)?.subviews.filter { type(of: $0) == UIView.self }.forEach { $0.layer.speed = on ? 1000 : 1 }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        finishStroke()
        strokeStart = canvas.drawing
        instantTiles(false)  // the ink being written keeps PencilKit's own pace
        marks.penDown(editing: brushing)
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        marks.penUp(writing: canvas.tool is PKInkingTool, editing: brushing)  // erasing isn't a mark
    }

    /// The point size of the person's own ink, from their latest stroke, so a shape sits level with their writing.
    var inkPoint: CGFloat {
        guard let last = canvas.drawing.strokes.last(where: AgentPen.person), !last.path.isEmpty else { return Self.penPoint }
        return last.path[last.path.count / 2].size.width
    }

    /// Lays a snapped shape down as strokes of the person's own pen, in place of what PencilKit may have kept of the stroke,
    /// in the steps undo walks back through, like Procreate: the shape as it ends (a circle, a square), the shape as it
    /// snapped (an ellipse, a rectangle), then the stroke as `drawn`. Maple reads it like any mark: a box snapped square is
    /// still a box to fill.
    func place(_ shape: Shape, snapped: Shape, drawn: [CGPoint], drawnSince start: Date) {
        finishStroke()
        let zoom = canvas.zoomScale
        // Each has its own date, so undo tells them apart by id.
        func ink(_ line: [CGPoint], _ n: Double) -> PKStroke {
            PKStroke(ink: pen.ink, path: AgentPen.stroke(line, width: inkPoint, step: 2 / zoom, date: start + n / 1000).path)
        }
        let dropped = canvas.drawing.strokes.filter { AgentPen.person($0) && $0.path.creationDate >= start }.map(Marks.id)
        var last = drawn.count > 1 ? ink(drawn, 0) : nil
        if let last { marks.apply(Marks.Change(add: [last], remove: Set(dropped))) }
        for (n, form) in [snapped, shape].enumerated() where n == 0 || form != snapped {
            let next = ink(form.outline(spacing: 2 / zoom), Double(n + 1))
            marks.apply(Marks.Change(add: [next], remove: last.map { [Marks.id($0)] } ?? Set(dropped)))
            last = next
        }
        marks.penUp(writing: true)
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        marks.drawingChanged()
        changed()
    }

    /// PencilKit may deliver the final ink after pen-up; Marks calls this once that drawing has settled.
    func finishStroke() {
        guard let before = strokeStart else { return }
        strokeStart = nil
        history.record(from: History.State(drawing: before, notes: marks.notes),
                       to: History.State(drawing: canvas.drawing, notes: marks.notes))
        updateTools()
    }

    func changed() {
        dirty = true
        updateTools()
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
        let archive = History.Archive(current: History.State(drawing: canvas.drawing, notes: marks.notes), past: history.past, future: history.future)
        let url = page.stateFile
        Store.queue.async {
            do {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                try encoder.encode(archive.forSaving).write(to: url, options: .atomic)
            } catch {
                Task { @MainActor in
                    self.dirty = true
                    self.reportSaveFailure()
                }
            }
        }
    }

    @objc func saveNow() {
        pencilSound.stop()
        finishStroke()
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
