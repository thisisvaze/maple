import PencilKit
import UIKit

/// An answer beside its mark: a quiet dot that opens into a glass bubble. While Muse answers, the dot is the thinking
/// orb; it turns orange if asking failed, and a tap tries again.
/// It lives in the canvas's content, top-left at `anchor`, and grows and shrinks with the page like ink. It reads level in
/// the frame its mark was written in, the page turned by `turn`.
final class Bubble: UIView {
    static let width: CGFloat = 300
    var anchor: CGPoint
    let zoom: CGFloat  // the page's zoom when its mark was made
    var turn: CGFloat
    var note: Note? { didSet { update() } }  // nil while Muse is reading
    var retry: (() -> Void)? { didSet { update() } }
    var deleted: () -> Void = {}
    var open = false

    let dot = UIView()
    let orb = Thinking(style: .orb)
    let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    let label = UILabel()
    let heading = UILabel()
    let headingOrb = Thinking(style: .orb)
    let retryLabel = UILabel()
    let retrySymbol = UIImageView(image: UIImage(systemName: "exclamationmark.triangle"))
    let close = UIButton(configuration: .plain())
    let trash = UIButton(configuration: .plain())

    init(anchor: CGPoint, zoom: CGFloat, turn: CGFloat, note: Note? = nil) {
        self.anchor = anchor
        self.zoom = zoom
        self.turn = turn
        self.note = note
        super.init(frame: .zero)
        layer.anchorPoint = .zero  // `center` is then the top-left, so it can sit at the anchor
        dot.layer.cornerRadius = 6
        addSubview(dot)
        addSubview(orb)
        glass.cornerConfiguration = .uniformCorners(radius: .fixed(18))
        addSubview(glass)
        label.font = UIFontMetrics(forTextStyle: .callout).scaledFont(for: .systemFont(ofSize: 15))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 0
        glass.contentView.addSubview(label)
        heading.text = "Maple"
        heading.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12, weight: .semibold))
        heading.adjustsFontForContentSizeCategory = true
        heading.textColor = .secondaryLabel
        glass.contentView.addSubview(heading)
        glass.contentView.addSubview(headingOrb)
        retryLabel.text = "Couldn’t finish. Try again"
        retryLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12, weight: .medium))
        retryLabel.adjustsFontForContentSizeCategory = true
        retryLabel.textColor = MapleStyle.coral
        retrySymbol.tintColor = MapleStyle.coral
        retrySymbol.contentMode = .scaleAspectFit
        addSubview(retryLabel)
        addSubview(retrySymbol)
        for (button, title, image) in [(close, "Close", "minus"), (trash, "Delete", "trash")] {
            button.configuration?.baseForegroundColor = Marks.ink
            button.configuration?.image = UIImage(systemName: image)
            button.configuration?.background.backgroundColor = MapleStyle.fill
            button.configuration?.background.cornerRadius = 10
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
    /// The eraser's touch goes through to the page, where Marks rubs the dot out with the ink.
    override func point(inside p: CGPoint, with event: UIEvent?) -> Bool {
        if (superview as? PKCanvasView)?.tool is PKEraserTool, event?.allTouches?.contains(where: { $0.type == .pencil }) == true { return false }
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
        MapleStyle.animate(0.32) { self.update() }
    }

    func update() {
        dot.backgroundColor = Marks.ink
        glass.isHidden = !open
        headingOrb.isHidden = !open
        retryLabel.isHidden = retry == nil
        retrySymbol.isHidden = retry == nil
        isAccessibilityElement = !open
        accessibilityLabel = retry != nil ? "Couldn't answer. Try again" : note == nil ? "Thinking" : "Answer"
        let thinking = note == nil && retry == nil
        orb.isHidden = !thinking
        dot.isHidden = open || thinking || retry != nil
        backgroundColor = retry == nil ? .clear : .paper.withAlphaComponent(0.94)
        layer.cornerRadius = 15
        if retry != nil {
            let width = max(190, retryLabel.intrinsicContentSize.width + 48)
            bounds = CGRect(x: 0, y: 0, width: width, height: max(44, retryLabel.intrinsicContentSize.height + 20))
            retrySymbol.frame = CGRect(x: 12, y: (bounds.height - 18) / 2, width: 18, height: 18)
            retryLabel.frame = CGRect(x: 38, y: 0, width: bounds.width - 48, height: bounds.height)
            return
        }
        guard open, let note else {
            bounds = CGRect(x: 0, y: 0, width: thinking ? 34 : 28, height: thinking ? 34 : 28)
            dot.frame = CGRect(x: 8, y: 8, width: 12, height: 12)
            orb.frame = bounds
            return
        }
        label.text = note.reply
        let textWidth = Self.width - 28
        let height = label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        bounds = CGRect(x: 0, y: 0, width: Self.width, height: height + 96)
        glass.frame = bounds
        headingOrb.frame = CGRect(x: 10, y: 8, width: 24, height: 24)
        heading.frame = CGRect(x: 39, y: 8, width: textWidth - 25, height: 24)
        label.frame = CGRect(x: 14, y: 38, width: textWidth, height: height)
        let row = height + 44
        trash.frame = CGRect(x: Self.width - 54, y: row, width: 44, height: 44)
        close.frame = CGRect(x: Self.width - 102, y: row, width: 44, height: 44)
    }

    /// Sits at its anchor and scales with the page since its mark was made; text stays sharp up to 3× that.
    func place(zoom current: CGFloat) {
        let scale = current / zoom
        transform = CGAffineTransform(rotationAngle: -turn).scaledBy(x: scale, y: scale)
        center = CGPoint(x: anchor.x * current, y: anchor.y * current)
        label.contentScaleFactor = traitCollection.displayScale * min(max(scale, 1), 3)
        orb.contentScaleFactor = label.contentScaleFactor
    }
}
