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

    private var cover: CAShapeLayer?  // paper where the eraser has rubbed this stroke, until the file keeps it

    /// Page points `line` in the picture's own points, from its box's top-left.
    func local(_ line: [CGPoint]) -> [CGPoint] {
        let frame = CGAffineTransform(rotationAngle: turn)
        return line.map { $0.applying(frame) }.map { CGPoint(x: $0.x - block.minX, y: $0.y - block.minY) }
    }

    /// A line through `points`; one point is a dot, as a tap of the eraser rubs.
    static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.count == 1 ? points + points : points)
        return path
    }

    /// Covers the picture in paper along the eraser's `line`, page points `width` wide, as it rubs.
    func rub(_ line: [CGPoint], width: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let cover = cover ?? CAShapeLayer()
        if self.cover == nil {
            (cover.fillColor, cover.lineCap, cover.lineJoin) = (nil, .round, .round)
            layer.addSublayer(cover)
            self.cover = cover
        }
        cover.strokeColor = UIColor.paper.resolvedColor(with: traitCollection).cgColor
        cover.lineWidth = width
        cover.path = Self.path(local(line))
        CATransaction.commit()
    }

    func endRub() {
        cover?.removeFromSuperlayer()
        cover = nil
    }

    /// The picture with `line`, page points `width` wide, rubbed out of it, as a PNG at its box's own shape, and whether
    /// any of it is left. Nil when the eraser took nothing of it: it missed, or went over parts already rubbed out.
    func rubbedOut(_ line: [CGPoint], width: CGFloat) -> (png: Data, left: Bool)? {
        let local = local(line), box = CGRect(origin: .zero, size: block.size), side = max(box.width, box.height)
        guard let image, image.size.width > 0, image.size.height > 0, side > 0,
              local.contains(where: box.insetBy(dx: -width / 2, dy: -width / 2).contains) else { return nil }  // far off: nothing to render
        func render(_ scale: CGFloat, rubbed: Bool, narrower: CGFloat = 0) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            return UIGraphicsImageRenderer(size: box.size, format: format).image { context in
                image.fill(box)
                guard rubbed else { return }
                let cg = context.cgContext
                cg.setBlendMode(.clear)
                cg.setLineWidth(max(width - narrower, 0))
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                cg.addPath(Self.path(local))
                cg.strokePath()
            }
        }
        // Seen 128 px a side, the eraser must take at least an eighth of a pixel, measured a little inside its edge, so going
        // over a part already rubbed out doesn't count the soft edge it shaves.
        let sample = 128 / side
        guard Self.alphas(render(sample, rubbed: false)).reduce(0, +) - Self.alphas(render(sample, rubbed: true, narrower: 3 / sample)).reduce(0, +) > 32 else {
            return nil
        }
        // At the detail the picture has in its box and no more: a big box drawn zoomed out holds few of its pixels a point.
        guard let png = render(image.scale / max(box.width / image.size.width, box.height / image.size.height), rubbed: true).pngData() else { return nil }
        // What's left, seen 32 px a side: any part of it still a tenth there.
        return (png, Self.alphas(render(32 / side, rubbed: true)).contains { $0 > 25 })
    }

    /// Each of an image's pixels' alpha, 0 to 255.
    static func alphas(_ image: UIImage) -> [Int] {
        guard let cg = image.cgImage else { return [] }
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return stride(from: 3, to: pixels.count, by: 4).map { Int(pixels[$0]) }
    }
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
