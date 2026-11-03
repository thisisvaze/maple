import UIKit
import UniformTypeIdentifiers

/// Procreate's Copy & Paste menu: swipe three fingers down the page, and a floating menu offers to copy the page for an AI,
/// as JSON with all Maple knows, or as SVG. Tapping anywhere else closes it.
final class QuickMenu: NSObject, UIGestureRecognizerDelegate {
    static let reach: CGFloat = 70  // calibration knob: screen points three fingers travel down to call the menu

    weak var controller: CanvasController?
    let swipe = Swipe()
    let shade = UIControl()  // takes the tap that closes the menu
    let panel = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    var held: (center: CGPoint, zoom: CGFloat, turn: CGFloat)?  // where the page was when the third finger came down

    /// Three fingers dragging, telling the moment the third lands, so the page can go back to where it was then.
    final class Swipe: UIPanGestureRecognizer {
        var third: () -> Void = {}
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            if numberOfTouches == 3 { third() }
        }
    }

    init(controller: CanvasController) {
        self.controller = controller
        super.init()
        swipe.minimumNumberOfTouches = 3
        swipe.maximumNumberOfTouches = 3
        swipe.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        swipe.delegate = self
        swipe.addTarget(self, action: #selector(swiped))
        swipe.third = { [weak self] in
            guard let self, let c = self.controller else { return }
            held = (c.center, c.canvas.zoomScale, c.rotation)
        }
        controller.turner.addGestureRecognizer(swipe)
        shade.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchDown)
        shade.isAccessibilityElement = false
        panel.cornerConfiguration = .uniformCorners(radius: .fixed(18))
        let row = UIStackView(arrangedSubviews: [
            button("Copy for AI", "doc.on.clipboard", "The page, its answers and what Maple remembers, as JSON") { [weak self] in self?.copyJSON() },
            button("Copy SVG", "scribble.variable", "The page's ink and pictures as SVG") { [weak self] in self?.copySVG() },
        ])
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -8),
        ])
        // VoiceOver's three-finger swipes scroll, so its users get the same actions here.
        controller.canvas.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Copy for AI") { [weak self] _ in self?.copyJSON(); return true },
            UIAccessibilityCustomAction(name: "Copy SVG") { [weak self] _ in self?.copySVG(); return true },
        ]
    }

    func button(_ title: String, _ image: String, _ hint: String, _ run: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: image)
        config.imagePlacement = .top
        config.imagePadding = 6
        config.baseForegroundColor = .label
        config.background.backgroundColor = MapleStyle.fill
        config.background.cornerRadius = 13
        config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12)
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in run() })
        button.accessibilityHint = hint
        return button
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc func swiped(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed, panel.superview == nil, let c = controller else { return }
        let moved = gesture.translation(in: c.view)  // on the still screen, however the page lies
        guard moved.y > Self.reach, abs(moved.x) < moved.y / 2 else { return }
        open()
    }

    /// Shows the menu at the top of the screen, and puts the page back where it was when the third finger landed: two of
    /// them may have panned, pinched or turned it a little first.
    func open() {
        guard let c = controller, panel.superview == nil else { return }
        for recognizer in [c.canvas.panGestureRecognizer, c.canvas.pinchGestureRecognizer].compactMap({ $0 }) + (c.turner.gestureRecognizers ?? []).filter({ $0 is UIRotationGestureRecognizer }) {
            recognizer.isEnabled = false  // cancels it
            recognizer.isEnabled = true
        }
        if let held {
            c.rotation = held.turn
            c.show(held.center, zoom: held.zoom)
        }
        shade.frame = c.view.bounds
        shade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        c.view.addSubview(shade)
        c.view.addSubview(panel)
        panel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: c.view.safeAreaLayoutGuide.centerXAnchor),
            panel.topAnchor.constraint(equalTo: c.view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])
        panel.alpha = 0
        panel.transform = UIAccessibility.isReduceMotionEnabled ? .identity : CGAffineTransform(translationX: 0, y: -7)
        MapleStyle.animate(0.32) {
            self.panel.alpha = 1
            self.panel.transform = .identity
        }
        UIAccessibility.post(notification: .screenChanged, argument: panel)
    }

    func close() {
        shade.removeFromSuperview()
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18) { self.panel.alpha = 0 } completion: { _ in
            if self.panel.alpha == 0 { self.panel.removeFromSuperview() }
        }
    }

    func copyJSON(to board: UIPasteboard = .general) {
        guard let c = controller else { return }
        close()
        let viewport = [c.center.x, c.center.y, c.canvas.zoomScale, c.rotation].map(Double.init)
        do {
            board.string = try Export.json(title: c.page.title, viewport: viewport, drawing: c.canvas.drawing, notes: c.marks.notes, memory: c.marks.memories.memory)
            c.marks.flash("Copied for AI")
        } catch {
            c.marks.flash("Couldn't copy: \(error.localizedDescription)")
        }
    }

    func copySVG(to board: UIPasteboard = .general) {
        guard let c = controller else { return }
        close()
        let svg = Export.svg(drawing: c.canvas.drawing, notes: c.marks.notes, pictures: c.page.pictures)
        board.items = [[UTType.svg.identifier: Data(svg.utf8), UTType.utf8PlainText.identifier: svg]]  // design tools take the SVG, text fields the text
        c.marks.flash("Copied as SVG")
    }
}
