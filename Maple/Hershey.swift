import CoreGraphics
import Foundation

/// Hershey's Simplex Sans (futural.jhf, see Hershey-LICENSE.txt): every glyph is a few pen strokes, so the agent's labels
/// are written like a pen, as real ink, not typeset.
nonisolated struct Hershey: Sendable {
    struct Glyph: Sendable {
        var left, right: CGFloat
        var lines: [[CGPoint]]
    }

    let glyphs: [Glyph]  // ASCII order from the space
    static let pen = Hershey(Bundle.main.url(forResource: "futural", withExtension: "jhf").flatMap { try? String(contentsOf: $0, encoding: .ascii) } ?? "")

    /// Each glyph is a 5-digit id, a 3-digit pair count, then letter pairs offset from "R": the left and right edges
    /// first, then points, with " R" lifting the pen. Records may wrap across lines.
    init(_ jhf: String) {
        let bytes = Array(jhf.filter { !$0.isNewline }.utf8)
        var glyphs: [Glyph] = [], i = 0
        while i + 8 <= bytes.count, let count = Int(String(decoding: bytes[i + 5 ..< i + 8], as: UTF8.self).trimmingCharacters(in: .whitespaces)) {
            let end = i + 8 + 2 * count
            guard count > 0, end <= bytes.count else { break }
            let pairs = stride(from: i + 8, to: end, by: 2).map { (CGFloat(Int(bytes[$0]) - 82), CGFloat(Int(bytes[$0 + 1]) - 82)) }
            var lines: [[CGPoint]] = [[]]
            for (x, y) in pairs.dropFirst() {
                if x == -50, y == 0 { lines.append([]) } else { lines[lines.count - 1].append(CGPoint(x: x, y: y)) }
            }
            glyphs.append(Glyph(left: pairs[0].0, right: pairs[0].1, lines: lines.filter { $0.count > 1 }))
            i = end
        }
        self.glyphs = glyphs
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
