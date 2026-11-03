import CoreGraphics
import Foundation

/// An answer written as ink in pen faces: Maple Hand (Handlee traced into strokes) for Latin, Hershey Greek, and maths
/// signs drawn the same way, with powers raised and subscripts lowered, word-wrapped to a width. It is written exactly
/// as given or not at all: `writable` is nil when any character has no glyph, and the app keeps its quiet dot. Sizes are
/// page points; `cap` is the capital height.
nonisolated struct Handwriting: Sendable {
    let glyphs: [Character: Hershey.Glyph]  // glyph units: capitals run from y -12 to the baseline at 9
    static let answers = Handwriting(latin: .pen, greek: .bundled("greek"))

    // Proportions, in capitals.
    static let lineGap: CGFloat = 1.6  // calibration knob: from one line's capital top to the next
    static let raise: CGFloat = 0.45, small: CGFloat = 0.62  // calibration knob: a power's baseline lift and size
    static let drop: CGFloat = 0.25  // calibration knob: a subscript's baseline drop; it is `small` too
    static let greekSize: CGFloat = 0.8  // calibration knob: lowercase Greek, to sit with the hand's x-height
    static let itemGap: CGFloat = 0.45  // calibration knob: extra space above each line of a list, so items don't run together
    static let hang: CGFloat = 0.9  // calibration knob: how far a list item's wrapped lines sit in from its first
    /// Units a number keeps on its line, as a typesetter's non-breaking space would: never "300 / cm".
    static let units: Set<String> = ["mm", "cm", "m", "km", "in", "ft", "mi", "g", "kg", "mg", "lb", "oz", "ml", "l", "L", "s", "min", "h", "hr", "hrs",
                                     "am", "pm", "%", "°", "°C", "°F", "px", "pt", "x", "×"]

    /// One written line: its text, the extra space above it and how far in it starts, both in capitals. A string
    /// literal is a plain line, so a single line can still be written as "x = 7".
    struct Line: Equatable, Sendable, ExpressibleByStringLiteral {
        var text: String
        var above: CGFloat = 0, indent: CGFloat = 0
        init(_ text: String, above: CGFloat = 0, indent: CGFloat = 0) { (self.text, self.above, self.indent) = (text, above, indent) }
        init(stringLiteral text: String) { self.init(text) }
    }

    /// Unicode Greek on the Greek face's ASCII positions, laid out like the Symbol font (p is pi), with the maths signs
    /// that are Greek letters: micro, partial, increment, n-ary sum and product. Its only theta is the open ϑ, so θ writes
    /// that too; final sigma writes σ. The ohm sign is Omega already, by canonical equivalence.
    static let letters = zipped("αβγδεζηθικλμνξοπρσςτυφχψωϑϕϵµ∂ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩϒ∆∑∏",
                                "abgdezhqiklmnxoprsstufcywqfemdABGDEZHQIKLMNXOPRSTUFCYWUDSP")
    /// The Greek face's own signs: times, divide, degree. Its middle dot is a speck, so `signs` draws one.
    static let greekSigns = zipped("×÷°", "jvV")
    /// Superscripts and subscripts, written as raised and lowered runs of their plain characters.
    static let raised = zipped("⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱ", "0123456789+−=()ni")
    static let lowered = zipped("₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎", "0123456789+−=()")
    /// Typography the way a pen writes it. Spaces, vulgar fractions and accented letters are handled in `writable`.
    static let plain: [Character: String] = [
        "‘": "'", "’": "'", "‚": "'", "‛": "'", "′": "'", "“": "\"", "”": "\"", "„": "\"", "‟": "\"", "″": "''",
        "…": "...", "•": "-", "‐": "-", "‑": "-", "⁄": "/", "℃": "°C", "℉": "°F",
    ]
    /// Maths signs drawn for the faces, as letter pairs like the .jhf records (see `Hershey.glyph`). Operators centre on
    /// y 0 like the faces' + and =.
    static let signs: [Character: String] = [
        "−": #"E_IR[R"#,  // minus, as long as +
        "±": #"E_RHRV RIO[O RI[[["#,
        "≠": #"E_IO[O RIU[U RVIN["#,
        "≈": #"E_IPJNLMNMPNTPVQXQZP[N RIVJTLSNSPTTVVWXWZV[T"#,
        "≤": #"F^ZHJOZV RJ[Z["#,
        "≥": #"F^JHZOJV RJ[Z["#,
        // ponytail: the roof covers part of the next glyph, like a typed √, so √49 roofs the 4 only; stretch it over the
        // digits, letters or bracket after it if answers need it.
        "√": #"GWHRKPP[WDaD"#,
        "→": #"D`GR]R RXM]RXW"#,
        "←": #"D`GR]R RLMGRLW"#,
        "⇒": #"D`GOZO RGUZU RVJ]RVZ"#,
        "∞": #"E_RRTOVNXNZO[Q[SZUXVVVTURRPONNLNJOIQISJULVNVPURR"#,
        "∫": #"I[ZEYCWBUCTESJQZP_OaMbKaJ_"#,
        "–": #"E_HR\R"#,
        "—": #"?eBRbR"#,
        "∈": #"G]YKUKRLONMPLRMTOVRXUYYY RLRWR"#,
        "∠": #"F^ZJJ[[["#,
        "∟": #"F^JIJ[[["#,
        "⊥": #"F^RHR[ RI[[["#,
        "⟂": #"F^RHR[ RI[[["#,
        "∥": #"JZOEO_ RUEU_"#,
        "∴": #"I[RNQORPSORN RMYLZM[NZMY RWYVZW[XZWY"#,
        "·": #"NVRQQRRSSRRQ"#,  // the period's dot, on the axis
        "⋅": #"NVRQQRRSSRRQ"#,
    ]

    init(latin: Hershey, greek: Hershey) {
        func glyph(_ face: Hershey, _ c: Character) -> Hershey.Glyph? {
            let i = Int(c.asciiValue ?? 0) - 32
            return face.glyphs.indices.contains(i) ? face.glyphs[i] : nil
        }
        var glyphs: [Character: Hershey.Glyph] = [:]
        for ascii in UInt8(32) ... 126 { glyphs[Character(UnicodeScalar(ascii))] = glyph(latin, Character(UnicodeScalar(ascii))) }
        glyphs["\u{00A0}"] = glyphs[" "]  // the space in 1 1/2, which wrap keeps
        for (c, at) in Self.letters { glyphs[c] = glyph(greek, at).map { at.isLowercase ? Self.scaled($0, Self.greekSize) : $0 } }
        for (c, at) in Self.greekSigns { glyphs[c] = glyph(greek, at) }
        for (c, pairs) in Self.signs { glyphs[c] = Hershey.glyph(pairs) }
        self.glyphs = glyphs
    }

    /// `text` as this pen writes it, or nil if any character has no glyph (emoji, CJK, most maths) or there is nothing
    /// to write. Curly quotes, ellipses, bullets, odd spaces and vulgar fractions become plain, a letter in a word loses
    /// its accent (café is cafe), and line breaks are kept. Nothing is dropped or swapped silently: a lone ŷ is maths, so
    /// like x̄ it is nil.
    func writable(_ text: String) -> String? {
        let chars = Array(text.precomposedStringWithCanonicalMapping)
        var out = ""
        for (i, c) in chars.enumerated() {
            let parts = String(c).decomposedStringWithCompatibilityMapping  // ½ is 1⁄2
            if c.isNewline { out.append("\n") }
            else if c.isWhitespace { out.append(" ") }
            else if glyphs[c] != nil || Self.raised[c] != nil || Self.lowered[c] != nil { out.append(c) }
            else if let s = Self.plain[c] { out += s }
            else if parts.contains("⁄") {  // after a number its space holds (1½ is 1 1/2); after a caret it keeps brackets
                let fraction = parts.replacingOccurrences(of: "⁄", with: "/")
                out += out.last == "^" ? "(\(fraction))" : (out.last?.isNumber == true ? "\u{00A0}" : "") + fraction
            }
            // é is e beside another letter. Latin-ASCII also turns ℝ into R and × into *, so only single Latin letters go
            // through it. ponytail: a letter beside it makes a word, so dŷ/dx would lose its hat; tell maths apart if needed.
            else if [i - 1, i + 1].contains(where: { chars.indices.contains($0) && chars[$0].isLetter }), c.unicodeScalars.count == 1,
                    (try? /\p{Script=Latin}/.wholeMatch(in: String(c))) != nil,
                    let s = String(c).applyingTransform(StringTransform("Latin-ASCII"), reverse: false), s.allSatisfy({ $0.isASCII && $0.isLetter }) {
                out += s
            }
            else { return nil }
        }
        // Every character drawn has a glyph, so ℃ without the Greek face's ° is nil rather than C.
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "\n" || glyphs[Self.raised[$0] ?? Self.lowered[$0] ?? $0] != nil }) else { return nil }
        return trimmed
    }

    /// Word wrap of `writable` text at `width`, keeping its line breaks. Each paragraph is wrapped as evenly as it
    /// can be in as few lines as greedy filling needs, so no word is left alone on a last line. With more than one
    /// paragraph it reads as a list: items get a little space between them and their wrapped lines hang in. A word
    /// wider than the width keeps a line to itself; words are never split.
    func wrap(_ text: String, cap: CGFloat, width: CGFloat) -> [Line] {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)
        let list = paragraphs.filter { !$0.allSatisfy(\.isWhitespace) }.count > 1, hang = list ? Self.hang : 0
        var lines: [Line] = []
        for paragraph in paragraphs {
            let words = Self.words(paragraph), rows = fill(words, cap: cap, width: width, hang: hang)
            var even = rows
            if rows.count > 1 {  // the narrowest width that still needs no more lines
                var low = words.map { self.width($0, cap: cap) }.max() ?? 0, high = width
                while high - low > 0.5 {
                    let mid = (low + high) / 2
                    if fill(words, cap: cap, width: mid, hang: hang).count <= rows.count { high = mid } else { low = mid }
                }
                even = fill(words, cap: cap, width: high, hang: hang)
            }
            for (i, row) in even.enumerated() {
                lines.append(Line(row, above: i == 0 && list && !lines.isEmpty ? Self.itemGap : 0, indent: i > 0 ? hang : 0))
            }
        }
        while lines.last?.text.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Greedy filling of `words` into rows `width` wide, the rows after the first `hang` capitals narrower.
    private func fill(_ words: [String], cap: CGFloat, width: CGFloat, hang: CGFloat) -> [String] {
        var rows: [String] = [], row = ""
        for word in words {
            let candidate = row.isEmpty ? word : row + " " + word
            if row.isEmpty || self.width(candidate, cap: cap) <= width - (rows.isEmpty ? 0 : hang * cap) { row = candidate }
            else { rows.append(row); row = word }
        }
        rows.append(row)
        return rows
    }

    /// A paragraph's words: split at spaces, but not inside a power's brackets, so x^(n + 1) keeps to one line.
    static func words(_ paragraph: Substring) -> [String] {
        let chars = Array(paragraph)
        var words = [""], i = 0
        while i < chars.count {
            let end = chars[i] == "^" && i + 1 < chars.count && chars[i + 1] == "(" ? close(chars, i + 1) ?? i + 1 : i + 1
            if chars[i] == " " { words.append("") } else { words[words.count - 1] += String(chars[i ..< end]) }
            i = end
        }
        var kept: [String] = []
        for word in words where !word.isEmpty {
            let unit = String(word.reversed().drop { ".,;:!?)".contains($0) }.reversed())
            if let number = kept.last, number.contains(where: \.isNumber), number.allSatisfy({ $0.isNumber || ".,".contains($0) }), units.contains(unit) {
                kept[kept.count - 1] += " " + word
            } else {
                kept.append(word)
            }
        }
        return kept
    }

    /// The ink's bounds, from the first line's capital top-left: tall glyphs reach above y 0, and the last line's
    /// descenders are included. Measured from the written points, so it is tight.
    func extent(_ lines: [Line], cap: CGFloat) -> CGRect {
        let points = pen(lines, at: .zero, cap: cap).joined(), xs = points.map(\.x), ys = points.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Pen lines for wrapped lines whose first capital top-left is at `origin`: left to right, line by line, each
    /// with its own space above and indent.
    func pen(_ lines: [Line], at origin: CGPoint, cap: CGFloat) -> [[CGPoint]] {
        var out: [[CGPoint]] = [], baseline = origin.y + cap
        for (i, line) in lines.enumerated() {
            if i > 0 { baseline += (Self.lineGap + line.above) * cap }
            var x = origin.x + line.indent * cap
            for (g, size, lift) in layout(line.text) {
                let k = cap / 21 * size, y = baseline - lift * cap
                out += g.lines.map { $0.map { CGPoint(x: x + ($0.x - g.left) * k, y: y + ($0.y - 9) * k) } }
                x += (g.right - g.left) * k
            }
        }
        return out
    }

    /// How far a line advances.
    func width(_ line: String, cap: CGFloat) -> CGFloat {
        layout(line).reduce(0) { $0 + ($1.glyph.right - $1.glyph.left) * cap / 21 * $1.size }
    }

    /// A line's glyphs in writing order, with their size and baseline lift in capitals.
    func layout(_ line: String) -> [(glyph: Hershey.Glyph, size: CGFloat, lift: CGFloat)] {
        var out: [(glyph: Hershey.Glyph, size: CGFloat, lift: CGFloat)] = []
        for run in Self.runs(line) {
            let size = run.level == 0 ? 1 : Self.small, lift = run.level > 0 ? Self.raise : run.level < 0 ? -Self.drop : 0
            out += run.text.compactMap { glyphs[$0] }.map { ($0, size, lift) }
        }
        return out
    }

    struct Run: Equatable {
        var text: String
        var level = 0  // 1 raised, -1 lowered
    }

    /// One line's runs: superscripts, and what follows the caret in `x^2`, `e^(-2r)` and `10^-3` (without the caret or
    /// brackets), are raised; subscripts, as in H₂O, are lowered.
    static func runs(_ line: String) -> [Run] {
        var runs: [Run] = [], chars = Array(line), i = 0
        func add(_ c: Character, _ level: Int) {
            if runs.last?.level == level { runs[runs.count - 1].text.append(c) } else { runs.append(Run(text: String(c), level: level)) }
        }
        func marked(_ c: Character) -> Bool { raised[c] != nil || lowered[c] != nil }
        while i < chars.count {
            let c = chars[i]
            i += 1
            if let r = raised[c] { add(r, 1); continue }
            if let l = lowered[c] { add(l, -1); continue }
            guard c == "^", i < chars.count else { add(c, 0); continue }
            var power = "", j = i
            if chars[j] == "(" {
                if let end = close(chars, j) { power = String(chars[j + 1 ..< end - 1]); j = end }
            } else {
                if "+-−".contains(chars[j]) { power.append(chars[j]); j += 1 }
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "." && j + 1 < chars.count && chars[j + 1].isNumber {
                    power.append(chars[j])
                    j += 1
                }
            }
            // ponytail: one level only. A caret stays a caret when nothing follows it, when its bracket never closes, or
            // when raising it would merge it with another raised or lowered run: e^x², x²^3, 2^3^2 and e^(−x²/2) are
            // written as typed, never as something else. Nest levels if answers need it.
            let next = j < chars.count ? chars[j] : " "
            if power.isEmpty || runs.last?.level == 1 || next == "^" || marked(next) || power.contains(where: marked) {
                add(c, 0)
                continue
            }
            for p in power { add(p, 1) }
            i = j
        }
        return runs
    }

    /// Past the bracket that closes the one at `i`, or nil if it never closes.
    static func close(_ chars: [Character], _ i: Int) -> Int? {
        var depth = 0
        for j in i ..< chars.count {
            if chars[j] == "(" { depth += 1 } else if chars[j] == ")" { depth -= 1; if depth == 0 { return j + 1 } }
        }
        return nil
    }

    /// `g` scaled by `s` about its baseline.
    static func scaled(_ g: Hershey.Glyph, _ s: CGFloat) -> Hershey.Glyph {
        Hershey.Glyph(left: g.left * s, right: g.right * s, lines: g.lines.map { $0.map { CGPoint(x: $0.x * s, y: 9 + ($0.y - 9) * s) } })
    }

    static func zipped(_ keys: String, _ values: String) -> [Character: Character] {
        precondition(keys.count == values.count, "zipped tables pair up")
        return Dictionary(uniqueKeysWithValues: zip(keys, values))
    }
}
