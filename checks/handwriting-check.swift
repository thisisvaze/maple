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
            precondition(lines.joined(separator: " ").split(separator: " ") == reply.split(separator: " "), "wrap keeps every word in order")
            for line in lines where line.contains(" ") {
                precondition(hand.width(line, cap: cap) <= width + 0.001, "line wider than \(width): \(line)")
            }
            let origin = CGPoint(x: 100, y: 50), box = hand.extent(lines, cap: cap).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -0.001, dy: -0.001)
            let pen = hand.pen(lines, at: origin, cap: cap)
            precondition(!pen.isEmpty && pen.allSatisfy { $0.allSatisfy(box.contains) }, "ink outside its extent at width \(width)")
        }
        precondition(hand.wrap("a supercalifragilistic b", cap: cap, width: 20) == ["a", "supercalifragilistic", "b"], "a long word keeps its own line")
        precondition(hand.wrap(hand.writable("one\ntwo\n\nthree")!, cap: cap, width: 999) == ["one", "two", "", "three"], "line breaks are kept")
        // A power's brackets and a mixed number never break across lines.
        precondition(Handwriting.words("of x^(n + 1) is") == ["of", "x^(n + 1)", "is"] && Handwriting.words("x^(n + 1 is") == ["x^(n", "+", "1", "is"])
        let power = hand.writable("The derivative of x^(n + 1) is (n + 1)x^n, about 2½ times.")!
        for width in stride(from: CGFloat(30), through: 300, by: 3) {
            let lines = hand.wrap(power, cap: cap, width: width)
            precondition(lines.contains { $0.contains("x^(n + 1)") } && lines.contains { $0.contains("2\u{00A0}1/2") }, "split at \(width): \(lines)")
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
