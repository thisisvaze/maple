// swiftc -swift-version 6 -parse-as-library Maple/Hershey.swift Maple/Handwriting.swift checks/handwriting-check.swift -o /tmp/handwriting-check && /tmp/handwriting-check
import CoreGraphics
import Foundation

@main
struct Check {
    typealias Run = Handwriting.Run

    static func main() throws {
        let traced = Hershey(traced: try Data(contentsOf: URL(fileURLWithPath: "Maple/hand.json")))
        let greek = Hershey(try String(contentsOfFile: "Maple/greek.jhf", encoding: .ascii))
        precondition(traced.glyphs.count == 95 && greek.glyphs.count == 96, "the faces load")
        precondition(Hershey(traced: Data()).glyphs.isEmpty && Handwriting(latin: Hershey(traced: Data()), greek: greek).writable("hi") == nil,
                     "a missing hand writes nothing, so answers stay a quiet dot")
        let hand = Handwriting(latin: traced, greek: greek), cap: CGFloat = 12
        func ink(_ text: String) -> [[CGPoint]] { hand.pen(hand.wrap(hand.writable(text)!, cap: cap, width: 1000), at: .zero, cap: cap) }

        // The period of 2.5 sits on the baseline (y 21 at a 21 capital), not at mid height like a times dot.
        let labelDot = traced.lines("2.5", at: .zero, height: 21)[traced.lines("2", at: .zero, height: 21).count]
        let answerDot = hand.pen(["2.5"], at: .zero, cap: 21)[hand.pen(["2"], at: .zero, cap: 21).count]
        for dot in [labelDot, answerDot] {
            precondition(abs(dot.map(\.y).max()! - 21) <= 0.5 && dot.map(\.y).min()! > 17, "the period floats: \(dot)")
        }

        // Written exactly as given: typography made plain, accents dropped in words, every maths sign kept. A mixed number's
        // space holds, and a fraction after a caret keeps its brackets.
        for (text, writable) in [("x = ±7", "x = ±7"), ("x ≠ 3", "x ≠ 3"), ("π ≈ 3.14", "π ≈ 3.14"), ("θ = 30°", "θ = 30°"),
                                 ("√2", "√2"), ("H₂O", "H₂O"), ("x²", "x²"), ("10⁻³", "10⁻³"), ("a → b", "a → b"), ("café", "cafe"),
                                 ("naïve Straße", "naive Strasse"), ("“quoted” — dash…", "\"quoted\" — dash..."), ("½", "1/2"),
                                 ("1½ cups", "1\u{00A0}1/2 cups"), ("x^½", "x^(1/2)"), ("f′(x)", "f'(x)"), ("x‑axis, well‐known", "x-axis, well-known"),
                                 (" x\u{00A0}=\u{2009}1\r\ny \n", "x = 1\ny")] {
            precondition(hand.writable(text) == writable, "writable(\(text)) = \(String(describing: hand.writable(text)))")
        }
        precondition(ink("x = ±7") != ink("x = +7") && ink("x ≠ 3") != ink("x = 3"), "± and ≠ keep their own glyphs")
        for (sign, letter) in [("\u{2126}", "Ω"), ("µ", "μ"), ("∑", "Σ"), ("∏", "Π"), ("∂", "δ"), ("ϑ", "θ"), ("∆", "Δ")] {
            precondition(ink(sign) == ink(letter), "\(sign) writes as \(letter)")
        }
        // Nothing unwritable is dropped or swapped: emoji, CJK, an unsupported sign, a combining bar, ℝ (not R), a lone
        // hatted y (not y), the ångström sign (not A).
        for text in ["✨ done", "日本", "∮ f dz", "x\u{0304}", "x ∈ ℝ", "ŷ = 2x + 1", "1.5 \u{212B}", "   "] {
            precondition(hand.writable(text) == nil, "\(text) is not writable")
        }
        let latinOnly = Handwriting(latin: traced, greek: Hershey(""))  // a bundle without greek.jhf
        precondition(latinOnly.writable("don't") == "don't" && latinOnly.writable("π") == nil && latinOnly.writable("25 ℃") == nil,
                     "without the Greek face, Greek and ° wait")

        // Powers raise, smaller; subscripts drop below the baseline.
        precondition(Handwriting.runs("x²") == [Run(text: "x"), Run(text: "2", level: 1)])
        precondition(Handwriting.runs("10⁻³") == [Run(text: "10"), Run(text: "−3", level: 1)])
        precondition(Handwriting.runs("H₂O") == [Run(text: "H"), Run(text: "2", level: -1), Run(text: "O")])
        precondition(ink("x²").last!.map(\.y).max()! < cap * 0.6, "the power sits above the baseline")
        precondition(ink("H₂O").joined().map(\.y).max()! > cap * 1.2, "the subscript drops below the baseline")
        precondition(Handwriting.runs("x^2 + e^(-2r)") == [Run(text: "x"), Run(text: "2", level: 1), Run(text: " + e"), Run(text: "-2r", level: 1)])
        precondition(Handwriting.runs("1.5^2.5x") == [Run(text: "1.5"), Run(text: "2.5x", level: 1)])
        precondition(Handwriting.runs("a ^ b") == [Run(text: "a ^ b")] && Handwriting.runs("f^()") == [Run(text: "f^()")], "a lone caret is a caret")
        precondition(Handwriting.runs("2^(3^2)") == [Run(text: "2"), Run(text: "3^2", level: 1)], "nested brackets stay whole")
        // One level only: a caret that would hide a superscript, subscript or another power stays a caret.
        precondition(Handwriting.runs("e^(−x²/2)") == [Run(text: "e^(−x"), Run(text: "2", level: 1), Run(text: "/2)")])
        precondition(Handwriting.runs("e^(x₁ + x₂)") == [Run(text: "e^(x"), Run(text: "1", level: -1), Run(text: " + x"), Run(text: "2", level: -1), Run(text: ")")])
        precondition(Handwriting.runs("e^x² + 2^3^2 + x²^3") == [Run(text: "e^x"), Run(text: "2", level: 1), Run(text: " + 2^3"), Run(text: "2", level: 1),
                                                                 Run(text: " + x"), Run(text: "2", level: 1), Run(text: "^3")])
        precondition(Handwriting.runs("x^(n") == [Run(text: "x^(n")], "an open bracket keeps its caret")

        // Every character the tables accept writes ink.
        let accepted = Array(hand.glyphs.keys) + Array(Handwriting.raised.keys) + Array(Handwriting.lowered.keys) + Array(Handwriting.plain.keys)
        for c in accepted where !c.isWhitespace {
            precondition(!ink(String(c)).isEmpty, "no ink for \(c)")
        }

        // Wrapping keeps every word in order within the width, and the ink stays inside its extent.
        let reply = hand.writable("Yeast breathes out CO₂ as it feeds; the gluten traps the gas, so the dough rises about 2× in 1½ hours (at 25 °C).")!
        for width: CGFloat in [60, 140, 300, 2000] {
            let lines = hand.wrap(reply, cap: cap, width: width)
            precondition(lines.map(\.text).joined(separator: " ").split(separator: " ") == reply.split(separator: " "), "wrap keeps every word in order")
            for line in lines where line.text.contains(" ") {
                precondition(hand.width(line.text, cap: cap) <= width + 0.001, "line wider than \(width): \(line)")
            }
            let origin = CGPoint(x: 100, y: 50), box = hand.extent(lines, cap: cap).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -0.001, dy: -0.001)
            let pen = hand.pen(lines, at: origin, cap: cap)
            precondition(!pen.isEmpty && pen.allSatisfy { $0.allSatisfy(box.contains) }, "ink outside its extent at width \(width)")
        }
        precondition(hand.wrap("a supercalifragilistic b", cap: cap, width: 20).map(\.text) == ["a", "supercalifragilistic", "b"], "a long word keeps its own line")
        precondition(hand.wrap(hand.writable("one\ntwo\n\nthree")!, cap: cap, width: 999).map(\.text) == ["one", "two", "", "three"], "line breaks are kept")

