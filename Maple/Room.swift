import CoreGraphics
import Foundation

/// Where an answer is written in ink: after its mark on the question's line, on the line under it, or in the best clear
/// gap on screen, with a dashed leader back to the mark when that is far. Pure geometry, so it checks on the Mac. It
/// works in a reading frame, the page turned by `angle` (q = p rotated by angle about the page origin): the screen's
/// own frame, squared to the person's line when they write on a slant.
nonisolated enum Room {
    struct Stroke: Sendable {
        var points: [CGPoint]  // visible ink in page points, a few apart, transform applied
        var person: Bool  // the person's pen; Maple's earlier ink is in the way but isn't part of their lines
        var mark: Bool  // one of the strokes being answered
    }

    struct Request: Sendable {
        var strokes: [Stroke]  // everything on and near the screen
        var doubleDot: Bool  // the mark is two nib taps ("look here"), not a written ?
        var trailing = false  // the mark is a small sign ending the line, an = or …: the answer takes its letters' size and baseline
        var screen: [CGPoint]  // the screen's four corners in page points, clockwise from top-left
        var avoid: [[CGPoint]]  // page-point polygons in the way: the Pages button, other answers' dots
        var screenAngle: CGFloat  // the page's rotation on screen, radians
        var zoom: CGFloat  // screen points per page point
        var nib: CGPoint?  // where the pen last touched, page points
    }

    struct Placement: Sendable, Equatable {
        enum Kind: String, Sendable { case sameLine, nextLine, gap, leader }
        var kind: Kind
        var angle: CGFloat  // the reading frame the block is written in
        var origin: CGPoint  // the first capital's top-left, reading frame
        var cap: CGFloat  // capital height, page points
        var width: CGFloat  // wrap width to lay the text out at, page points
        var rect: CGRect  // the written block, reading frame (origin + extent)
        var leader: [[CGPoint]]  // dashes from the mark to the block, page points; empty unless kind == .leader
    }

    /// The question's line in one reading frame.
    struct Line {
        var mark, band: CGRect  // the mark (with a double dot's word), and the line's strokes around it
        var cap, capTop: CGFloat  // the answer's capital height, and where a capital on this line starts
        var bottoms: [CGPoint]  // the middles of its letters' bottoms, to square the frame to
        var members: [Int]  // its strokes, by place among the person's other strokes with ink
    }

    // Lengths are in caps, the answer's capital height, unless they say screen points.
    static let capFactor: CGFloat = 0.9  // calibration knob: a capital against the ?'s height, or the letters' median
    static let capRange: ClosedRange<CGFloat> = 12 ... 26  // calibration knob: screen points
    static let defaultCap: CGFloat = 18  // calibration knob: screen points, a double dot's cap until it finds letters
    // calibration knob: default caps from a double dot to the stroke under it, or else to the nearest stroke
    static let under: CGFloat = 1, nearest: CGFloat = 2
    static let word: CGFloat = 0.4  // calibration knob: caps between a word's letters; a double dot's seed grows to its word
    // calibration knob: the line band; a stroke joins sharing chainOverlap of the smaller height, chainGap from the band
    static let chainGap: CGFloat = 1.5, chainOverlap: CGFloat = 0.5, bandMax: CGFloat = 25
    // calibration knob: a line long enough to square the frame to, and how many fits find its slant
    static let squareStrokes = 4, squareSpan: CGFloat = 3, squareTurns = 3
    // calibration knob: degrees between the turns tried when the screen's frame finds no slant, and how far (caps, root
    // mean square) the letters of a slant found that way may sit off a straight baseline
    static let sweep: CGFloat = 5, straight: CGFloat = 0.2
    static let slant: ClosedRange<CGFloat> = 2 ... 45  // calibration knob: degrees of slant the frame squares away
    static let fitHeight: CGFloat = 0.5  // calibration knob: strokes this tall count in the slant fit; dots and bars sit off the baseline
    static let cell: CGFloat = 0.25, margin: CGFloat = 1, nibClear: CGFloat = 4  // calibration knob: grid cells, the screen edge, the nib
    static let after: CGFloat = 0.6, below: CGFloat = 0.5  // calibration knob: mark to a same-line answer, band to a next-line one
    static let widths: [CGFloat] = [32, 20, 12], maxRows = 8  // calibration knob: wrap widths, widest first
    static let sizes: [CGFloat] = [1, 0.85, 0.72], minSize: CGFloat = 10  // calibration knob: smaller caps for a gap, minSize in screen points
    static let step: CGFloat = 0.5  // calibration knob: between the gap positions tried
    // calibration knob: a gap's score, on top of its distance from the mark
    static let leftCost: CGFloat = 3, aboveCost: CGFloat = 2, sizeCost: CGFloat = 2, rowCost: CGFloat = 0.25, leaderCost: CGFloat = 2
    // calibration knob: a block past leaderReach gets a leader; its dashes, and the ends of it that may cross ink
    static let leaderReach: CGFloat = 2, dash: CGFloat = 0.5, dashGap: CGFloat = 0.35, leaderEnds: CGFloat = 0.75
    static let crossing: CGFloat = 3  // calibration knob: caps over and under the mark a leader may cross, when none is clear

    /// Where to write an answer that `layout(cap, width)` wraps at `width`, giving its ink extent from the first
    /// capital's top-left and its number of lines. Nil when nothing fits on screen, and the answer stays a quiet dot.
    static func place(_ request: Request, layout: (_ cap: CGFloat, _ width: CGFloat) -> (extent: CGRect, rows: Int)) -> Placement? {
        let level = request.screenAngle
        guard request.zoom > 0, let flat = Self.line(request, at: level) else { return nil }
        // Square the frame to a slanted line: turn it by the slant of a line through the band's letters, and fit again on
        // the band that turn finds, a few times. The frame turns only for a line long enough to trust. When the screen's
        // frame found a line (letters on a straight baseline), the turn must keep all of it; when it found a cut across
        // slanted lines instead, the turned band must be straight. Seen in the screen's frame a steep line chains few
        // strokes past its mark, so when that finds nothing the fit starts again from the turn, `sweep` degrees apart,
        // with the widest straight band. A band that isn't straight is a cut across the lines around the mark.
        func straight(_ line: Line) -> Bool { line.bottoms.count > 2 && tilt(line.bottoms).map { $0.spread <= Self.straight * line.cap } ?? false }
        let found = straight(flat)
        func keeps(_ line: Line) -> Bool { found ? flat.members.allSatisfy(line.members.contains) : straight(line) }
        func squared(from start: (angle: CGFloat, line: Line)) -> (angle: CGFloat, line: Line)? {
            var turned = start
            for _ in 0 ..< squareTurns {
                guard let phi = tilt(turned.line.bottoms)?.angle, abs(phi) > 0.001, abs(turned.angle - phi - level) <= slant.upperBound * .pi / 180,
                      let next = Self.line(request, at: turned.angle - phi) else { break }
                turned = (turned.angle - phi, next)
            }
            let trusted = turned.line.bottoms.count >= squareStrokes && turned.line.band.width >= squareSpan * turned.line.cap
                && slant.contains(abs(turned.angle - level) * 180 / .pi) && keeps(turned.line)
            return trusted ? turned : nil
        }
        func swept() -> (angle: CGFloat, line: Line)? {
            var start = (angle: level, line: flat)
            for degrees in stride(from: sweep, through: slant.upperBound, by: sweep).flatMap({ [$0, -$0] }) {
                let angle = level + degrees * .pi / 180
                if let line = Self.line(request, at: angle), line.band.width > start.line.band.width, keeps(line), straight(line) { start = (angle, line) }
            }
            return squared(from: start).flatMap { straight($0.line) ? $0 : nil }
        }
        let (angle, line) = squared(from: (level, flat)) ?? swept() ?? (level, flat)

        let cap = line.cap, mark = line.mark, band = line.band, frame = CGAffineTransform(rotationAngle: angle)
        let toScreen = CGAffineTransform(rotationAngle: level - angle)  // reading frame to the screen's, where the screen is a rect
        let inset = box(request.screen, CGAffineTransform(rotationAngle: level)).insetBy(dx: margin * cap, dy: margin * cap)
        guard !inset.isNull else { return nil }
        let grid = Grid(request, frame: frame, cell: cell * cap), nib = request.nib.map { CGRect(origin: $0.applying(frame), size: .zero) }

        func onScreen(_ p: CGPoint) -> Bool {
            let s = p.applying(toScreen)
            return s.x >= inset.minX && s.x <= inset.maxX && s.y >= inset.minY && s.y <= inset.maxY
        }
        /// On the inset screen, clear of the nib, and meeting no stamped cell but within `skip` of its top edge, left of `end`.
        func fits(_ r: CGRect, skip: CGFloat = 0, to end: CGFloat = 0) -> Bool {
            grid.free(CGRect(x: r.minX, y: r.minY + skip, width: r.width, height: r.height - skip))
                && (skip == 0 || end >= r.maxX || grid.free(CGRect(x: end, y: r.minY, width: r.maxX - end, height: skip)))
                && (nib.map { distance($0, r) >= nibClear * cap } ?? true)
                && onScreen(CGPoint(x: r.minX, y: r.minY)) && onScreen(CGPoint(x: r.maxX, y: r.minY))
                && onScreen(CGPoint(x: r.maxX, y: r.maxY)) && onScreen(CGPoint(x: r.minX, y: r.maxY))
        }
        /// How far the reading frame's x axis runs from `origin` to the inset screen's edge.
        // ponytail: measured along the first row only; a squared frame's lower rows may run out sooner, and `fits` says no.
        func room(_ origin: CGPoint) -> CGFloat {
            guard onScreen(origin) else { return 0 }
            let s = origin.applying(toScreen), dx = cos(level - angle), dy = sin(level - angle)
            return min((inset.maxX - s.x) / dx, dy > 0 ? (inset.maxY - s.y) / dy : dy < 0 ? (inset.minY - s.y) / dy : .infinity)
        }
        // On the question's line, or the line under it. A next-line block starts `below` under its band, nearer than the
        // grid's margin round the band's descenders reaches (two cells), so its top cell under the band and that margin
        // may meet it. All other ink keeps its whole margin from either block.
        // ponytail: trusts that only the band's own ink sits in that strip; an underline or stray mark just under the band
        // can come within a cell of the answer. Test the strip against raw ink, not stamps, if that shows up.
        func written(_ kind: Placement.Kind, at origin: CGPoint) -> Placement? {
            let room = room(origin)
            for width in [min(widths[0] * cap, room)] + widths.dropFirst().map({ $0 * cap }).filter({ $0 <= room }) where width > 0 {
                let (extent, rows) = layout(cap, width)
                let rect = extent.offsetBy(dx: origin.x, dy: origin.y)
                if rows <= maxRows, rows == 1 || width >= widths[widths.count - 1] * cap,
                   fits(rect, skip: kind == .nextLine ? cell * cap : 0, to: band.maxX + 2 * cell * cap) {
                    return Placement(kind: kind, angle: angle, origin: origin, cap: cap, width: width, rect: rect, leader: [])
                }
            }
            return nil
        }
        if let placed = written(.sameLine, at: CGPoint(x: mark.maxX + after * cap, y: line.capTop))
            ?? written(.nextLine, at: CGPoint(x: band.minX, y: band.maxY + below * cap)) { return placed }

        /// Dashes from the middle of the mark's nearest edge to the middle of the block's, or nil when the line between
        /// them crosses ink away from its ends and outside `near`. The dashes and gaps stretch to fit it end to end.
        // ponytail: a straight leader or none; route around ink if good gaps keep losing their leaders.
        func leader(to block: CGRect, near: CGRect) -> [[CGPoint]]? {
            func middles(_ r: CGRect) -> [CGPoint] {
                [CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY)]
            }
            let (a, b) = middles(mark).flatMap { a in middles(block).map { (a, $0) } }
                .min { hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) < hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) }!
            let length = hypot(b.x - a.x, b.y - a.y)
            func at(_ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t / length, y: a.y + (b.y - a.y) * t / length) }
            for t in stride(from: leaderEnds * cap, through: length - leaderEnds * cap, by: cell * cap) where grid.inked(at(t)) && !near.contains(at(t)) {
                return nil
            }
            let d = dash * cap, g = dashGap * cap, n = max(1, ((length + g) / (d + g)).rounded()), s = length / (n * d + (n - 1) * g)
            return (0 ..< Int(n)).map { CGFloat($0) * (d + g) * s }.map { [at($0), at($0 + d * s)] }
        }
        // Otherwise the best clear gap on screen, smaller if need be: near the mark, after or under it rather than before
        // or over it, with a dashed leader when it's far. When no leader is clear, as round a word inside a paragraph,
        // one may cross the lines just over and under the mark.
        let page = CGAffineTransform(rotationAngle: -angle)
        let area = box([CGPoint(x: inset.minX, y: inset.minY), CGPoint(x: inset.maxX, y: inset.minY), CGPoint(x: inset.maxX, y: inset.maxY),
                        CGPoint(x: inset.minX, y: inset.maxY)], toScreen.inverted())
        var crossed = false  // a block fit but its leader crossed ink
        func gap(near: CGRect) -> Placement? {
            var best: (score: CGFloat, placement: Placement)?
            for (n, size) in sizes.enumerated() where cap * size * request.zoom >= minSize {
                for width in widths.reversed().map({ $0 * cap * size }) {
                    let (extent, rows) = layout(cap * size, width)
                    guard rows <= maxRows else { continue }
                    let fixed = sizeCost * CGFloat(n) + rowCost * CGFloat(rows)
                    for y in stride(from: area.minY, through: area.maxY - extent.height, by: step * cap) {
                        for x in stride(from: area.minX, through: area.maxX - extent.width, by: step * cap) {
                            let rect = CGRect(x: x, y: y, width: extent.width, height: extent.height), gap = distance(mark, rect), far = gap > leaderReach * cap
                            let score = gap / cap + fixed + (rect.maxX <= mark.minX ? leftCost : 0) + (rect.maxY <= band.minY ? aboveCost : 0)
                                + (far ? leaderCost : 0)
                            guard score < best?.score ?? .infinity, fits(rect) else { continue }
                            guard let dashes = far ? leader(to: rect, near: near) : [] else { crossed = true; continue }
                            best = (score, Placement(kind: far ? .leader : .gap, angle: angle, origin: CGPoint(x: x - extent.minX, y: y - extent.minY),
                                                     cap: cap * size, width: width, rect: rect, leader: dashes.map { $0.map { $0.applying(page) } }))
                        }
                    }
                }
            }
            return best?.placement
        }
        if let placed = gap(near: .null) { return placed }
        return crossed ? gap(near: mark.insetBy(dx: -leaderEnds * cap, dy: -crossing * cap)) : nil
    }

    /// The question's line in the frame turned by `angle`: its seed (the ?, or the strokes under a double dot grown to
    /// their word) and the person's strokes chained to it both ways. Each must share half its height with the seed's own
    /// span, so ascenders and descenders don't chain into the lines above and below. Nil without a mark.
    static func line(_ request: Request, at angle: CGFloat) -> Line? {
        let frame = CGAffineTransform(rotationAngle: angle), zoom = request.zoom
        func clamp(_ cap: CGFloat) -> CGFloat { min(max(cap, capRange.lowerBound / zoom), capRange.upperBound / zoom) }
        let marked = request.strokes.reduce(CGRect.null) { $1.mark ? $0.union(box($1.points, frame)) : $0 }
        guard !marked.isNull else { return nil }
        let boxes = request.strokes.compactMap { $0.person && !$0.mark ? box($0.points, frame) : nil }.filter { !$0.isNull }
        // A trailing = or … is shorter than its letters: chain at a usual size, then take theirs.
        var members: [Int] = [], cap = request.trailing ? clamp(defaultCap / zoom) : clamp(capFactor * marked.height)
        if request.doubleDot {
            // The strokes touching the dots, else the nearest right under them, else the nearest at all, else the dots alone.
            let fallback = clamp(defaultCap / zoom), strip = CGRect(x: marked.minX, y: marked.maxY, width: marked.width, height: under * fallback)
            func nearest(_ near: (CGRect) -> Bool) -> [Int] {
                boxes.indices.filter { near(boxes[$0]) }.min { distance(marked, boxes[$0]) < distance(marked, boxes[$1]) }.map { [$0] } ?? []
            }
            members = boxes.indices.filter { distance(boxes[$0], marked) == 0 }
            if members.isEmpty { members = nearest { distance($0, strip) == 0 } }
            if members.isEmpty { members = nearest { distance($0, marked) <= Self.nearest * fallback } }
            cap = members.isEmpty ? fallback : clamp(capFactor * median(members.map { boxes[$0].height }))
        }
        let core = members.isEmpty ? marked : members.reduce(CGRect.null) { $0.union(boxes[$1]) }
        var band = core, rest = boxes.indices.filter { i in
            !members.contains(i) && min(boxes[i].maxY, core.maxY) - max(boxes[i].minY, core.minY) >= chainOverlap * min(boxes[i].height, core.height)
        }
        /// Adds the strokes `gap` caps or less beside the band as it grows, until none is or the band is bandMax wide.
        func chain(_ gap: CGFloat) {
            var grew = true
            while grew {
                grew = false
                for (k, i) in rest.enumerated().reversed()
                where band.width < bandMax * cap && max(band.minX - boxes[i].maxX, boxes[i].minX - band.maxX) <= gap * cap {
                    band = band.union(boxes[i])
                    members.append(i)
                    rest.remove(at: k)
                    grew = true
                }
            }
        }
        if request.doubleDot, !members.isEmpty {
            chain(word)
            cap = clamp(capFactor * median(members.map { boxes[$0].height }))
        }
        let mark = request.doubleDot ? band.union(marked) : marked  // a double dot's word stands for its mark
        chain(chainGap)
        let fromLetters = (request.doubleDot || request.trailing) && !members.isEmpty
        if fromLetters { cap = clamp(capFactor * median(members.map { boxes[$0].height })) }
        let letters = ((request.doubleDot ? [] : [marked]) + members.map { boxes[$0] }).filter { $0.height >= fitHeight * cap }
        let bottoms = letters.map { CGPoint(x: $0.midX, y: $0.maxY) }
        let baseline = fromLetters ? median(members.map { boxes[$0].maxY }) : marked.maxY
        return Line(mark: mark, band: band, cap: cap, capTop: baseline - cap, bottoms: bottoms, members: members)
    }

    /// The median slope between letters resists a descender pulling a short line off level. Spread is the root mean
    /// square distance from that slope through their center. Nil without any horizontal spread.
    static func tilt(_ points: [CGPoint]) -> (angle: CGFloat, spread: CGFloat)? {
        let slopes = points.enumerated().flatMap { i, a in
            points.dropFirst(i + 1).compactMap { b in b.x == a.x ? nil : (b.y - a.y) / (b.x - a.x) }
        }
        guard !slopes.isEmpty else { return nil }
        let n = CGFloat(points.count), mx = points.reduce(0) { $0 + $1.x } / n, my = points.reduce(0) { $0 + $1.y } / n
        let k = median(slopes), off = points.reduce(0) { $0 + pow($1.y - my - k * ($1.x - mx), 2) }
        return (atan(k), (off / n).squareRoot())
    }

    /// The box around `points` turned by `t`; null when there are none.
    static func box(_ points: [CGPoint], _ t: CGAffineTransform = .identity) -> CGRect {
        var x0 = CGFloat.infinity, y0 = CGFloat.infinity, x1 = -CGFloat.infinity, y1 = -CGFloat.infinity
        for p in points {
            let q = p.applying(t)
            (x0, y0, x1, y1) = (min(x0, q.x), min(y0, q.y), max(x1, q.x), max(y1, q.y))
        }
        return x0 <= x1 ? CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : .null
    }

    /// How far apart two boxes are, 0 when they meet; a point is a box of no size.
    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(max(a.minX - b.maxX, b.minX - a.maxX, 0), max(a.minY - b.maxY, b.minY - a.maxY, 0))
    }

    static func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }

    /// The ink on screen, in the reading frame, as cells a fraction of a cap square: each sample along a stroke, a cell
    /// apart, stamps its cell and the eight around it, and avoid polygons fill theirs. A summed-area table tells in
    /// constant time whether a rect meets a stamped cell.
    private struct Grid {
        let x0, y0, size: CGFloat
        let cols, rows: Int
        var ink: [UInt8], sums: [Int32] = []

        init(_ request: Request, frame: CGAffineTransform, cell: CGFloat) {
            let area = Room.box(request.screen, frame)
            (x0, y0, size) = (area.minX - cell, area.minY - cell, cell)
            cols = Int((area.width / cell).rounded(.up)) + 2
            rows = Int((area.height / cell).rounded(.up)) + 2
            ink = Array(repeating: 0, count: cols * rows)
            func turned(_ points: [CGPoint]) -> [CGPoint] { points.filter { $0.x.isFinite && $0.y.isFinite }.map { $0.applying(frame) } }
            for stroke in request.strokes { stamp(turned(stroke.points)) }
            for polygon in request.avoid.map(turned) where polygon.count > 2 {
                stamp(polygon + [polygon[0]])
                fill(polygon)
            }
            sums = Array(repeating: 0, count: (cols + 1) * (rows + 1))
            for r in 0 ..< rows {
                var run: Int32 = 0
                for c in 0 ..< cols {
                    run += Int32(ink[r * cols + c])
                    sums[(r + 1) * (cols + 1) + c + 1] = sums[r * (cols + 1) + c + 1] + run
                }
            }
        }

        /// Stamps samples a cell apart along a polyline, each with the eight cells around it.
        mutating func stamp(_ line: [CGPoint]) {
            var a = line.first ?? .zero
            for b in line {
                let n = max(1, Int(min(hypot(b.x - a.x, b.y - a.y) / size, 10_000).rounded(.up)))
                for k in 1 ... n {
                    let t = CGFloat(k) / CGFloat(n)
                    let c = ((a.x + (b.x - a.x) * t - x0) / size).rounded(.down), r = ((a.y + (b.y - a.y) * t - y0) / size).rounded(.down)
                    guard c >= -1, r >= -1, c <= CGFloat(cols), r <= CGFloat(rows) else { continue }
                    for row in max(Int(r) - 1, 0) ... min(Int(r) + 1, rows - 1) {
                        for col in max(Int(c) - 1, 0) ... min(Int(c) + 1, cols - 1) { ink[row * cols + col] = 1 }
                    }
                }
                a = b
            }
        }

        /// Stamps the cells whose middles are inside `polygon`, even-odd.
        mutating func fill(_ polygon: [CGPoint]) {
            let box = Room.box(polygon), edges = Array(zip(polygon, polygon.dropFirst() + [polygon[0]]))
            func index(_ v: CGFloat, _ count: Int) -> Int { Int(min(max(v, 0), CGFloat(count - 1))) }
            for row in index((box.minY - y0) / size, rows) ... index((box.maxY - y0) / size, rows) {
                for col in index((box.minX - x0) / size, cols) ... index((box.maxX - x0) / size, cols) {
                    let p = CGPoint(x: x0 + (CGFloat(col) + 0.5) * size, y: y0 + (CGFloat(row) + 0.5) * size)
                    var inside = false
                    for (a, b) in edges where (a.y > p.y) != (b.y > p.y) && p.x < a.x + (b.x - a.x) * (p.y - a.y) / (b.y - a.y) { inside.toggle() }
                    if inside { ink[row * cols + col] = 1 }
                }
            }
        }

        /// Whether `rect` meets no stamped cell; cells it only touches along an edge don't count.
        func free(_ rect: CGRect) -> Bool {
            guard !rect.isNull else { return false }
            func index(_ v: CGFloat, _ rule: FloatingPointRoundingRule, _ count: Int) -> Int { Int(min(max(v.rounded(rule), 0), CGFloat(count))) }
            let c0 = index((rect.minX - x0) / size, .down, cols), c1 = index((rect.maxX - x0) / size, .up, cols)
            let r0 = index((rect.minY - y0) / size, .down, rows), r1 = index((rect.maxY - y0) / size, .up, rows), w = cols + 1
            return sums[r1 * w + c1] - sums[r0 * w + c1] - sums[r1 * w + c0] + sums[r0 * w + c0] == 0
        }

        /// Whether the cell under `p` is stamped.
        func inked(_ p: CGPoint) -> Bool {
            let c = ((p.x - x0) / size).rounded(.down), r = ((p.y - y0) / size).rounded(.down)
            return c >= 0 && r >= 0 && c < CGFloat(cols) && r < CGFloat(rows) && ink[Int(r) * cols + Int(c)] != 0
        }
    }
}
