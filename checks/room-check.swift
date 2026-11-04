// swiftc -swift-version 6 -O -parse-as-library Maple/Room.swift checks/room-check.swift -o /tmp/room-check && /tmp/room-check
import CoreGraphics
import Foundation

@main
struct Check {
    typealias Stroke = Room.Stroke

    /// A made-up hand, one zigzag stroke per letter across its box: capitals, digits and ascenders `h` tall, other letters
    /// 0.6 h, descenders 0.35 h under the baseline; = and - are bars, ² a small raised digit, ? a hook and a dot. Returns
    /// the strokes and where the next letter starts.
    static func write(_ text: String, x: CGFloat, base: CGFloat, h: CGFloat, mark: Bool = false) -> (strokes: [Stroke], end: CGFloat) {
        func zigzag(_ x0: CGFloat, _ top: CGFloat, _ w: CGFloat, _ tall: CGFloat) -> [CGPoint] {
            dense([0, 0.25, 0.5, 0.75, 1].enumerated().map { CGPoint(x: x0 + w * $1, y: $0 % 2 == 0 ? top + tall : top) })
        }
        func bar(_ x0: CGFloat, _ y: CGFloat, _ w: CGFloat) -> [CGPoint] { dense([CGPoint(x: x0, y: y), CGPoint(x: x0 + w, y: y)]) }
        var strokes: [Stroke] = [], x = x
        for c in text {
            let lines: [[CGPoint]]
            switch c {
            case " ": x += 0.5 * h; continue
            case "?": lines = [zigzag(x, base - h, 0.5 * h, 0.7 * h), zigzag(x + 0.2 * h, base - 0.1 * h, 0.1 * h, 0.1 * h)]
            case "=": lines = [bar(x, base - 0.55 * h, 0.6 * h), bar(x, base - 0.35 * h, 0.6 * h)]
            case "-": lines = [bar(x, base - 0.4 * h, 0.4 * h)]
            case "²": lines = [zigzag(x, base - h, 0.35 * h, 0.4 * h)]
            case _ where "acemnorsuvwxz".contains(c): lines = [zigzag(x, base - 0.6 * h, 0.55 * h, 0.6 * h)]
            case _ where "gjpqy".contains(c): lines = [zigzag(x, base - 0.6 * h, 0.55 * h, 0.95 * h)]
            default: lines = [zigzag(x, base - h, 0.55 * h, h)]
            }
            strokes += lines.map { Stroke(points: $0, person: true, mark: mark) }
            x = lines.joined().map(\.x).max()! + 0.15 * h
        }
        return (strokes, x)
    }

    /// Points along a polyline about 3 pt apart, the way the app samples a stroke.
    static func dense(_ corners: [CGPoint]) -> [CGPoint] {
        var out = [corners[0]]
        for (a, b) in zip(corners, corners.dropFirst()) {
            let n = max(1, Int((hypot(b.x - a.x, b.y - a.y) / 3).rounded(.up)))
            out += (1 ... n).map { CGPoint(x: a.x + (b.x - a.x) * CGFloat($0) / CGFloat(n), y: a.y + (b.y - a.y) * CGFloat($0) / CGFloat(n)) }
        }
        return out
    }

    /// A scribbled letter of 30 points, `w` wide and 16 tall.
    static func scribble(_ x: CGFloat, _ y: CGFloat, w: CGFloat = 11, person: Bool = false) -> Stroke {
        Stroke(points: (0 ..< 30).map { i in
            let t = CGFloat(i) / 29
            return CGPoint(x: x + w * t, y: y + 16 * abs((t * 4).truncatingRemainder(dividingBy: 2) - 1))
        }, person: person, mark: false)
    }

    /// Rows of scribbles filling `rect`: ink in the way, not part of the question's line.
    static func fill(_ rect: CGRect) -> [Stroke] {
        stride(from: rect.minY, to: rect.maxY, by: 20).flatMap { y in stride(from: rect.minX, to: rect.maxX, by: 13).map { scribble($0, y) } }
    }

