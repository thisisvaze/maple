import CoreGraphics
import Foundation

/// Which of the latest strokes make up the mark someone just made. Pure geometry and timing, so it checks on the Mac.
nonisolated enum Grouping {
    struct Stroke {
        var id: String
        var bounds: CGRect  // page points
        var started, ended: TimeInterval
    }

    /// The last stroke and the strokes written just before it, close by, up to four: a `?` drawn in one or two pauses,
    /// or the end of a sentence. A `?`'s dot joins its hook even after an 8 s pause, and may sit a whole hook below it.
    static func candidate(_ strokes: [Stroke]) -> [String] {
        guard let last = strokes.last else { return [] }
        var chosen = [last]
        for previous in strokes.dropLast().reversed().prefix(7) {
            let hook = previous.bounds, dot = last.bounds
            let isDotOfHook = chosen.count == 1 && last.started - previous.ended <= 8
                && max(dot.width, dot.height) <= max(12, hook.height * 0.35) && hook.height > dot.height * 2
                && dot.midY >= hook.midY && dot.minY - hook.maxY <= max(18, hook.height * 1.25)
                && abs(dot.midX - hook.midX) <= max(14, hook.width)
            if isDotOfHook { chosen.append(previous); break }
            let group = chosen.reduce(CGRect.null) { $0.union($1.bounds) }
            guard last.started - previous.ended <= 1.2, hook.insetBy(dx: -16, dy: -16).intersects(group) else { break }
            chosen.append(previous)
            if chosen.count == 4 { break }
        }
        return chosen.reversed().map(\.id)
    }

    /// Two taps of the nib in one spot within `gap` seconds: "look here". In a picture two taps look like one dot, so
    /// this is read from timing on the device. `reach` (page points) is how far apart the taps may land; a colon lands
    /// further apart, and a third quick dot before them makes an ellipsis, not a double dot.
    static func doubleDot(_ strokes: [Stroke], reach: CGFloat, gap: TimeInterval = 0.4) -> [String]? {
        func isDot(_ s: Stroke) -> Bool { max(s.bounds.width, s.bounds.height) <= 6 + reach }
        guard strokes.count >= 2 else { return nil }
        let a = strokes[strokes.count - 2], b = strokes[strokes.count - 1]
        guard isDot(a), isDot(b), b.started - a.ended <= gap,
              hypot(a.bounds.midX - b.bounds.midX, a.bounds.midY - b.bounds.midY) <= reach else { return nil }
        if strokes.count >= 3, case let c = strokes[strokes.count - 3], isDot(c), a.started - c.ended <= gap { return nil }
        return [a.id, b.id]
    }
}
