import UIKit

/// An answer beside its mark: a quiet dot that opens into a glass bubble. While Muse answers, the dot is the thinking
/// orb; it turns orange if asking failed, and a tap tries again.
/// It lives in the canvas's content, top-left at `anchor`, and grows and shrinks with the page like ink.
final class Bubble: UIView {
    static let width: CGFloat = 300
    let anchor: CGPoint
    let zoom: CGFloat  // the page's zoom when its mark was made
    var note: Note? { didSet { update() } }  // nil while Muse is reading
    var retry: (() -> Void)? { didSet { update() } }
    var deleted: () -> Void = {}
    var open = false

    let dot = UIView()
    let orb = Thinking(style: .orb)
    let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    let label = UILabel()
    let close = UIButton(configuration: .plain())
    let trash = UIButton(configuration: .plain())

    init(anchor: CGPoint, zoom: CGFloat, note: Note? = nil) {
        self.anchor = anchor
        self.zoom = zoom
        self.note = note
        super.init(frame: .zero)
        layer.anchorPoint = .zero  // `center` is then the top-left, so it can sit at the anchor
        dot.layer.cornerRadius = 6
        addSubview(dot)
        addSubview(orb)
        glass.cornerConfiguration = .uniformCorners(radius: .fixed(14))
        addSubview(glass)
        label.font = .preferredFont(forTextStyle: .callout)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Marks.ink
        label.numberOfLines = 0
        glass.contentView.addSubview(label)
        for (button, title, image) in [(close, "Close", "minus"), (trash, "Delete", "trash")] {
            button.configuration?.baseForegroundColor = Marks.ink
            button.configuration?.image = UIImage(systemName: image)
            button.accessibilityLabel = title
            glass.contentView.addSubview(button)
        }
        close.addAction(UIAction { [unowned self] _ in toggle(false) }, for: .primaryActionTriggered)
        trash.addAction(UIAction { [unowned self] _ in deleted() }, for: .primaryActionTriggered)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        accessibilityTraits = .button
        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// An open answer lets the Pencil write through it: only its buttons take touches.
    override func point(inside p: CGPoint, with event: UIEvent?) -> Bool {
        guard open else { return super.point(inside: p, with: event) }
        return [close, trash].contains { $0.frame.insetBy(dx: -6, dy: -6).contains(p) }
    }

    @objc func tapped() { _ = accessibilityActivate() }

    override func accessibilityActivate() -> Bool {
        if let retry { retry() } else if note != nil { toggle(true) }
        return true
    }

    func toggle(_ open: Bool) {
        self.open = open
        UIView.animate(springDuration: 0.35, bounce: 0.2) { self.update() }
    }

    func update() {
        dot.backgroundColor = retry == nil ? Marks.ink : .systemOrange
        glass.isHidden = !open
        isAccessibilityElement = !open
        accessibilityLabel = retry != nil ? "Couldn't answer. Try again" : note == nil ? "Thinking" : "Answer"
        let thinking = note == nil && retry == nil
        orb.isHidden = !thinking
        dot.isHidden = open || thinking
        guard open, let note else {
            bounds = CGRect(x: 0, y: 0, width: thinking ? 34 : 28, height: thinking ? 34 : 28)
            dot.frame = CGRect(x: 8, y: 8, width: 12, height: 12)
            orb.frame = bounds
            return
        }
        label.text = note.reply
        let textWidth = Self.width - 28
        let height = label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        bounds = CGRect(x: 0, y: 0, width: Self.width, height: height + 58)
        glass.frame = bounds
        label.frame = CGRect(x: 14, y: 14, width: textWidth, height: height)
        let row = height + 20
        trash.frame = CGRect(x: Self.width - 42, y: row, width: 36, height: 32)
        close.frame = CGRect(x: Self.width - 78, y: row, width: 36, height: 32)
    }

    /// Sits at its anchor and scales with the page since its mark was made; text stays sharp up to 3× that.
    func place(zoom current: CGFloat) {
        let scale = current / zoom
        transform = CGAffineTransform(scaleX: scale, y: scale)
        center = CGPoint(x: anchor.x * current, y: anchor.y * current)
        label.contentScaleFactor = traitCollection.displayScale * min(max(scale, 1), 3)
        orb.contentScaleFactor = label.contentScaleFactor
    }
}
