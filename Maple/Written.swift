import PencilKit

/// An answer Maple wrote in ink. The strokes are on the page; this clear view over them reads the answer to VoiceOver,
/// and when the answer lands, hides the ink under paper and writes it back in with a pen's stroke. A drawing gets one
/// for as long as it draws itself in. The Pencil writes through it.
final class Written: UIView {
    static let perLetter = 0.04  // calibration knob: seconds of writing per letter, within 0.9–2 s
    static let drawingSpeed: CGFloat = 1400  // calibration knob: screen points of line a second, within 1–3 s a drawing
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

    /// Writes an answer of `letters` back in: see `reveal(_:along:duration:)`.
    func reveal(_ strokes: [PKStroke], along lines: [[CGPoint]], letters: Int) {
        reveal(strokes, along: lines, duration: min(max(Double(letters) * Self.perLetter, 0.9), 2))
    }

    /// Writes `strokes`, the committed ink, back in along `lines`, their pen lines in order in the block's reading frame:
    /// paper along the lines hides the ink, and a picture of that same ink shows through a pen-wide trail that runs along
    /// them, so what's written in is exactly what stays, grain and all. Both go once the writing is done, then `done`.
    func reveal(_ strokes: [PKStroke], along lines: [[CGPoint]], duration: Double, done: @escaping () -> Void = {}) {
        let local = CGAffineTransform(translationX: -block.minX, y: -block.minY)
        let ink = PKDrawing(strokes: strokes).transformed(using: CGAffineTransform(rotationAngle: turn).concatenating(local))
        let area = ink.bounds.insetBy(dx: -2, dy: -2), trail = CGMutablePath()
        for points in lines where points.count > 1 { trail.addLines(between: points.map { $0.applying(local) }) }
        guard !UIAccessibility.isReduceMotionEnabled, !area.isNull, !trail.isEmpty else { return done() }
        let scale = traitCollection.displayScale * min(max(hypot(transform.a, transform.b), 1), 3)
        var picture: UIImage?
        traitCollection.performAsCurrent { picture = ink.image(from: area, scale: scale) }
        // Wide enough for the pencil, its taper and a drawn line's bow, as written at the zoom it was written at.
        let width = 2 * (AgentPen.hand / 2 + AgentPen.bow + 1) / note.zoom
        let cover = CAShapeLayer(), copy = CALayer(), pen = CAShapeLayer()
        cover.path = trail
        cover.strokeColor = UIColor.paper.resolvedColor(with: traitCollection).cgColor
        copy.frame = area
        copy.contents = picture?.cgImage
        pen.path = trail
        pen.strokeColor = UIColor.black.cgColor
        pen.position = CGPoint(x: -area.minX, y: -area.minY)  // in the copy's own coordinates
        for shape in [cover, pen] {
            shape.fillColor = nil
            shape.lineWidth = width
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.contentsScale = scale
        }
        copy.mask = pen
        layer.addSublayer(cover)
        layer.addSublayer(copy)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak cover, weak copy] in
            cover?.removeFromSuperlayer()
            copy?.removeFromSuperlayer()
            done()
        }
        let writing = CABasicAnimation(keyPath: "strokeEnd")
        writing.fromValue = 0
        writing.toValue = 1
        writing.duration = duration
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