    /// The strokes turned `degrees` about `center`, against the clock on screen for positive degrees (a line rising to
    /// the right), as writing on a slant.
    static func slanted(_ strokes: [Stroke], _ degrees: CGFloat, about center: CGPoint) -> [Stroke] {
        let t = CGAffineTransform(translationX: -center.x, y: -center.y).concatenating(CGAffineTransform(rotationAngle: -degrees * .pi / 180))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        return strokes.map { Stroke(points: $0.points.map { $0.applying(t) }, person: $0.person, mark: $0.mark) }
    }

    /// Two dots tapped in the middle of `letter`, as a double dot.
    static func dots(on letter: Stroke) -> [Stroke] {
        let r = Room.box(letter.points)
        return [CGPoint(x: r.midX, y: r.midY), CGPoint(x: r.midX + 1.5, y: r.midY + 1)].map {
            Stroke(points: [$0, CGPoint(x: $0.x + 0.5, y: $0.y + 0.5)], person: true, mark: true)
        }
    }

    /// A 1180 × 820 screen's corners in page points, clockwise from top-left, at `zoom` with the page turned by `turn`.
    static func request(_ strokes: [Stroke], doubleDot: Bool = false, avoid: [[CGPoint]] = [], zoom: CGFloat = 1, turn: CGFloat = 0, nib: CGPoint? = nil) -> Room.Request {
        let screen = [CGPoint(x: 0, y: 0), CGPoint(x: 1180, y: 0), CGPoint(x: 1180, y: 820), CGPoint(x: 0, y: 820)].map {
            CGPoint(x: $0.x / zoom, y: $0.y / zoom).applying(CGAffineTransform(rotationAngle: -turn))
        }
        return Room.Request(strokes: strokes, doubleDot: doubleDot, screen: screen, avoid: avoid, screenAngle: turn, zoom: zoom, nib: nib)
    }

    /// The fake pen: about 0.8 cap a character, wrapped by count. Its extent starts 0.2 cap over the first capital and
    /// ends under the last line's descenders.
    static func layout(_ count: Int) -> (CGFloat, CGFloat) -> (extent: CGRect, rows: Int) {
        { cap, width in
            let perRow = max(1, Int(width / (0.8 * cap))), rows = (count + perRow - 1) / perRow
            return (CGRect(x: 0, y: -0.2 * cap, width: CGFloat(min(count, perRow)) * 0.8 * cap, height: (CGFloat(rows - 1) * 1.6 + 1.35 + 0.2) * cap), rows)
        }
    }

