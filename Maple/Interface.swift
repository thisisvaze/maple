import UIKit

enum MapleStyle {
    static let green = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.66, green: 0.78, blue: 0.66, alpha: 1)
        : UIColor(red: 0.21, green: 0.41, blue: 0.29, alpha: 1) }
    static let coral = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.97, green: 0.60, blue: 0.46, alpha: 1)
        : UIColor(red: 0.78, green: 0.31, blue: 0.19, alpha: 1) }
    static let fill = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.20, green: 0.24, blue: 0.21, alpha: 1)
        : UIColor(red: 0.91, green: 0.92, blue: 0.90, alpha: 1) }

    static func animate(_ duration: TimeInterval = 0.28, _ changes: @escaping () -> Void) {
        guard !UIAccessibility.isReduceMotionEnabled else { changes(); return }
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut], animations: changes)
    }

    static func surface(_ view: UIView, radius: CGFloat = 18) {
        view.backgroundColor = .paper.withAlphaComponent(0.94)
        view.layer.cornerRadius = radius
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 0.5
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.06
        view.layer.shadowRadius = 9
        view.layer.shadowOffset = CGSize(width: 0, height: 3)
        view.layer.borderColor = UIColor.separator.resolvedColor(with: view.traitCollection).withAlphaComponent(0.2).cgColor
        view.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: UIView, _: UITraitCollection) in
            view.layer.borderColor = UIColor.separator.resolvedColor(with: view.traitCollection).withAlphaComponent(0.2).cgColor
        }
    }
}

/// The same compact, stable control for AI, voice and tools; its whole 44 pt surface takes a touch.
final class MapleButton: UIButton {
    enum Mark: Equatable { case symbol(String), orb, waveform, loading }
    let caption = UILabel()
    let detail = UILabel()
    let symbol = UIImageView()
    let orb = Thinking(style: .orb)
    let waveform = UIStackView()
    let spinner = UIActivityIndicatorView(style: .medium)
    var minimumWidth: CGFloat = 44
    private(set) var mark = Mark.symbol("")

    init(minimumWidth: CGFloat = 44) {
        self.minimumWidth = minimumWidth
        super.init(frame: .zero)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        caption.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
        detail.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .monospacedDigitSystemFont(ofSize: 11, weight: .medium))
        for label in [caption, detail] { label.adjustsFontForContentSizeCategory = true }
        symbol.contentMode = .center  // draw at the 17 pt configuration; aspect-fit blew glyphs up to the 24 pt box
        symbol.preferredSymbolConfiguration = .init(pointSize: 17, weight: .medium)
        waveform.axis = .horizontal
        waveform.alignment = .center
        waveform.distribution = .fillEqually
        waveform.spacing = 2
        for height: CGFloat in [7, 13, 20, 13, 7] {
            let bar = UIView()
            bar.layer.cornerRadius = 1.5
            bar.heightAnchor.constraint(equalToConstant: height).isActive = true
            waveform.addArrangedSubview(bar)
        }
        for child in [caption, detail, symbol, orb, waveform, spinner] {
            child.isUserInteractionEnabled = false
            child.isAccessibilityElement = false
            addSubview(child)
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func display(_ title: String, mark: Mark, color: UIColor = .label, filled: Bool = false, detail: String = "") {
        let changed = caption.text != title || self.mark != mark
        self.mark = mark
        caption.text = title
        caption.textColor = color
        self.detail.text = detail
        self.detail.textColor = color.withAlphaComponent(0.7)
        tintColor = color
        waveform.arrangedSubviews.forEach { $0.backgroundColor = color }
        symbol.isHidden = true
        orb.isHidden = mark != .orb
        waveform.isHidden = mark != .waveform
        spinner.isHidden = mark != .loading
        if case .symbol(let name) = mark { symbol.image = UIImage(systemName: name); symbol.isHidden = false }
        if mark == .loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        let background = filled ? color.withAlphaComponent(traitCollection.userInterfaceStyle == .dark ? 0.16 : 0.10) : MapleStyle.fill
        MapleStyle.animate { self.backgroundColor = background }
        if changed, window != nil, !UIAccessibility.isReduceMotionEnabled {
            let fade = CATransition(); fade.type = .fade; fade.duration = 0.28
            caption.layer.add(fade, forKey: "state")
        }
        accessibilityLabel = title
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        let text = caption.intrinsicContentSize, tail = detail.text?.isEmpty == false ? detail.intrinsicContentSize.width + 7 : 0
        return CGSize(width: max(minimumWidth, 20 + 24 + (caption.text?.isEmpty == false ? 7 + text.width : 0) + tail), height: max(44, text.height + 20))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let hasTitle = caption.text?.isEmpty == false
        let icon = CGRect(x: hasTitle ? 9 : (bounds.width - 24) / 2, y: (bounds.height - 24) / 2, width: 24, height: 24)
        for view in [symbol, orb, waveform, spinner] { view.frame = icon }
        let tail = detail.text?.isEmpty == false ? detail.intrinsicContentSize.width : 0
        detail.frame = CGRect(x: bounds.width - 10 - tail, y: 0, width: tail, height: bounds.height)
        caption.frame = CGRect(x: 40, y: 0, width: max(0, bounds.width - 50 - (tail > 0 ? tail + 7 : 0)), height: bounds.height)
    }

    override var isEnabled: Bool { didSet { MapleStyle.animate { self.alpha = self.isEnabled ? 1 : 0.42 } } }
    override var isHighlighted: Bool {
        didSet { MapleStyle.animate(0.18) { self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity } }
    }

    func level(_ value: CGFloat) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let value = min(max(value, 0.15), 1)
        MapleStyle.animate(0.1) { self.waveform.transform = CGAffineTransform(scaleX: 1, y: value) }
    }
}

final class StatusLabel: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12, weight: .medium))
        adjustsFontForContentSizeCategory = true
        textColor = .secondaryLabel
        MapleStyle.surface(self, radius: 14)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var intrinsicContentSize: CGSize { let s = super.intrinsicContentSize; return CGSize(width: s.width + 24, height: max(40, s.height + 16)) }
    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 12, dy: 8)) }
}
