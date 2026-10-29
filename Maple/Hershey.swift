import CoreGraphics
import Foundation

/// A Hershey pen face (see Hershey-LICENSE.txt): every glyph is a few pen strokes, so the agent's labels and answers
/// are written like a pen, as real ink, not typeset. Simplex Sans (futural.jhf) writes the labels in drawings.
nonisolated struct Hershey: Sendable {
    struct Glyph: Sendable {
        var left, right: CGFloat
        var lines: [[CGPoint]]
    }

    let glyphs: [Glyph]  // ASCII order from the space
    static let pen = bundled("futural")  // Simplex Sans, for labels in drawings

    static func bundled(_ name: String) -> Hershey {
        Hershey(Bundle.main.url(forResource: name, withExtension: "jhf").flatMap { try? String(contentsOf: $0, encoding: .ascii) } ?? "")
    }

    /// Each glyph is a 5-digit id, a 3-digit pair count, then its letter pairs. Records may wrap across lines.
    init(_ jhf: String) {
        let bytes = Array(jhf.filter { !$0.isNewline }.utf8)
        var glyphs: [Glyph] = [], i = 0
        while i + 8 <= bytes.count, let count = Int(String(decoding: bytes[i + 5 ..< i + 8], as: UTF8.self).trimmingCharacters(in: .whitespaces)) {
            let end = i + 8 + 2 * count
            guard count > 0, end <= bytes.count else { break }
            glyphs.append(Self.glyph(String(decoding: bytes[i + 8 ..< end], as: UTF8.self)))
            i = end
        }
        // The faces float the low dots of . , : ; 3 units over the baseline (y 9), so 2.5 read as 2·5: set them on it.
        for mark in ".,:;" where Int(mark.asciiValue!) - 32 < glyphs.count {
            let g = Int(mark.asciiValue!) - 32
            glyphs[g].lines = glyphs[g].lines.map { line in line.allSatisfy { $0.y >= 3 } ? line.map { CGPoint(x: $0.x, y: $0.y + 3) } : line }
        }
        self.glyphs = glyphs
    }

    /// One glyph as letter pairs offset from "R": the left and right edges first, then points, with " R" lifting the pen.
    /// Capitals run from y -12 to the baseline at 9.
    static func glyph(_ pairs: String) -> Glyph {
        let bytes = Array(pairs.utf8)
        let xy = stride(from: 0, to: bytes.count - 1, by: 2).map { (CGFloat(Int(bytes[$0]) - 82), CGFloat(Int(bytes[$0 + 1]) - 82)) }
        var lines: [[CGPoint]] = [[]]
        for (x, y) in xy.dropFirst() {
            if x == -50, y == 0 { lines.append([]) } else { lines[lines.count - 1].append(CGPoint(x: x, y: y)) }
        }
        return Glyph(left: xy.first?.0 ?? 0, right: xy.first?.1 ?? 0, lines: lines.filter { $0.count > 1 })
    }

    /// How far `text` advances with capitals `height` tall. Characters the font lacks are skipped.
    func width(_ text: String, height: CGFloat) -> CGFloat {
        text.unicodeScalars.reduce(0) { sum, scalar in
            guard scalar.value >= 32, Int(scalar.value) - 32 < glyphs.count else { return sum }
            let g = glyphs[Int(scalar.value) - 32]
            return sum + (g.right - g.left) * height / 21
        }
    }

    /// `text` as pen lines, its top-left at `origin` and capitals `height` tall. Characters the font lacks are skipped.
    func lines(_ text: String, at origin: CGPoint, height: CGFloat) -> [[CGPoint]] {
        let k = height / 21  // capitals run from -12 to 9
        var x = origin.x, out: [[CGPoint]] = []
        for scalar in text.unicodeScalars where scalar.value >= 32 && Int(scalar.value) - 32 < glyphs.count {
            let g = glyphs[Int(scalar.value) - 32]
            out += g.lines.map { $0.map { CGPoint(x: x + ($0.x - g.left) * k, y: origin.y + ($0.y + 12) * k) } }
            x += (g.right - g.left) * k
        }
        return out
    }
}
