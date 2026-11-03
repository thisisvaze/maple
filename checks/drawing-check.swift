// swiftc -swift-version 6 -parse-as-library Maple/{Drawing,Figure,Computed,Hershey}.swift checks/drawing-check.swift -o /tmp/drawing-check && /tmp/drawing-check
import CoreGraphics
import Foundation
import ImageIO

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
        let font = Hershey(traced: try Data(contentsOf: URL(fileURLWithPath: "Maple/hand.json")))
        precondition(font.glyphs.count == 95 && !font.lines("y = x", at: .zero, height: 10).isEmpty, "the pen face")

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

        // That JSON is a drawing saved before parts: its strokes and labels are one part, named "drawing".
        precondition(drawing.parts.count == 1 && drawing.parts[0].name == "drawing" && drawing.parts[0].strokes.count == 2
                     && drawing.parts[0].labels.map(\.text) == ["A"], "legacy: \(drawing.parts)")
        // Parts read back as written, and only parts are written.
        let sorted = JSONEncoder()
        sorted.outputFormatting = .sortedKeys
        func encoded(_ value: some Encodable) -> String { String(decoding: try! sorted.encode(value), as: UTF8.self) }
        let saved = try JSONSerialization.jsonObject(with: try sorted.encode(drawing)) as! [String: Any]
        precondition(saved["parts"] != nil && saved["strokes"] == nil && saved["labels"] == nil, "writes parts only: \(saved.keys)")
        let reread = try JSONDecoder().decode(Drawing.self, from: try sorted.encode(drawing))
        precondition(encoded(reread) == encoded(drawing), "round trip")

        // An edit patches parts by name, trimmed and in any case: it replaces one, adds one, removes one with an empty
        // part, and leaves the rest. An empty plot expression and say keep their own; others replace them.
        func part(_ name: String, _ x: Double, label: String? = nil) -> Drawing.Part {
            Drawing.Part(name: name, strokes: [[[x, 10], [x + 20, 30]]], labels: label.map { [Drawing.Label(text: $0, x: x, y: 40, size: 10)] } ?? [])
        }
        let graph = Drawing.Graph(expression: "x", xMin: 0, xMax: 1, yMin: 0, yMax: 1), none = Drawing.Graph(expression: " ", xMin: 0, xMax: 0, yMin: 0, yMax: 0)
        let login = Drawing(reading: "login", kind: "ink", say: "A login screen", parts: [part("Title", 10), part("Email field", 50), part("Sign In Button", 90, label: "Sign in")], plot: graph)
        let edited = login.patched(parts: [part(" sign in button ", 95, label: "Log in"), part("forgot link", 130),
                                           Drawing.Part(name: "EMAIL FIELD", strokes: [], labels: []), Drawing.Part(name: "nothing", strokes: [], labels: [])],
                                   plot: none, say: "")
        precondition(edited.parts.map(\.name) == ["Title", " sign in button ", "forgot link"], "patched names: \(edited.parts.map(\.name))")
        let button = part(" sign in button ", 95, label: "Log in")
        precondition(encoded(edited.parts[0]) == encoded(login.parts[0]), "the title stays")
        precondition(encoded(edited.parts[1]) == encoded(button), "the button is replaced")
        precondition(encoded(edited.plot) == encoded(graph) && edited.say == "A login screen", "an empty plot and say keep their own")
        let replotted = login.patched(parts: [], plot: Drawing.Graph(expression: "x^2", xMin: -2, xMax: 2, yMin: 0, yMax: 4), say: "A parabola")
        precondition(replotted.plot.expression == "x^2" && replotted.plot.xMin == -2 && replotted.say == "A parabola" && encoded(replotted.parts) == encoded(login.parts),
                     "a plot and say replace their own; parts stay")
        precondition(login.patched(parts: login.parts.map { Drawing.Part(name: $0.name, strokes: [], labels: []) }, plot: none, say: "").blank, "all gone")
        precondition(!Drawing(reading: "", kind: "plot", say: "", parts: [], plot: graph).blank, "a plot draws itself")
        // A plot draws its parts over the graph: what an edit marks on it, like its roots.
        let parabola = Drawing(reading: "", kind: "plot", say: "", parts: [], plot: .init(expression: "x^2 - 4", xMin: -3, xMax: 3, yMin: -5, yMax: 6))
        let roots = Drawing.Part(name: "roots", strokes: [[[96, 150], [104, 158]]], labels: [Drawing.Label(text: "I", x: 90, y: 162, size: 10)])
        let (bare, marked) = (try parabola.lines(in: box, font: font), try parabola.patched(parts: [roots], plot: none, say: "").lines(in: box, font: font))
        precondition(marked.count == bare.count + 2 && marked.contains([CGPoint(x: 96, y: 150), CGPoint(x: 104, y: 158)]), "a plot's parts: \(bare.count) \(marked.count)")

        // The caps hold across all parts together: 256 strokes, 12000 points, 64 labels.
        let many = (0 ..< 3).map { Drawing.Part(name: "p\($0)", strokes: Array(repeating: [[0, 0], [10, 10]], count: 100), labels: []) }
        func ink(_ parts: [Drawing.Part]) throws -> [[CGPoint]] { try Drawing(reading: "", kind: "ink", say: "", parts: parts, plot: graph).lines(in: box, font: font) }
        let strokes = try ink(many).count
        precondition(strokes == 256, "256 strokes: \(strokes)")
        let long = (0 ..< 2).map { Drawing.Part(name: "p\($0)", strokes: [(0 ..< 7000).map { [Double($0 % 300), 1] }], labels: []) }
        let points = try ink(long).joined().count
        precondition(points == 12_000, "12000 points: \(points)")
        precondition(font.lines("I", at: .zero, height: 10).count == 1, "an I is one line")
        let labelled = (0 ..< 3).map { n in Drawing.Part(name: "p\(n)", strokes: [], labels: (0 ..< 30).map { Drawing.Label(text: "I", x: CGFloat($0) * 9, y: CGFloat(n) * 20, size: 10) }) }
        let labels = try ink(labelled).count
        precondition(labels == 64, "64 labels: \(labels)")
                // Formulas take the caller's variables, and two-argument functions.
        let wave = try Plot.expression("sin(x)*max(y, 2) + atan2(0, 1) + hypot(3, 4)", variables: ["x", "y"])
        precondition(abs(wave([.pi / 2, 1]) - 7) < 1e-12)
        for bad in ["z + 1", "max(1)", "atan2(1 2)"] {
            do { _ = try Plot.expression(bad, variables: ["x"]); preconditionFailure(bad) } catch {}
        }

        // A figure's ink has true proportions in any box, however Muse's numbers fall, and its labels are measured.
        func triangle(_ c: String = "5") -> Figure {
            Figure(points: [.init(name: "A", x: "0", y: "0", label: true), .init(name: "B", x: "ax + 4", y: "0", label: true), .init(name: "C", x: "bx", y: "3", label: true)],
                   lines: [["A", "B", "C", "A"]],
                   lengths: [.init(from: "A", to: "B", expected: "4", unit: "cm"), .init(from: "B", to: "C", expected: "3", unit: "cm"), .init(from: "C", to: "A", expected: c, unit: "cm")],
                   angles: [.init(vertex: "B", from: "A", to: "C", expected: "90")])
        }
        for size in [CGSize(width: 300, height: 300), CGSize(width: 640, height: 180), CGSize(width: 150, height: 420)] {
            let lines = try triangle().lines(in: size, font: .pen), sides = lines.prefix(3).map { hypot($0[1].x - $0[0].x, $0[1].y - $0[0].y) }
            precondition(abs(sides[0] / sides[1] - 4.0 / 3) < 1e-9 && abs(sides[2] / sides[1] - 5.0 / 3) < 1e-9, "a 3-4-5 triangle stays 3-4-5")
            precondition(lines.allSatisfy { $0.allSatisfy { CGRect(origin: .zero, size: size).insetBy(dx: -30, dy: -30).contains($0) } }, "it fits its box")
        }
        do { try triangle("6").check(); preconditionFailure("a side that doesn't measure up fails") } catch {}
        var frame = Figure(points: [.init(name: "B", x: "0", y: "0", label: false), .init(name: "S", x: "bx - 50*cos(73*pi/180)", y: "50*sin(73*pi/180)", label: false),
                                    .init(name: "R", x: "-40", y: "0", label: false)],
                           lines: [["R", "B", "S"]], circles: [.init(center: "R", radius: "33.4")], angles: [.init(vertex: "B", from: "R", to: "S", expected: "73")])
        try frame.check()
        let leaning = try Figure.angle(frame.angles[0], frame.solved())
        precondition(abs(leaning - 73) < 1e-9, "the seat tube leans at 73 degrees")
        frame.angles[0].expected = "100"
        do { try frame.check(); preconditionFailure("an angle that doesn't measure up fails") } catch {}
        var twice = triangle()
        twice.points[1].name = "a"
        do { _ = try twice.solved(); preconditionFailure("a name used twice fails") } catch {}

        // A computed picture is worked out: hydrogen's 1s density is darkest at the nucleus, a wave swings both ways, and the
        // flow of a rigid turn traces true circles.
        func pixels(_ png: Data) -> (image: CGImage, bytes: [UInt8]) {
            let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)!
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return (image, bytes)
        }
        func colour(_ p: (image: CGImage, bytes: [UInt8]), _ x: Int, _ y: Int) -> [UInt8] { Array(p.bytes[(y * p.image.width + x) * 4 ..< (y * p.image.width + x) * 4 + 3]) }
        let pictureBox = CGSize(width: 300, height: 200)
        let hydrogen = pixels(try Computed(field: "exp(-2*sqrt(x^2 + y^2))", xMin: -4, xMax: 4, yMin: -3, yMax: 3).raster(in: pictureBox))
        precondition(hydrogen.image.width == 600 && hydrogen.image.height == 400)
        let (centre, edge) = (colour(hydrogen, 300, 200), colour(hydrogen, 4, 4))
        precondition(centre[2] < 170 && centre[0] < 60 && edge[0] > 240, "darkest at the nucleus, paper far away: \(centre) \(edge)")
        let swing = pixels(try Computed(field: "sin(x)", xMin: -3.15, xMax: 3.15, yMin: -2, yMax: 2).raster(in: pictureBox))
        precondition(colour(swing, 150, 200)[0] > 200 && colour(swing, 150, 200)[2] < 90 && colour(swing, 450, 200)[0] < 60, "coral below zero, blue above")
        _ = try Computed(field: "1/(x^2 + y^2)", xMin: -1, xMax: 1, yMin: -1, yMax: 1).raster(in: pictureBox)  // a singularity is clipped, not fatal
        do { _ = try Computed(field: "1", xMin: -1, xMax: 1, yMin: -1, yMax: 1).raster(in: pictureBox); preconditionFailure("a flat field has nothing to show") } catch {}
        do {
            _ = try Computed(field: "x * 1e308", xMin: -1, xMax: 1, yMin: -1, yMax: 1).raster(in: pictureBox)
            preconditionFailure("an overflowing field range must be rejected")
        } catch {}
        let turning = Computed(u: "-y", v: "x", xMin: -5, xMax: 5, yMin: -5, yMax: 5), square = CGSize(width: 300, height: 300)
        let rings = try turning.lines(in: square, font: .pen).filter { $0.count > 12 }
        precondition(rings.count > 3, "flow lines: \(rings.count)")
        for ring in rings {
            let radii = ring.map { hypot($0.x - 150, $0.y - 150) }
            precondition(radii.max()! - radii.min()! < 0.05, "a rigid turn's flow lines are circles")
        }
        let orbit = Computed(curves: [.init(x: "3*cos(t)", y: "3*sin(t)", tMin: 0, tMax: 6.3)], xMin: -5, xMax: 5, yMin: -5, yMax: 5)
        let path = try orbit.lines(in: CGSize(width: 600, height: 200), font: .pen)
        precondition(path.count == 1 && path[0].allSatisfy { abs(hypot($0.x - 300, $0.y - 100) - 60) < 1e-6 }, "one unit is the same size across and up")

        // Pictures have no lines of their own, an old drawing still reads, and an edit swaps a figure whole.
        let painting = Drawing(reading: "a yard", kind: "picture", say: "a yard in spring", parts: [], plot: .init(expression: "", xMin: 0, xMax: 0, yMin: 0, yMax: 0),
                               picture: .init(prompt: "a yard in spring", search: false))
        let unlined = try painting.lines(in: pictureBox)
        precondition(unlined.isEmpty && painting.painted && !painting.blank)
        let old = try JSONDecoder().decode(Drawing.self, from: Data(#"{"reading":"r","kind":"ink","say":"s","parts":[],"plot":{"expression":"","xMin":0,"xMax":0,"yMin":0,"yMax":0}}"#.utf8))
        precondition(old.figure.points.isEmpty && old.computed.empty && old.question.isEmpty && old.blank)
        var diagram = old
        diagram.kind = "figure"
        diagram.figure = triangle()
        precondition(diagram.patched(parts: [], plot: diagram.plot, say: "", figure: frame).figure == frame && diagram.patched(parts: [], plot: diagram.plot, say: "").figure == triangle())

        print("drawing ok")
    }
}
