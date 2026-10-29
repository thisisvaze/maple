// swiftc -swift-version 6 -parse-as-library Maple/Drawing.swift Maple/Hershey.swift checks/drawing-check.swift -o /tmp/drawing-check && /tmp/drawing-check
import CoreGraphics
import Foundation

@main
struct Check {
    static func main() throws {
        // The grammar: precedence, right-associative powers, unary minus, functions, constants.
        let values = try [("x^2 - 3*x + 2", 1.0), ("2^3^2", 0), ("-x^2", 3), ("sin(pi/2) + cos(0) + sqrt(16) + abs(-1) + log(e) + exp(0)", 0), ("1.5e2/(x+1)", 2)]
            .map { try Plot.function($0.0)($0.1) }
        precondition(values[0] == 0 && values[1] == 512 && values[2] == -9, "precedence: \(values)")
        precondition(abs(values[3] - 9) < 1e-12 && values[4] == 50, "functions and numbers: \(values)")
        for bad in ["x;1", "2x", "foo(x)", "x +", "(x", "sin x", "x^^2", String(repeating: "(", count: 40) + "x"] {
            precondition((try? Plot.function(bad)) == nil, "rejects \(bad)")
        }

        let box = CGSize(width: 300, height: 200), inside = CGRect(origin: .zero, size: box)
        let font = Hershey(try String(contentsOfFile: "Maple/futural.jhf", encoding: .ascii))
        precondition(font.glyphs.count == 96 && !font.lines("y = x", at: .zero, height: 10).isEmpty, "Hershey font")

        // A graph: two axes, then the curve, split at the asymptote of 1/x.
        let sine = try Plot.graph(.init(expression: "sin(x)", xMin: -6.3, xMax: 6.3, yMin: -1.5, yMax: 1.5), in: box)
        precondition(sine.lines.count == 3 && sine.lines.allSatisfy { $0.allSatisfy { inside.insetBy(dx: -0.01, dy: -0.01).contains($0) } }, "sine")
        let hyperbola = try Plot.graph(.init(expression: "1/x", xMin: -3, xMax: 3, yMin: -5, yMax: 5), in: box)
        precondition(hyperbola.lines.count == 4, "1/x splits in two: \(hyperbola.lines.count)")
        precondition((try? Plot.graph(.init(expression: "x", xMin: 1, xMax: 0, yMin: 0, yMax: 1), in: box)) == nil, "bad range")
        precondition((try? Plot.graph(.init(expression: "x", xMin: 0, xMax: 1, yMin: 0, yMax: 1), in: CGSize(width: 40, height: 40))) == nil, "tiny box")

        // Ink from the model: invalid points dropped, the rest clamped into the box, labels written in the pen font.
        let json = #"""
        {"reading": "triangle", "kind": "ink", "say": "A triangle", "plot": {"expression": "", "xMin": 0, "xMax": 1, "yMin": 0, "yMax": 1},
         "strokes": [[[20, 180], [150, 20], [280, 180], [20, 180]], [[10, 10], [999, -5], [1]]],
         "labels": [{"text": "A", "x": 10, "y": 185, "size": 12}]}
        """#
        let drawing = try JSONDecoder().decode(Drawing.self, from: Data(json.utf8))
        let lines = try drawing.lines(in: box, font: font)
        precondition(lines.count >= 3 && lines[1] == [CGPoint(x: 10, y: 10), CGPoint(x: 300, y: 0)], "clamped: \(lines[1])")
        precondition(lines.allSatisfy { $0.allSatisfy { inside.insetBy(dx: -0.01, dy: -0.01).contains($0) } }, "inside, edges included")
        print("drawing ok")
    }
}
