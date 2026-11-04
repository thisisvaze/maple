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

    /// One thing a person might point at and ask to change: a button, a field, a heading, an arrow, an axis.
    struct Part: Codable, Equatable, Sendable {
        var name: String
        var strokes: [[[Double]]]
        var labels: [Label]
        var fill: String? = nil  // one of `fills` colours its closed shapes in; anything else, or none, leaves them open
        var role: String? = nil  // in a hand: "detail" draws lighter, "arrow" flicks its short strokes; "fill" only colours its
        // closed shapes in, with no line round them (a traced painting's colour, whose lines are their own part); "traced" is
        // a traced painting's lines, which keep a hand's bow but don't lift at corners, since a painting's every small kink
        // would break them into scribbles; nil or else is a main line
    }

    /// One line Maple's pencil draws, and how: `lines` in the order they're drawn and stacked.
    struct Ink: Equatable, Sendable {
        /// A drawn line, a lighter one, a quick flick, colouring in, or a stroke of a label's letters.
        enum Kind: Sendable { case main, detail, flick, shade, letter }
        var line: [CGPoint]
        var cap: CGFloat? = nil  // a letter's capital height, so the pen can write small labels finer
        var fill: String? = nil  // the colour colouring in is done in
        var kind = Kind.main
    }

    /// The coloured pencils a part can be coloured in with (AgentPen.fills has their colours).
    static let fills = ["yellow", "green", "blue", "pink"]

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
    var lineArt = ""  // kind ink: what Muse Image paints for the app to trace into its lines (see Trace); empty when Muse draws it itself
    /// How its lines are drawn: 0 as before 4 Nov, `handDrawn` as a hand draws them. A saved drawing keeps the style it
    /// was inked in, because edits find its ink again by redrawing its lines.
    var style = 0
    var labeled = false  // the box sits under the person's label, so the drawing doesn't write that label again

    /// Lines that press and lift, lift at corners, overlap where a curve closes, colour in softly and weigh by role.
    static let handDrawn = 1

    /// A picture fills its box, under whatever ink the drawing has.
    var painted: Bool { kind == "picture" || kind == "computed" && !computed.field.isEmpty }

    /// Pen lines for a box of `size`: what the app computes itself (a plot's graph, a figure, a computed picture's lines)
    /// and the model's strokes in its parts (over those, notes on them), plus labels in Hershey's pen font. Model output
    /// is capped across all its parts, clamped into the box, and never executed.
    /// `zoom` is the zoom the drawing is inked at, which spaces its colouring in.
    func lines(in size: CGSize, font: Hershey = .pen, zoom: CGFloat = 1) throws -> [[CGPoint]] { try pen(in: size, font: font, zoom: zoom).map(\.line) }

    /// `lines` in the order they're drawn and stacked: the drawn lines, then the colouring in of filled parts, then
    /// labels over both (a figure's or computed picture's own labels count as drawn). In a hand, the colouring comes
    /// first, under the lines, and a part's line is cut where it lifts, each piece its own line, so every stroke still
    /// has its line.
    func pen(in size: CGSize, font: Hershey = .pen, zoom: CGFloat = 1) throws -> [Ink] {
        let inHand = style >= Self.handDrawn
        var lines: [[CGPoint]] = [], labels: [Label] = []
        switch kind {
        case "plot":
            (lines, labels) = try Plot.graph(plot, in: size)
            // Under the person's label, the graph's title, its first label, goes when it only says that label again.
            if labeled, let title = labels.first, title.text == "y = f(x)" || Self.repeats(title.text, reading, by: 0.6) { labels.removeFirst() }
        case "figure": lines = try figure.lines(in: size, font: font)
        case "computed": lines = try computed.lines(in: size, font: font)
        default: break
        }
        var budget = 12_000, strokes = 256  // the model's points and strokes, across all the parts
        // In a hand, a plot's axes, its first two lines, are lighter than its curve.
        var pen = lines.enumerated().map { Ink(line: $1, kind: inHand && kind == "plot" && $0 < 2 ? .detail : .main) }, colouring: [Ink] = []
        for part in parts {
            var closed: [[CGPoint]] = [], drawn: [(model: [CGPoint], lines: [[CGPoint]])] = []
            for stroke in part.strokes.prefix(max(strokes, 0)) {
                strokes -= 1
                let points = stroke.prefix(max(budget, 0)).compactMap { $0.count == 2 && $0.allSatisfy(\.isFinite) ? CGPoint(x: $0[0], y: $0[1]) : nil }
                budget -= points.count
                guard points.count > 1 else { continue }
                let shut = Self.closes(points, smallest: inHand ? 6 / zoom : 6)  // a hand measures a shape on screen
                if shut { closed.append(points) }
                drawn.append((points, inHand && part.role != "traced" ? Self.lift(points, closed: shut, zoom: zoom) : [points]))
            }
            if part.role != "fill" { pen += Self.inks(drawn, role: inHand ? part.role : nil, zoom: zoom) }
            guard let fill = part.fill, Self.fills.contains(fill) else { continue }
            // ponytail: each closed shape is coloured in on its own, so a shape inside another is coloured over twice;
            // colour by even-odd across the part's shapes if drawings need holes.
            // A shape too small to shade, like a timeline's dot, stays an outline: colored in, it reads as a scribble.
            let shaded = closed.filter { shape in
                let box = shape.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
                return min(box.width, box.height) * zoom >= Self.smallestShaded
            }
            if inHand {
                // At most `softInk` screen points of rows for the part, so a big fill spaces its rows out rather than
                // making the drawing too complex to ink. ponytail: past that the rows space out while staying as wide;
                // widen them with the gap if huge fills stripe.
                let gap = max(Self.softGap / zoom, shaded.map(Self.area).reduce(0, +) * zoom / Self.softInk)
                colouring += shaded.flatMap { Self.soft($0, gap: gap, inset: Self.softInset / zoom, spread: Self.softSpread / zoom) }.map { Ink(line: $0, fill: fill, kind: .shade) }
            } else {
                colouring += shaded.flatMap { Self.hatch($0, gap: Self.hatchGap / zoom, inset: Self.hatchInset / zoom) }.prefix(200).map { Ink(line: $0, fill: fill, kind: .shade) }
            }
        }
        // A hand colours in first and draws its lines over the colour, so a line inside a coloured shape still shows.
        pen = inHand ? colouring + pen : pen + colouring
        labels += parts.flatMap(\.labels)
        for label in labels.prefix(64) where [label.x, label.y, label.size].allSatisfy(\.isFinite) {
            let text = String(label.text.prefix(80)), cap = min(max(label.size, 4), 48)
            pen += font.lines(text, at: CGPoint(x: label.x, y: label.y), height: cap).map { Ink(line: $0, cap: cap, kind: .letter) }
        }
        let box = CGRect(origin: .zero, size: size)
        for i in pen.indices { pen[i].line = pen[i].line.map { CGPoint(x: min(max($0.x, box.minX), box.maxX), y: min(max($0.y, box.minY), box.maxY)) } }
        guard !pen.isEmpty || painted else { throw Plot.Failure("The drawing came back empty") }
        return pen
    }

    static let hatchGap: CGFloat = 3.4  // calibration knob: screen points between the colouring's strokes
    static let hatchInset: CGFloat = 2.6  // calibration knob: screen points the colouring keeps inside a shape's line
    static let smallestShaded: CGFloat = 18  // calibration knob: screen points across the smallest shape that gets colored in

    /// Whether a drawn line comes back round to where it began, as a box or a circle does, `smallest` across or more.
    static func closes(_ points: [CGPoint], smallest: CGFloat = 6) -> Bool {
        let box = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        guard points.count > 3, box.width >= smallest, box.height >= smallest, let a = points.first, let b = points.last else { return false }
        return hypot(a.x - b.x, a.y - b.y) <= max(4, hypot(box.width, box.height) * 0.08)
    }

    /// Colouring in for the closed `shape`, the way a hand does it with a pencil: diagonal strokes `gap` apart, kept
    /// `inset` inside its line, each run of them one zig-zag stroke that turns at the shape's edge.
    static func hatch(_ shape: [CGPoint], gap: CGFloat, inset: CGFloat) -> [[CGPoint]] {
        let turn = CGAffineTransform(rotationAngle: .pi / 4), back = turn.inverted()  // level the strokes to scan across
        let level = (shape + [shape[0]]).map { $0.applying(turn) }
        let ys = level.map(\.y)
        guard let top = ys.min(), let bottom = ys.max(), gap > 0, bottom - top > 2 * inset else { return [] }
        let along = inset * 2.squareRoot()  // along a stroke, so it keeps `inset` clear of a level or upright line
        var runs: [[CGPoint]] = [], open: [Int: [CGPoint]] = [:]  // zig-zags still going, by their place along the scan line
        var y = top + inset, row = 0
        while y <= bottom - inset, row < 400 {
            var xs: [CGFloat] = []
            for (a, b) in zip(level, level.dropFirst()) where (a.y <= y) != (b.y <= y) { xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)) }
            xs.sort()
            var next: [Int: [CGPoint]] = [:]
            for k in stride(from: 0, to: xs.count - 1, by: 2) where xs[k + 1] - xs[k] > 2 * along {
                let ends = row % 2 == 0 ? [CGPoint(x: xs[k] + along, y: y), CGPoint(x: xs[k + 1] - along, y: y)]
                                        : [CGPoint(x: xs[k + 1] - along, y: y), CGPoint(x: xs[k] + along, y: y)]
                var run = open.removeValue(forKey: k / 2) ?? []
                if let last = run.last, abs(last.x - ends[0].x) > 6 * gap {  // too far to turn to: lift and start again
                    runs.append(run)
                    run = []
                }
                run += ends
                next[k / 2] = run
            }
            runs += open.values  // a run whose shape ended or split stops here
            open = next
            y += gap
            row += 1
        }
        runs += open.values
        return runs.filter { $0.count > 1 }.map { $0.map { $0.applying(back) } }
    }

    // MARK: A hand's lines. Every amount a line varies by is seeded by the line's own points, so a line always draws the
    // same way: edits find the lines they leave alone by redrawing them.

    static let cornerTurn: CGFloat = 0.96  // calibration knob: radians a line turns through, 55°, for a hand to lift there
    static let mostCorners = 24  // calibration knob: a line with more corners than this is a scribble, drawn in one go
    static let softGap: CGFloat = 4.4  // calibration knob: screen points between soft colouring's rows
    static let softInset: CGFloat = 4.2  // calibration knob: screen points a row stops inside the line, at the least
    static let softSpread: CGFloat = 2.2  // calibration knob: screen points more that a row's end may stop short
    static let softInk: CGFloat = 120_000  // calibration knob: screen points of rows a part's colouring may take, well inside Marks.inked's limit
    static let softRows = 2000  // rows one shape gets at most: only so a shape far off the page always finishes

    /// A hand's line through the model's `points`: cut at each sharp corner, the piece running 1 to 3 screen points past
    /// the corner and the next starting just short of it. A closed shape lifts at its corners too, where it began; one
    /// with no corners, like a circle, is a single line that runs a little past its start.
    static func lift(_ model: [CGPoint], closed: Bool, zoom: CGFloat) -> [[CGPoint]] {
        // A point repeated, or a step under half a screen point, would hide the corner it sits on.
        let points = model.reduce(into: [CGPoint]()) { kept, p in
            if let last = kept.last, hypot(p.x - last.x, p.y - last.y) * zoom < 0.5 { return }
            kept.append(p)
        }
        guard points.count > 1 else { return [model] }
        guard closed else {
            let cuts = (1 ..< max(points.count - 1, 1)).filter { sharp(points[$0 - 1], points[$0], points[$0 + 1], zoom: zoom) }
            return cuts.count > mostCorners ? [points] : split(points, at: cuts, ends: false, zoom: zoom)
        }
        var ring = points
        if let a = ring.first, let b = ring.last, hypot(a.x - b.x, a.y - b.y) * zoom < 0.5 { ring.removeLast() }
        let n = ring.count
        guard n > 2 else { return [points] }
        let corners = (0 ..< n).filter { sharp(ring[($0 + n - 1) % n], ring[$0], ring[($0 + 1) % n], zoom: zoom) }
        guard let first = corners.first else { return [overlapped(ring, zoom: zoom)] }
        guard corners.count <= mostCorners else { return [points] }
        // Round from the first corner and back to it, cut at the others.
        let path = (0 ... n).map { ring[(first + $0) % n] }
        return split(path, at: corners.dropFirst().map { $0 - first }, ends: true, zoom: zoom)
    }

    /// Whether a line turns sharply at `b`, coming from `a` and going on to `c`, by more than `cornerTurn`. Steps under 2
    /// screen points don't count, so the small steps of a curve never do.
    static func sharp(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, zoom: CGFloat) -> Bool {
        let u = CGPoint(x: b.x - a.x, y: b.y - a.y), v = CGPoint(x: c.x - b.x, y: c.y - b.y), lu = hypot(u.x, u.y), lv = hypot(v.x, v.y)
        guard lu * zoom >= 2, lv * zoom >= 2 else { return false }
        return acos(min(max((u.x * v.x + u.y * v.y) / (lu * lv), -1), 1)) > cornerTurn
    }

    /// `path` in pieces at the corners `cuts`, by index: each piece runs on past the corner it ends at and the next starts
    /// a little before it, along their own directions. With `ends`, the path's own ends are a corner too.
    static func split(_ path: [CGPoint], at cuts: [Int], ends: Bool, zoom: CGFloat) -> [[CGPoint]] {
        guard !cuts.isEmpty || ends else { return [path] }
        var pieces: [[CGPoint]] = [], from = 0
        for cut in cuts + [path.count - 1] where cut > from {
            pieces.append(Array(path[from ... cut]))
            from = cut
        }
        func along(_ a: CGPoint, _ b: CGPoint, by length: CGFloat) -> CGPoint {
            let d = hypot(b.x - a.x, b.y - a.y)
            return d > 0 ? CGPoint(x: b.x + (b.x - a.x) / d * length, y: b.y + (b.y - a.y) / d * length) : b
        }
        return pieces.indices.map { j in
            var piece = pieces[j]
            let last = piece.count - 1
            if j < pieces.count - 1 || ends { piece[last] = along(piece[last - 1], piece[last], by: (1 + 2 * seed(piece[last], 1)) / zoom) }
            if j > 0 || ends { piece[0] = along(piece[1], piece[0], by: (0.3 + 0.9 * seed(piece[0], 2)) / zoom) }
            return piece
        }
    }

    /// One line round the closed `ring` from a start the shape itself picks, running 6 to 9% of the way round again past
    /// it while drifting just inside, as a pencil comes back round to where it began.
    static func overlapped(_ ring: [CGPoint], zoom: CGFloat) -> [CGPoint] {
        let n = ring.count
        guard n > 3 else { return ring + [ring[0]] }
        let box = ring.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }, middle = CGPoint(x: box.midX, y: box.midY)
        let start = min(Int(seed(middle, 3) * CGFloat(n)), n - 1)
        var out = (0 ... n).map { ring[(start + $0) % n] }
        let extra = length(out) * (0.06 + 0.03 * seed(middle, 4)), drift = (0.8 + 0.6 * seed(middle, 5)) / zoom
        var run: CGFloat = 0
        for j in 1 ..< n where run < extra {
            let q = ring[(start + j - 1) % n], p = ring[(start + j) % n], step = hypot(p.x - q.x, p.y - q.y)
            let t = step > 0 ? min(1, (extra - run) / step) : 1, at = CGPoint(x: q.x + (p.x - q.x) * t, y: q.y + (p.y - q.y) * t)
            run += step * t
            let d = hypot(middle.x - at.x, middle.y - at.y), pull = min(drift, d / 2) * run / extra
            out.append(d > 0 ? CGPoint(x: at.x + (middle.x - at.x) / d * pull, y: at.y + (middle.y - at.y) / d * pull) : at)
        }
        return out
    }

    /// Colouring in with the side of the pencil, for the closed `shape`: rows `gap` apart, rising at 30°, each one soft
    /// stroke that stops `inset` inside the shape's line, or up to `spread` more, by an amount the row itself picks.
    static func soft(_ shape: [CGPoint], gap: CGFloat, inset: CGFloat, spread: CGFloat) -> [[CGPoint]] {
        let turn = CGAffineTransform(rotationAngle: .pi / 6), back = turn.inverted()  // level the rows to scan across
        let level = (shape + [shape[0]]).map { $0.applying(turn) }
        let ys = level.map(\.y)
        guard let top = ys.min(), let bottom = ys.max(), gap > 0, bottom - top > 2 * inset else { return [] }
        let step = gap
        var rows: [[CGPoint]] = [], y = top + inset, row = 0
        while y <= bottom - inset, row < softRows {  // counted too, since far off, y + step can round back to y
            row += 1
            var xs: [CGFloat] = []
            for (a, b) in zip(level, level.dropFirst()) where (a.y <= y) != (b.y <= y) { xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)) }
            xs.sort()
            for k in stride(from: 0, to: xs.count - 1, by: 2) {
                let key = CGPoint(x: xs[k], y: y), a = xs[k] + inset + spread * seed(key, 6), b = xs[k + 1] - inset - spread * seed(key, 7)
                guard b - a > inset else { continue }
                let bend = (seed(key, 8) - 0.5) * step * 0.3
                rows.append([CGPoint(x: a, y: y), CGPoint(x: (a + b) / 2, y: y + bend), CGPoint(x: b, y: y)].map { $0.applying(back) })
            }
            y += step
        }
        return rows
    }

    /// How much of the page `shape` covers, by the shoelace formula: what it takes of a part's colouring.
    static func area(_ shape: [CGPoint]) -> CGFloat {
        abs(zip(shape, shape.dropFirst() + [shape[0]]).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }) / 2
    }

    static let flickReach: CGFloat = 6  // calibration knob: screen points between a short stroke's end and the one it's drawn from
    /// The kind of each line of a part's strokes, the model's `model` points cut into `lines`, by the part's role:
    /// "detail" draws lighter, and in an "arrow" a short stroke that starts from a much longer one, as a head starts
    /// at its shaft's tip, is a flick drawn out from there. Every other stroke is a main line, however it bends. Nil
    /// or any other role is a main line.
    static func inks(_ strokes: [(model: [CGPoint], lines: [[CGPoint]])], role: String?, zoom: CGFloat) -> [Ink] {
        guard role == "arrow" else { return strokes.flatMap(\.lines).map { Ink(line: $0, kind: role == "detail" ? .detail : .main) } }
        func gap(_ p: CGPoint, _ line: [CGPoint]) -> CGFloat { line.map { hypot($0.x - p.x, $0.y - p.y) }.min() ?? .infinity }
        return strokes.indices.flatMap { i -> [Ink] in
            let longer = strokes.indices.filter { $0 != i && length(strokes[$0].model) > 2.5 * length(strokes[i].model) }.map { strokes[$0].model }
            // Each piece by its own ends, so both halves of a head drawn as one V flick out from the tip they share.
            return strokes[i].lines.map { line in
                let tip = [line[0], line[line.count - 1]].map { end in (end, longer.map { gap(end, $0) }.min() ?? .infinity) }.min { $0.1 < $1.1 }
                guard let tip, tip.1 * zoom <= flickReach else { return Ink(line: line) }
                return Ink(line: tip.0 == line[0] ? line : line.reversed(), kind: .flick)
            }
        }
    }

    /// Under the person's label, this drawing without the labels of a part Muse named as a title that only say that
    /// label again. Words that belong to what's drawn, like a screen's heading or a button's text, stay, and nothing
    /// goes if it would leave the drawing empty. Done once as the drawing comes back, so edits see what's on the page.
    func untitled() -> Drawing {
        guard labeled else { return self }
        var out = self
        for i in out.parts.indices where out.parts[i].name.lowercased().contains("title") {
            out.parts[i].labels.removeAll { Self.repeats($0.text, reading, by: 0.8) }
        }
        return out.blank && !blank ? self : out
    }

    static func length(_ line: [CGPoint]) -> CGFloat { zip(line, line.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } }

    /// A number from 0 to 1 that `p` and `salt` always give, and nearby points give quite differently.
    static func seed(_ p: CGPoint, _ salt: Double) -> CGFloat {
        let s = sin(Double(p.x) * 12.9898 + Double(p.y) * 78.233 + salt * 37.719) * 43_758.5453
        return CGFloat(s - s.rounded(.down))
    }

    /// Whether `text` only says `reading` again: at least `share` of its words are in `reading`, whatever the case,
    /// punctuation and plural, leaving out small words like "the" and "of".
    static func repeats(_ text: String, _ reading: String, by share: Double) -> Bool {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !["the", "a", "an", "of", "and", "to", "in", "on", "for"].contains($0) }
                .map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
        }
        let a = words(text), b = words(reading)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(a.count) >= share
    }

    /// Nothing left to draw: an ink drawing whose parts have no strokes or labels.
    var blank: Bool { kind == "ink" && parts.allSatisfy { $0.strokes.isEmpty && $0.labels.isEmpty } }

    /// Parts are stored in box points; plots and figures regenerate from their equations at the new size.
    func scaled(by scale: CGFloat) -> Drawing {
        var out = self
        out.parts = parts.map { part in
            Part(name: part.name, strokes: part.strokes.map { $0.map { $0.map { $0 * scale } } },
                 labels: part.labels.map { Label(text: $0.text, x: $0.x * scale, y: $0.y * scale, size: $0.size * scale) }, fill: part.fill, role: part.role)
        }
        return out
    }

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
        lineArt = try saved.decodeIfPresent(String.self, forKey: .lineArt) ?? ""
        style = try saved.decodeIfPresent(Int.self, forKey: .style) ?? 0
        labeled = try saved.decodeIfPresent(Bool.self, forKey: .labeled) ?? false
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
