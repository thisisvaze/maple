import CoreGraphics
import Foundation

/// What the agent draws in an empty box, in the box's own points: x rightward, y downward, from its top-left.
nonisolated struct Drawing: Codable, Equatable, Sendable {
    struct Label: Codable, Equatable, Sendable {
        var text: String
        var x, y, size: CGFloat  // top-left of the text; size is the capital height
    }

    struct Graph: Codable, Equatable, Sendable {
        var expression: String
        var xMin, xMax, yMin, yMax: Double
    }

    /// One thing a person might point at and ask to change: a button, a field, the title, an arrow, an axis.
    struct Part: Codable, Equatable, Sendable {
        var name: String
        var strokes: [[[Double]]]
        var labels: [Label]
    }

    /// What Muse Image is asked to paint.
    struct Picture: Codable, Equatable, Sendable {
        var prompt = ""
        var search = false  // the picture depends on what something real looks like, or on current facts
    }

    var reading: String  // what the box's label says
    var kind: String  // "ink", "plot", "figure", "computed", "picture", or "ask" when Muse needs to know which is meant
    var say: String  // one line about the drawing, for follow-up questions
    var parts: [Part]
    var plot: Graph
    var figure = Figure()
    var computed = Computed()
    var picture = Picture()
    var question = ""  // kind ask: what Maple writes beside the box

    /// A picture fills its box, under whatever ink the drawing has.
    var painted: Bool { kind == "picture" || kind == "computed" && !computed.field.isEmpty }

    /// Pen lines for a box of `size`: what the app computes itself (a plot's graph, a figure, a computed picture's lines)
    /// and the model's strokes in its parts (over those, notes on them), plus labels in Hershey's pen font. Model output
    /// is capped across all its parts, clamped into the box, and never executed.
    func lines(in size: CGSize, font: Hershey = .pen) throws -> [[CGPoint]] {
        var lines: [[CGPoint]] = [], labels: [Label] = []
        switch kind {
        case "plot": (lines, labels) = try Plot.graph(plot, in: size)
        case "figure": lines = try figure.lines(in: size, font: font)
        case "computed": lines = try computed.lines(in: size, font: font)
        default: break
        }
        var budget = 12_000  // points
        lines += parts.flatMap(\.strokes).prefix(256).compactMap { stroke in
            let points = stroke.prefix(max(budget, 0)).compactMap { $0.count == 2 && $0.allSatisfy(\.isFinite) ? CGPoint(x: $0[0], y: $0[1]) : nil }
            budget -= points.count
            return points.count > 1 ? points : nil
        }
        labels += parts.flatMap(\.labels)
        for label in labels.prefix(64) where [label.x, label.y, label.size].allSatisfy(\.isFinite) {
            let text = String(label.text.prefix(80))
            lines += font.lines(text, at: CGPoint(x: label.x, y: label.y), height: min(max(label.size, 4), 48))
        }
        let box = CGRect(origin: .zero, size: size)
        lines = lines.map { $0.map { CGPoint(x: min(max($0.x, box.minX), box.maxX), y: min(max($0.y, box.minY), box.maxY)) } }
        guard !lines.isEmpty || painted else { throw Plot.Failure("The drawing came back empty") }
        return lines
    }

    /// Nothing left to draw: an ink drawing whose parts have no strokes or labels.
    var blank: Bool { kind == "ink" && parts.allSatisfy { $0.strokes.isEmpty && $0.labels.isEmpty } }

    /// This drawing with an edit's parts patched in by name, trimmed and in any case: a listed part replaces its namesake
    /// or is added, one with no strokes and no labels removes its namesake, and unlisted parts stay as they are. A plot
    /// with an expression, a figure with points, a computed picture with something to compute, and a non-empty say,
    /// replace their own.
    func patched(parts: [Part], plot: Graph, say: String, figure: Figure = Figure(), computed: Computed = Computed()) -> Drawing {
        func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var out = self
        for part in parts {
            let same = out.parts.firstIndex { key($0.name) == key(part.name) }
            if part.strokes.isEmpty, part.labels.isEmpty {
                if let same { out.parts.remove(at: same) }
            } else if let same {
                out.parts[same] = part
            } else {
                out.parts.append(part)
            }
        }
        if !plot.expression.trimmingCharacters(in: .whitespaces).isEmpty { out.plot = plot }
        if !figure.points.isEmpty { out.figure = figure }
        if !computed.empty { out.computed = computed }
        if !say.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.say = say }
        return out
    }
}