        // Muse's real Lisbon reply (2 Nov), at about the width Room gave it: greedy filling left "well.", "needed" and
        // "by 6pm" alone. Each item now wraps evenly in the same number of lines, items have space between them, and an
        // item's wrapped lines hang in; one paragraph is plain prose, without either.
        let plan = hand.writable("Yes - perfect Friday day trip, fits your plan well.\nEarly train Rossio to Sintra, ~40min, no car needed\nBook Pena Palace 9:30am slot first, then Moorish Castle\nLunch in town, Quinta da Regaleira after, back by 6pm")!
        let items = hand.wrap(plan, cap: 24, width: 640)
        precondition(items.count == 8 && items.allSatisfy { $0.text.split(separator: " ").count >= 3 }, "no word left alone: \(items.map(\.text))")
        precondition(items.enumerated().allSatisfy { i, line in i % 2 == 0 ? line.indent == 0 && line.above == (i == 0 ? 0 : Handwriting.itemGap) : line.indent == Handwriting.hang && line.above == 0 },
                     "items spaced, their second lines hung in: \(items)")
        let pairs = stride(from: 0, to: items.count, by: 2).map { (hand.width(items[$0].text, cap: 24), hand.width(items[$0 + 1].text, cap: 24)) }
        precondition(pairs.allSatisfy { min($0.0, $0.1) > 0.5 * max($0.0, $0.1) }, "an item's lines are about as long as each other: \(pairs)")
        let prose = hand.wrap(reply, cap: cap, width: 140)
        precondition(prose.allSatisfy { $0.above == 0 && $0.indent == 0 } && prose.last!.text.contains(" "), "one paragraph is prose, evenly wrapped: \(prose.map(\.text))")
        let ink = hand.extent(items, cap: 24), flat = hand.extent(items.map { Handwriting.Line($0.text) }, cap: 24)
        precondition(ink.height > flat.height + 2 * Handwriting.itemGap * 24, "item gaps add height the extent sees, so Room makes room for them")
        // A power's brackets and a mixed number never break across lines.
        precondition(Handwriting.words("of x^(n + 1) is") == ["of", "x^(n + 1)", "is"] && Handwriting.words("x^(n + 1 is") == ["x^(n", "+", "1", "is"])
        precondition(Handwriting.words("= 300 cm = 3.0 m, so your 3.2 m wall, 20 cm left, 2 rooms") == ["=", "300 cm", "=", "3.0 m,", "so", "your", "3.2 m", "wall,", "20 cm", "left,", "2", "rooms"],
                     "a number keeps its unit")
        let power = hand.writable("The derivative of x^(n + 1) is (n + 1)x^n, about 2½ times.")!
        for width in stride(from: CGFloat(30), through: 300, by: 3) {
            let lines = hand.wrap(power, cap: cap, width: width)
            precondition(lines.contains { $0.text.contains("x^(n + 1)") } && lines.contains { $0.text.contains("2\u{00A0}1/2") }, "split at \(width): \(lines)")
        }

        // The extent is the ink's own (capitals 21 tall, so glyph units): an x starts at the x-height, a g's descender,
        // a root's roof and a second line count.
        let x = hand.extent(["x"], cap: 21), hg = hand.extent(["Hg"], cap: 21)
        precondition(x.minY > 4 && abs(x.maxY - 21) < 0.5 && x.minX >= 0, "an x stands on the baseline, below the capitals: \(x)")
        precondition(abs(hg.minY) < 1 && hg.maxY > 25, "a capital reaches the top, a descender drops below the baseline: \(hg)")
        precondition(hand.extent(["√2"], cap: 21).minY < hg.minY, "a root's roof reaches above the capitals")
        precondition(abs(hand.extent(["x", "x"], cap: 21).maxY - (21 * Handwriting.lineGap + x.maxY)) < 0.001, "two lines")
        precondition(hand.extent([], cap: cap) == .zero)
        print("handwriting ok")
    }
}
