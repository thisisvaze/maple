import PencilKit

/// A page, copied out of Maple: everything Maple knows about it as JSON to paste into another AI, or its ink as SVG.
/// Coordinates are page points, x rightward, y downward. Edit marks are instructions, never content, so neither has them.
enum Export {
    /// What an AI needs to pick up where Maple is: the page, what Maple remembers about the person, every answer and
    /// drawing with what it was made from, and the ink itself, simplified.
    static func json(title: String, viewport: [Double], drawing: PKDrawing, notes: [Note], memory: Memory) throws -> String {
        struct Remembered: Encodable { var text, from, because: String, date: Date }
        struct Answer: Encodable {
            var kind, read, reply: String
            var at: [Double], box: [Double]?, turn: Double?
            var drawing: Drawing?, picture: String?
        }
        struct Line: Encodable { var by: String, points: [[Double]] }
        struct View: Encodable { var center: [Double], zoom, turn: Double }
        struct Page: Encodable {
            var about = "A page from Maple, a pen-and-paper workspace on iPad where AI answers handwritten marks. Coordinates are page points, x rightward, y downward. ink is every stroke on the page, by the person or by Maple; answers are what Maple read in the person's marks and what it replied or drew; memory is what Maple remembers about the person across pages."
            var title: String, exported: Date, view: View?
            var memory: [Remembered], answers: [Answer], ink: [Line]
        }
        func r(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }
        let view = viewport.count >= 3 ? View(center: [viewport[0], viewport[1]].map { ($0 * 10).rounded() / 10 }, zoom: viewport[2],
                                               turn: viewport.count > 3 ? (viewport[3] * 180 / .pi * 10).rounded() / 10 : 0) : nil
        let page = Page(title: title, exported: .now, view: view,
                        memory: memory.active.map { Remembered(text: $0.text, from: $0.author == "you" ? "the person" : "Maple", because: $0.because, date: $0.date) },
                        answers: notes.map { note in
                            Answer(kind: note.mark, read: note.reading, reply: note.reply, at: [r(note.anchor.x), r(note.anchor.y)],
                                   box: note.rect.map { [r($0.minX), r($0.minY), r($0.width), r($0.height)] }, turn: note.turn.map { (Double($0) * 1800 / .pi).rounded() / 10 },
                                   drawing: note.source, picture: note.picture)
                        },
                        ink: drawing.strokes.filter { !AgentPen.edit($0) }.flatMap { stroke in
                            lines(stroke, tolerance: 0.75).map { Line(by: AgentPen.wrote(stroke) ? "maple" : "person", points: $0.map { [r($0.x), r($0.y)] }) }
                        })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(page), as: UTF8.self)
    }

    /// The page's ink as SVG, with pictures under it as they show, framed to the ink with a little margin.
    static func svg(drawing: PKDrawing, notes: [Note], pictures: URL) -> String {
        let strokes = drawing.strokes.filter { !AgentPen.edit($0) }
        let painted = notes.filter { $0.picture != nil && $0.rect != nil }
        var frame = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        for note in painted { frame = frame.union(note.rect!.applying(CGAffineTransform(rotationAngle: -(note.turn ?? 0)))) }
        if frame.isNull { frame = CGRect(x: 0, y: 0, width: 1, height: 1) }
        frame = frame.insetBy(dx: -20, dy: -20).integral
        func f(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }
        var out = ["<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(f(frame.minX)) \(f(frame.minY)) \(f(frame.width)) \(f(frame.height))\" width=\"\(f(frame.width))\" height=\"\(f(frame.height))\">"]
        for note in painted {
            guard let data = try? Data(contentsOf: pictures.appending(path: note.picture!)), let rect = note.rect else { continue }
            let kind = note.picture!.hasSuffix(".webp") ? "webp" : "png", turn = -Double(note.turn ?? 0) * 180 / .pi
            out.append("<image transform=\"rotate(\(String(format: "%.3f", turn)))\" x=\"\(f(rect.minX))\" y=\"\(f(rect.minY))\" width=\"\(f(rect.width))\" height=\"\(f(rect.height))\" preserveAspectRatio=\"xMidYMid slice\" href=\"data:image/\(kind);base64,\(data.base64EncodedString())\"/>")
        }
        for stroke in strokes {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            stroke.ink.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let colour = String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
            let size = stroke.path.first?.size.width ?? 3, width = max(2 * (size - 2), 0.5)  // how thick PencilKit draws a point of this size
            for line in lines(stroke, tolerance: 0.25) where line.count > 1 {
                let d = "M" + line.map { "\(f($0.x)) \(f($0.y))" }.joined(separator: "L")
                out.append("<path d=\"\(d)\" fill=\"none\" stroke=\"\(colour)\"\(a < 1 ? String(format: " stroke-opacity=\"%.2f\"", Double(a)) : "") stroke-width=\"\(f(width))\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>")
            }
        }
        out.append("</svg>")
        return out.joined(separator: "\n")
    }

    /// What the eraser left of a stroke, as lines through its curve, each simplified to within `tolerance` page points.
    static func lines(_ stroke: PKStroke, tolerance: CGFloat) -> [[CGPoint]] {
        stroke.maskedPathRanges.map { range in
            simplified(stroke.path.interpolatedPoints(in: range, by: .distance(1)).map { $0.location.applying(stroke.transform) }, tolerance)
        }
    }

    /// Ramer–Douglas–Peucker: the fewest points that stay within `tolerance` of the line.
    static func simplified(_ points: [CGPoint], _ tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count), stack = [(0, points.count - 1)]
        keep[0] = true
        keep[points.count - 1] = true
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var far = a, most: CGFloat = 0
            for i in (a + 1)..<b {
                let d = Shape.away(points[i], points[a], points[b])
                if d > most { (far, most) = (i, d) }
            }
            if most > tolerance {
                keep[far] = true
                stack += [(a, far), (far, b)]
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }
}