nonisolated extension Drawing {
    /// A drawing saved before parts kept its strokes and labels at the top.
    private enum Legacy: String, CodingKey { case strokes, labels }

    /// Reads parts, or a drawing saved before them as one part named "drawing". Here, so the memberwise init stays.
    init(from decoder: any Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        reading = try saved.decode(String.self, forKey: .reading)
        kind = try saved.decode(String.self, forKey: .kind)
        say = try saved.decode(String.self, forKey: .say)
        plot = try saved.decode(Graph.self, forKey: .plot)
        figure = try saved.decodeIfPresent(Figure.self, forKey: .figure) ?? Figure()
        computed = try saved.decodeIfPresent(Computed.self, forKey: .computed) ?? Computed()
        picture = try saved.decodeIfPresent(Picture.self, forKey: .picture) ?? Picture()
        question = try saved.decodeIfPresent(String.self, forKey: .question) ?? ""
        if saved.contains(.parts) {
            parts = try saved.decode([Part].self, forKey: .parts)
        } else {
            let old = try decoder.container(keyedBy: Legacy.self)
            parts = [Part(name: "drawing", strokes: try old.decode([[[Double]]].self, forKey: .strokes), labels: try old.decode([Label].self, forKey: .labels))]
        }
    }
}

/// Graphs of y = f(x). The expression is parsed by a small maths grammar (numbers, pi, e, + - * / ^, parentheses, the
/// functions below and the caller's variables), so a model's formula is never run as code. The model picks the function
/// and ranges; the app computes every point, because drawn-by-hand curves came out wrong.
nonisolated enum Plot {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func function(_ source: String) throws -> (Double) -> Double {
        let f = try expression(source, variables: ["x"])
        return { f([$0]) }
    }

    /// `source` as a function of `variables`, whose values it takes in that order.
    static func expression(_ source: String, variables: [String]) throws -> ([Double]) -> Double {
        guard source.count <= 600 else { throw Failure("Expression too long") }
        let tokens = source.lowercased().matches(of: /(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?|[a-z][a-z0-9_]*|\S/).map { String($0.output) }
        let functions: [String: (Double) -> Double] = ["sin": sin, "cos": cos, "tan": tan, "sqrt": { $0.squareRoot() }, "abs": abs, "log": log, "exp": exp,
                                                       "asin": asin, "acos": acos, "atan": atan, "sinh": sinh, "cosh": cosh, "tanh": tanh]
        let pairs: [String: (Double, Double) -> Double] = ["atan2": atan2, "min": min, "max": max, "hypot": hypot]
        let powers: [String: Int] = ["+": 1, "-": 1, "*": 2, "/": 2, "^": 3]
        var i = 0
        func next() -> String? { defer { i += 1 }; return i < tokens.count ? tokens[i] : nil }
        func expect(_ token: String) throws { guard next() == token else { throw Failure("Expected \(token)") } }

        func parse(_ least: Int, _ depth: Int) throws -> ([Double]) -> Double {
            guard depth < 32 else { throw Failure("Expression too deep") }
            var left: ([Double]) -> Double
            switch next() {
            case "-"?: let operand = try parse(3, depth + 1); left = { -operand($0) }
            case "+"?: left = try parse(3, depth + 1)
            case "("?: left = try parse(0, depth + 1); try expect(")")
            case let name? where variables.contains(name):
                let index = variables.firstIndex(of: name)!
                left = { $0[index] }
            case "pi"?: left = { _ in .pi }
            case "e"?: left = { _ in M_E }
            case let name? where functions[name] != nil:
                try expect("(")
                let argument = try parse(0, depth + 1), f = functions[name]!
                try expect(")")
                left = { f(argument($0)) }
            case let name? where pairs[name] != nil:
                try expect("(")
                let a = try parse(0, depth + 1)
                try expect(",")
                let b = try parse(0, depth + 1), f = pairs[name]!
                try expect(")")
                left = { f(a($0), b($0)) }
            case let token?:
                guard let number = Double(token), number.isFinite else { throw Failure("Unsupported \(token)") }
                left = { _ in number }
            case nil: throw Failure("Expression ended early")
            }
            while i < tokens.count, let power = powers[tokens[i]], power >= least {
                let op = tokens[i]
                i += 1
                let right = try parse(op == "^" ? power : power + 1, depth + 1), before = left
                switch op {
                case "+": left = { before($0) + right($0) }
                case "-": left = { before($0) - right($0) }
                case "*": left = { before($0) * right($0) }
                case "/": left = { before($0) / right($0) }
                default: left = { pow(before($0), right($0)) }
                }
            }
            return left
        }
        let f = try parse(0, 0)
        guard i == tokens.count else { throw Failure("Unexpected \(tokens[i])") }
        return f
    }

    /// Axes, the curve sampled 240 times (split where it leaves the range or jumps), and labels for it and its x range.
    static func graph(_ g: Drawing.Graph, in size: CGSize) throws -> (lines: [[CGPoint]], labels: [Drawing.Label]) {
        guard [g.xMin, g.xMax, g.yMin, g.yMax].allSatisfy({ $0.isFinite && abs($0) <= 1e6 }), g.xMax > g.xMin, g.yMax > g.yMin else { throw Failure("Invalid graph ranges") }
        guard size.width >= 80, size.height >= 60 else { throw Failure("Draw a larger box for a graph") }
        let f = try function(g.expression)
        let w = size.width, h = size.height, pad = 0.12  // Agent.editInstructions tells Muse this, to mark points on a plot
        func px(_ x: Double) -> CGFloat { w * (pad + (1 - 2 * pad) * (x - g.xMin) / (g.xMax - g.xMin)) }
        func py(_ y: Double) -> CGFloat { h * (1 - pad - (1 - 2 * pad) * (y - g.yMin) / (g.yMax - g.yMin)) }
        let axisX = px(min(max(0, g.xMin), g.xMax)), axisY = py(min(max(0, g.yMin), g.yMax))
        var lines = [[CGPoint(x: px(g.xMin), y: axisY), CGPoint(x: px(g.xMax), y: axisY)],
                     [CGPoint(x: axisX, y: py(g.yMin)), CGPoint(x: axisX, y: py(g.yMax))]]
        var line: [CGPoint] = [], previous: Double?
        func flush() { if line.count > 1 { lines.append(line) }; line = []; previous = nil }
        for n in 0...240 {
            let x = g.xMin + (g.xMax - g.xMin) * Double(n) / 240, y = f(x)
            guard y.isFinite, y >= g.yMin, y <= g.yMax else { flush(); continue }
            if let previous, abs(y - previous) > (g.yMax - g.yMin) * 0.4 { flush() }  // an asymptote, not a cliff to draw
            line.append(CGPoint(x: px(x), y: py(y)))
            previous = y
        }
        flush()
        guard lines.count > 2 else { throw Failure("The function isn't visible in those ranges") }
        // Hershey capitals are about as wide as they are tall; size each label to fit.
        let size = min(12, max(4, h * 0.05)), room = w * (1 - 2 * pad)
        let title = "y = \(g.expression)".count * Int(size) <= Int(room) ? "y = \(g.expression)" : "y = f(x)"
        var labels = [Drawing.Label(text: title, x: w * pad, y: h * 0.025, size: min(size, room / CGFloat(title.count)))]
        for x in [g.xMin, g.xMax] {
            let text = String(format: "%g", x), s = min(size, w * 0.9 / CGFloat(text.count)), width = CGFloat(text.count) * s
            labels.append(Drawing.Label(text: text, x: min(max(0, px(x) - width / 2), w - width), y: min(h - s * 1.4, axisY + 5), size: s))
        }
        return (lines, labels)
    }
}
