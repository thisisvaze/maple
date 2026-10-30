import PencilKit

/// An answer Maple wrote in ink. The strokes are on the page; this clear view over them reads the answer to VoiceOver,
/// and when the answer lands, hides the ink under paper and writes it back in with a pen's stroke. The Pencil writes
/// through it.
final class Written: UIView {
    static let perLetter = 0.04  // calibration knob: seconds of writing per letter, within 0.9–2 s
    let note: Note
    let block: CGRect, turn: CGFloat  // the written block in its reading frame

    init(note: Note) {
        self.note = note
        block = note.rect ?? .zero
        turn = note.turn ?? 0
        super.init(frame: .zero)
        layer.anchorPoint = .zero  // `center` is then the block's top-left
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = note.reply
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func place(zoom: CGFloat) {
        pin(to: block, turn: turn, zoom: zoom)
        layer.sublayers?.forEach { $0.contentsScale = traitCollection.displayScale * min(max(zoom, 1), 3) }
    }

    /// Writes `lines`, in the block's reading frame, over paper that hides the committed ink, in order and in the colour
    /// PencilKit draws Maple's blue on this paper. The paper and pen go once the writing is done.
    func reveal(_ lines: [[CGPoint]], letters: Int) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let local = CGAffineTransform(translationX: -block.minX, y: -block.minY)
        let line = AgentPen.thickness / note.zoom  // as thick as AgentPen drew it, at the zoom it wrote at
        let cover = CAShapeLayer(), pen = CAShapeLayer(), ink = CGMutablePath(), paper = CGMutablePath()
        for points in lines where points.count > 1 {
            let path = points.map { $0.applying(local) }
            ink.addLines(between: path)
            paper.addRect(path.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -line * 2, dy: -line * 2))
        }
        cover.path = paper
        cover.fillColor = UIColor.paper.resolvedColor(with: traitCollection).cgColor
        pen.path = ink
        pen.fillColor = nil
        pen.strokeColor = PKInkingTool.convertColor(AgentPen.blue, from: .light, to: traitCollection.userInterfaceStyle).cgColor
        pen.lineWidth = line
        pen.lineCap = .round
        pen.lineJoin = .round
        for sub in [cover, pen] {
            sub.contentsScale = traitCollection.displayScale * min(max(hypot(transform.a, transform.b), 1), 3)
            layer.addSublayer(sub)
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak cover, weak pen] in
            cover?.removeFromSuperlayer()
            pen?.removeFromSuperlayer()
        }
        let writing = CABasicAnimation(keyPath: "strokeEnd")
        writing.fromValue = 0
        writing.toValue = 1
        writing.duration = min(max(Double(letters) * Self.perLetter, 0.9), 2)
        pen.add(writing, forKey: "writing")
        CATransaction.commit()
    }
}

/// A picture in a box, under the ink, so the person can write on it. It lives in the canvas's content, level in the frame
/// the box was drawn in, and grows and shrinks with the page. The Pencil writes through it.
final class PictureView: UIImageView {
    let note: Note
    let block: CGRect, turn: CGFloat

    init(note: Note, file: URL) {
        self.note = note
        block = note.rect ?? .zero
        turn = note.turn ?? 0
        super.init(image: UIImage(contentsOfFile: file.path))
        layer.anchorPoint = .zero
        contentMode = .scaleAspectFill
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = "Picture: " + note.reply
        accessibilityTraits = .image
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func place(zoom: CGFloat) { pin(to: block, turn: turn, zoom: zoom) }
}

extension UIView {
    /// Sits over `box`, a rect in the page turned by `turn`, scaled with the page. Its anchor point must be .zero.
    func pin(to box: CGRect, turn: CGFloat, zoom: CGFloat) {
        bounds = CGRect(origin: .zero, size: box.size)
        transform = CGAffineTransform(rotationAngle: -turn).scaledBy(x: zoom, y: zoom)
        let corner = box.origin.applying(CGAffineTransform(rotationAngle: -turn))
        center = CGPoint(x: corner.x * zoom, y: corner.y * zoom)
    }
}

extension UIImage {
    /// Draws the picture filling `rect`, cropped evenly to its shape.
    nonisolated func fill(_ rect: CGRect) {
        let scale = max(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale, height = size.height * scale
        UIGraphicsGetCurrentContext()?.saveGState()
        UIGraphicsGetCurrentContext()?.clip(to: rect)
        draw(in: CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height))
        UIGraphicsGetCurrentContext()?.restoreGState()
    }
}