    /// Places "x = 7 or x = -7" (16 characters) by default, and checks it lands on screen, every ink point a grid cell (a
    /// quarter of the question's cap) clear of its block, and any leader running from the mark's edge to the block's.
    static func place(_ request: Room.Request, text: Int = 16) -> Room.Placement? {
        guard let p = Room.place(request, layout: layout(text)) else { return nil }
        let screen = Room.box(request.screen, CGAffineTransform(rotationAngle: request.screenAngle)).insetBy(dx: p.cap - 0.01, dy: p.cap - 0.01)
        let toScreen = CGAffineTransform(rotationAngle: request.screenAngle - p.angle), r = p.rect
        for corner in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)] {
            precondition(screen.contains(corner.applying(toScreen)), "off screen: \(p)")
        }
        let frame = CGAffineTransform(rotationAngle: p.angle), line = Room.line(request, at: p.angle)!
        func point(_ q: CGPoint) -> CGRect { CGRect(origin: q, size: .zero) }
        for q in request.strokes.flatMap(\.points).map({ $0.applying(frame) }) {
            precondition(Room.distance(point(q), r) >= 0.25 * line.cap - 0.01, "ink \(Room.distance(point(q), r)) pt from the block at \(q): \(p)")
        }
        precondition((p.kind == .leader) == !p.leader.isEmpty, "a leader only for .leader: \(p)")
        if let start = p.leader.first?.first?.applying(frame), let end = p.leader.last?.last?.applying(frame) {
            let edge = line.mark.insetBy(dx: 0.01, dy: 0.01)
            precondition(Room.distance(point(start), line.mark) < 0.01 && !edge.contains(start), "the leader starts off the mark's edge: \(p)")
            precondition(Room.distance(point(end), r) < 0.01 && !r.insetBy(dx: 0.01, dy: 0.01).contains(end), "the leader stops short of the block: \(p)")
        }
        return p
    }

    /// How close a leader's line comes to any ink, away from its first and last 0.75 cap of the question's `cap`.
    static func clearance(_ p: Room.Placement, _ strokes: [Stroke], cap: CGFloat) -> CGFloat {
        guard let a = p.leader.first?.first, let b = p.leader.last?.last else { return .infinity }
        let length = hypot(b.x - a.x, b.y - a.y)
        let ink = strokes.flatMap { s in zip(s.points, s.points.dropFirst()).map { ($0, $1) } }
        func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
            let t = l2 == 0 ? 0 : min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / l2, 0), 1)
            return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
        }
        return stride(from: 0.75 * cap, through: length - 0.75 * cap, by: 0.5).map { t in
            let q = CGPoint(x: a.x + (b.x - a.x) * t / length, y: a.y + (b.y - a.y) * t / length)
            return ink.reduce(CGFloat.infinity) { min($0, distance(q, $1.0, $1.1)) }
        }.min() ?? .infinity
    }

    static func main() {
        func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool { abs(a - b) <= tolerance }
        let h: CGFloat = 28, base: CGFloat = 300

        // "x² = 49 ?" on an empty page: written after the ?, 0.6 cap on, its capitals 0.9 of the ?'s height.
        let sum = write("x² = 49 ", x: 200, base: base, h: h), q = write("?", x: sum.end, base: base, h: h, mark: true)
        let question = sum.strokes + q.strokes, mark = Room.box(q.strokes.flatMap(\.points)), cap = 0.9 * mark.height
        let first = place(request(question))!
        precondition(first.kind == .sameLine && near(first.cap, cap) && first.angle == 0, "\(first)")
        precondition(near(first.origin.x, mark.maxX + 0.6 * cap) && near(first.origin.y, mark.maxY - cap), "\(first.origin)")

        // "75% of 500 g =", the = a blank to fill: the value goes after it at the letters' size, on their baseline, not
        // at the = sign's own small height and raised bottom.
        let sentence = write("75% of 500 g ", x: 200, base: base, h: h), equals = write("=", x: sentence.end, base: base, h: h, mark: true)
        let blank = Room.box(equals.strokes.flatMap(\.points)), letterCap = 0.9 * h  // the median letter is h tall
        let unsized = place(request(sentence.strokes + equals.strokes))!
        var trailing = request(sentence.strokes + equals.strokes)
        trailing.trailing = true
        let filled = place(trailing)!
        precondition(unsized.cap < letterCap / 2, "without trailing, the = sets the size: \(unsized)")
        precondition(filled.kind == .sameLine && near(filled.cap, letterCap) && near(filled.origin.x, blank.maxX + 0.6 * letterCap)
                     && near(filled.origin.y, base - letterCap), "a blank after = is filled at the letters' size: \(filled)")

        // A list, "- Hotel 412" over "- Taxi 38", and an empty dash under it: the item goes after the dash at the size of
        // the letters over it, its baseline half an x-height under the dash, and nowhere once the person starts writing it.
        let listed = write("- Hotel 412", x: 200, base: 420, h: h).strokes + write("- Taxi 38", x: 200, base: 420 + 1.8 * h, h: h).strokes
        let row = 420 + 3.6 * h, dash = write("-", x: 200, base: row, h: h, mark: true), dashBox = Room.box(dash.strokes.flatMap(\.points))
        var bullet = request(listed + dash.strokes)
        bullet.bullet = true
        let item = place(bullet)!
        precondition(item.kind == .sameLine && near(item.cap, letterCap) && near(item.origin.x, dashBox.maxX + 0.6 * letterCap)
                     && near(item.origin.y, dashBox.midY + 0.35 * letterCap - letterCap), "an empty bullet is filled at the list's size: \(item)")
        var byHand = request(listed + dash.strokes + write("Sun", x: dash.end + 0.4 * h, base: row, h: h).strokes)
        byHand.bullet = true
        precondition(place(byHand) == nil, "a bullet being filled in by hand is left alone")
        // The pen already on the next bullet, a line down, doesn't push this one's item away.
        bullet.nib = CGPoint(x: dashBox.maxX, y: dashBox.midY + 1.8 * h)
        precondition(place(bullet)?.kind == .sameLine, "the next bullet drawn before this one is filled")
        // Under a row Maple filled, a dash and its blue item, the next bullet still takes the person's letters' size.
        let filledRow = write("-", x: 200, base: row, h: h).strokes + write("Sunscreen", x: 230, base: row, h: h).strokes.map {
            Stroke(points: $0.points, person: false, mark: false)
        }
        let nextDash = write("-", x: 200, base: row + 1.8 * h, h: h, mark: true)
        var underFilled = request(listed + filledRow + nextDash.strokes)
        underFilled.bullet = true
        let nextItem = place(underFilled)!
        precondition(nextItem.kind == .sameLine && near(nextItem.cap, letterCap), "the size of the person's list, past Maple's row: \(nextItem)")

        // A … on its own line under that list carries it on down the page: from the line under the dots, at their left
        // edge, at the list's size. Without `down` it would go after the dots.
        let ellipsis = (0 ..< 3).map { i in
            Stroke(points: [CGPoint(x: 200 + CGFloat(i) * 0.3 * h, y: row - 1), CGPoint(x: 200.5 + CGFloat(i) * 0.3 * h, y: row)], person: true, mark: true)
        }
        var carried = request(listed + ellipsis)
        carried.trailing = true
        precondition(place(carried)!.kind == .sameLine, "along the line")
        carried.down = true
        for text in [30, 8] {  // three items, or just one
            let grown = place(carried, text: text)!
            precondition(grown.kind == .nextLine && near(grown.cap, letterCap) && near(grown.origin.x, 200) && near(grown.origin.y, row + 0.5 * letterCap),
                         "a list carried on starts under the dots: \(grown)")
        }
        // A … along a line, after letters, is carried on after it even so.
        let sequence = write("1 2 3 5 ", x: 200, base: row, h: h).strokes + ellipsis.map { Stroke(points: $0.points.map { CGPoint(x: $0.x + 4.2 * h, y: $0.y) }, person: true, mark: true) }
        var inline = request(sequence)
        (inline.trailing, inline.down) = (true, true)
        precondition(place(inline)?.kind == .sameLine, "a … ending a line of letters stays on it")

        // More writing after the ? on that line: under the line from its left edge, 0.5 cap below its band (a descender).
        let more = question + write(" and why", x: q.end, base: base, h: h).strokes, band = Room.box(more.flatMap(\.points))
        let next = place(request(more))!
        precondition(next.kind == .nextLine && near(next.origin.x, band.minX) && near(next.origin.y, band.maxY + 0.5 * cap), "\(next)")

        // A ? by the right edge: never off screen (place checks every block's corners).
        let edge = write("x² = 49 ", x: 950, base: base, h: h), edgeQ = write("?", x: edge.end, base: base, h: h, mark: true)
        precondition(edgeQ.end > 1080 && place(request(edge.strokes + edgeQ.strokes)) != nil, "by the edge")

        // A line of the person's 1.2 to 1.8 ?-heights under the question, or one of descenders over it: wherever the answer
        // goes, it keeps a cell clear of them (place checks), at every alignment with the grid.
        for spacing in stride(from: 1.2 * h, through: 1.8 * h, by: 1) {
            for dy in stride(from: CGFloat(0), to: 6.3, by: 1.5) {
                let under = write("the next line goes all the way across", x: 120, base: base + spacing + dy, h: h)
                let over = write("gypsy jumpy query gappy gypsy jumpy", x: 120, base: base - spacing + dy, h: h)
                precondition(place(request(question + under.strokes)) != nil && place(request(question + over.strokes)) != nil, "a line by the question")
            }
        }

        // Ink filling the right side and the lines below: a gap, over the line.
        let line = Room.box(question.flatMap(\.points))
        let crowded = question + fill(CGRect(x: mark.maxX + 20, y: 0, width: 1180, height: 820)) + fill(CGRect(x: 0, y: base + 25, width: 1180, height: 600))
        let gap = place(request(crowded))!
        precondition(gap.kind == .gap && gap.rect.maxY <= line.minY && gap.leader.isEmpty, "\(gap)")

        // Ink over the line too, but for a corridor up from the ?: the answer goes high up, its leader clear of the ink.
        let sum2 = write("x² = 49 ", x: 450, base: base, h: h), q2 = write("?", x: sum2.end, base: base, h: h, mark: true)
        let mark2 = Room.box(q2.strokes.flatMap(\.points)), line2 = Room.box((sum2.strokes + q2.strokes).flatMap(\.points))
        let walled = sum2.strokes + q2.strokes + fill(CGRect(x: mark2.maxX + 20, y: 220, width: 1180, height: 600))
            + fill(CGRect(x: 0, y: base + 25, width: 1180, height: 600)) + fill(CGRect(x: 0, y: line2.minY - 15, width: line2.minX - 10, height: 60))
            + fill(CGRect(x: 0, y: 220, width: mark2.midX - 20, height: line2.minY - 235))
            + fill(CGRect(x: mark2.midX + 20, y: 220, width: 1180, height: line2.minY - 235))
        let led = place(request(walled))!
        let ledClear = clearance(led, walled, cap: cap)
        precondition(led.kind == .leader && led.rect.maxY <= 220 && ledClear > 0, "\(led) clearance \(ledClear)")

        // The page turned 20° on screen: the same answer in the reading frame.
        let turn = 20 * CGFloat.pi / 180, r20 = CGAffineTransform(rotationAngle: -turn)
        let turned = place(request(question.map { Stroke(points: $0.points.map { $0.applying(r20) }, person: $0.person, mark: $0.mark) }, turn: turn))!
        precondition(near(turned.angle, turn, 1e-9) && turned.kind == first.kind && near(turned.cap, first.cap) && near(turned.width, first.width)
            && near(turned.origin.x, first.origin.x) && near(turned.origin.y, first.origin.y) && near(turned.rect.maxX, first.rect.maxX)
            && near(turned.rect.maxY, first.rect.maxY), "\(turned)")

        // Handwriting slanted on a level page, 12° up, and steeper, up and down: the frame squares to it. Written level, it
        // stays level.
        for (degrees, y) in [(CGFloat(12), CGFloat(500)), (25, 500), (-40, 300)] {
            let long = write("so if x² = 49 then x is ", x: 150, base: y, h: h), longQ = write("?", x: long.end, base: y, h: h, mark: true)
            let tilted = place(request(slanted(long.strokes + longQ.strokes, degrees, about: CGPoint(x: 150, y: y))))!
            precondition(abs(tilted.angle * 180 / .pi - degrees) < 1, "\(degrees)° squared to \(tilted.angle * 180 / .pi)°")
            precondition(degrees != 12 || place(request(long.strokes + longQ.strokes))!.angle == 0, "a level line keeps the screen's frame")
        }

        // Short equations, gentle tilts and descenders still provide a baseline, even on a rotated page.
        for text in ["x² = 49 ", "2+2 ", "why ", "gypsy jumpy query "] {
            let words = write(text, x: 200, base: base, h: h), end = write("?", x: words.end, base: base, h: h, mark: true)
            for degrees: CGFloat in [0, 3, -3, 12, -25, 40] {
                for pageDegrees: CGFloat in [0, 20] {
                    let tilted = slanted(words.strokes + end.strokes, degrees, about: CGPoint(x: 200, y: base))
                    let page = slanted(tilted, pageDegrees, about: .zero)
                    let answer = place(request(page, turn: pageDegrees * .pi / 180))!
                    precondition(abs(answer.angle * 180 / .pi - pageDegrees - degrees) < 1,
                                 "\(text)? at \(degrees)° on a \(pageDegrees)° page squared to \(answer.angle * 180 / .pi)°")
                }
            }
        }
        let lone = slanted(q.strokes, 12, about: CGPoint(x: 200, y: base))
        precondition(place(request(lone))!.angle == 0, "a lone question mark cannot establish a baseline")

        // A paragraph: a short question line in it, written level, stays level, though a slant across its lines finds a
        // longer band. The whole paragraph written 20° up squares to it.
        let notes = ["the first line of my notes runs on", "and the second line is here too", "", "a fourth line with gypsy jumpy words", "and the last line of it all ends"]
        let paragraph = notes.enumerated().flatMap { write($1, x: 100, base: 200 + CGFloat($0) * 1.6 * 20, h: 20).strokes }
        for x: CGFloat in [100, 250, 400] {
            let why = write("why ", x: x, base: 264, h: 20), whyQ = write("?", x: why.end, base: 264, h: 20, mark: true)
            precondition(place(request(paragraph + why.strokes + whyQ.strokes))!.angle == 0, "a short line in a paragraph turned")
        }
        let so = write("so is x² = 49 ", x: 100, base: 264, h: 20), soQ = write("?", x: so.end, base: 264, h: 20, mark: true)
        let sloped = place(request(slanted(paragraph + so.strokes + soQ.strokes, 20, about: CGPoint(x: 300, y: 300))))!
        precondition(abs(sloped.angle * 180 / .pi - 20) < 1, "a slanted paragraph squared to \(sloped.angle * 180 / .pi)°")

        // The pen just after the ?: the person may still be writing there, so not on that line, and 4 caps clear.
        let nib = CGPoint(x: mark.maxX + 6, y: mark.midY)
        let nibbed = place(request(question, nib: nib))!
        precondition(nibbed.kind != .sameLine && Room.distance(CGRect(origin: nib, size: .zero), nibbed.rect) >= 4 * cap, "\(nibbed)")

        // A double dot on a word 24 pt tall: capitals from the letters, not the 12-point floor, and the band is that line.
        let above = write("THE CAT SAT", x: 150, base: 250, h: 24), words = write("HELLO BRAVE WORLD", x: 150, base: 300, h: 24)
        let dotted = request(above.strokes + words.strokes + dots(on: words.strokes[6]), doubleDot: true)  // on the R of BRAVE
        let wordLine = Room.box(words.strokes.flatMap(\.points)), brave = Room.box(words.strokes[5 ..< 10].flatMap(\.points))
        let found = Room.line(dotted, at: 0)!
        precondition(near(found.cap, 0.9 * 24) && found.band == wordLine && near(found.capTop, 300 - 0.9 * 24) && found.mark.contains(brave), "\(found)")
        let explained = place(dotted)!
        precondition(explained.kind == .nextLine && near(explained.cap, 0.9 * 24) && near(explained.origin.x, wordLine.minX)
            && near(explained.origin.y, wordLine.maxY + 0.5 * 0.9 * 24), "\(explained)")

        // Double dots also follow a short word's baseline.
        let hello = write("HELLO", x: 150, base: 300, h: 24).strokes
        for degrees: CGFloat in [3, -12, 25] {
            let ink = slanted(hello + dots(on: hello[2]), degrees, about: CGPoint(x: 150, y: 300))
            precondition(abs(place(request(ink, doubleDot: true))!.angle * 180 / .pi - degrees) < 1, "slanted double dot")
        }

        // Written 12 pt tall, with the next line right under it: the band stays the dotted line.
        for spacing: CGFloat in [1.4, 1.6] {
            let small = write("HELLO BRAVE WORLD", x: 150, base: 300, h: 12), next = write("HELLO BRAVE WORLD", x: 150, base: 300 + spacing * 12, h: 12)
            let tight = request(small.strokes + next.strokes + dots(on: small.strokes[6]), doubleDot: true)
            precondition(Room.line(tight, at: 0)!.band == Room.box(small.strokes.flatMap(\.points)) && place(tight) != nil, "the line under it at \(spacing)")
        }

        // Dots on the last word of a line: the answer goes after the word, not into it.
        let learned = write("WE LEARNED ABOUT PHOTOSYNTHESIS", x: 100, base: 300, h: 24), then = write("AND THEN WE WROTE IT DOWN", x: 100, base: 338.4, h: 24)
        let lastWord = Room.box(learned.strokes.suffix(14).flatMap(\.points))
        let after = place(request(learned.strokes + then.strokes + dots(on: learned.strokes[learned.strokes.count - 10]), doubleDot: true))!
        precondition(after.kind == .sameLine && near(after.origin.x, lastWord.maxX + 0.6 * after.cap), "\(after)")

        // Dots on a word in the middle of a paragraph, the screen otherwise empty: no leader is clear of the lines over and
        // under the word, so one crosses the next line by the mark.
        let lines = ["THE CAT SAT ON THE MAT", "HELLO BRAVE WORLD AGAIN", "ANOTHER LINE BELOW IT"].enumerated().map { write($1, x: 150, base: 261.6 + CGFloat($0) * 38.4, h: 24) }
        let inside = place(request(lines.flatMap(\.strokes) + dots(on: lines[1].strokes[6]), doubleDot: true))!
        precondition(inside.kind == .leader, "\(inside)")

        // Something over the obvious spot: the block moves off it.
        let spot = first.rect.insetBy(dx: -4, dy: -4)
        let moved = place(request(question, avoid: [[CGPoint(x: spot.minX, y: spot.minY), CGPoint(x: spot.maxX, y: spot.minY),
                                                     CGPoint(x: spot.maxX, y: spot.maxY), CGPoint(x: spot.minX, y: spot.maxY)]]))!
        precondition(moved.origin != first.origin && moved.rect.intersection(spot).isEmpty, "\(moved)")

        // A long line running in from off the left edge, the ? at its end, writing after it: the band stops near 25 caps
        // whichever order the strokes come in, so the answer still goes under the line.
        let runOn = write("then we know that the answer must be that x is equal to ", x: -20, base: base, h: h).strokes.filter { $0.points.allSatisfy { $0.x < 900 } }
        let runQ = write("?", x: runOn.flatMap(\.points).map(\.x).max()! + 0.15 * h, base: base, h: h, mark: true)
        let wall = fill(CGRect(x: runQ.end + 30, y: 250, width: 400, height: 70))
        for strokes in [runOn + runQ.strokes + wall, (runOn + runQ.strokes + wall).reversed()] {
            let bounded = place(request(strokes))!, run = Room.line(request(strokes), at: 0)!
            precondition(bounded.kind == .nextLine && run.band.width < 27 * run.cap, "\(bounded), band \(run.band.width / run.cap) caps")
        }

        // A point or an avoid corner that isn't a number is left out, not a crash.
        let nan = Stroke(points: [CGPoint(x: 100, y: 100), CGPoint(x: CGFloat.nan, y: 100)], person: true, mark: false)
        precondition(Room.place(request(question + [nan], avoid: [[.zero, CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 10, y: 10)]]), layout: layout(16)) == first, "NaN")

        // No room: a full page, or an answer too long for 8 lines at any width.
        precondition(place(request(question + fill(CGRect(x: 0, y: 0, width: 1180, height: 820)))) == nil, "a full page")
        precondition(place(request(question), text: 2000) == nil, "too long")

        // Caps clamp in screen points: 28-point letters at zoom 2 would be 50 on screen, so 26; 20-point ones at 0.5, 9, so 12.
        let small = write("x² = 49 ", x: 60, base: 150, h: 28), smallQ = write("?", x: small.end, base: 150, h: 28, mark: true)
        let zoomed = place(request(small.strokes + smallQ.strokes, zoom: 2))!
        precondition(zoomed.kind == .sameLine && near(zoomed.cap * 2, 26), "\(zoomed)")
        let tiny = write("x² = 49 ", x: 400, base: 600, h: 20), tinyQ = write("?", x: tiny.end, base: 600, h: 20, mark: true)
        let wide = place(request(tiny.strokes + tinyQ.strokes, zoom: 0.5))!
        precondition(wide.kind == .sameLine && near(wide.cap * 0.5, 12), "\(wide)")

        // A screen full of ink, 3000 strokes of 30 points with the ? among them: nothing fits. Then with room only in a
        // far corner, which its leader can't reach. Both search every gap.
        var page: [Stroke] = []
        for row in 0 ..< 30 {
            for col in 0 ..< 100 where !(row == 12 && col == 50) { page.append(scribble(8 + CGFloat(col) * 11.6, 6 + CGFloat(row) * 27, w: 9, person: true)) }
        }
        page += write("?", x: 8 + 50 * 11.6, base: 6 + 12 * 27 + 16, h: 20, mark: true).strokes
        let window = CGRect(x: 0, y: 0, width: 360, height: 110)
        let clock = ContinuousClock()
        var slowest: Double = 0
        for (name, strokes) in [("full", page), ("corner", page.filter { $0.mark || !window.contains($0.points[0]) })] {
            let busy = request(strokes)
            var placed: Room.Placement?, best = Double.infinity
            for _ in 0 ..< 5 {
                let took = clock.measure { placed = Room.place(busy, layout: layout(16)) }
                best = min(best, Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15)
            }
            print("room: \(strokes.count) strokes (\(name)) in \(String(format: "%.1f", best)) ms: \(placed.map(\.kind.rawValue) ?? "no room")")
            slowest = max(slowest, best)
        }
        precondition(slowest < 30, "too slow: \(slowest) ms")
        print("room ok")
    }
}
