// swiftc -swift-version 6 -parse-as-library Maple/Grouping.swift checks/grouping-check.swift -o /tmp/grouping-check && /tmp/grouping-check
import CoreGraphics

@main
struct Check {
    static func s(_ id: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ t0: Double, _ t1: Double) -> Grouping.Stroke {
        Grouping.Stroke(id: id, bounds: CGRect(x: x, y: y, width: w, height: h), started: t0, ended: t1)
    }

    static func main() {
        // "x² = 49" written, then a ? hook, then its dot after a 3 s pause: the hook and dot, not the sum.
        let sum = [s("x", 0, 0, 20, 20, 0, 0.3), s("2", 22, -6, 8, 10, 0.5, 0.7), s("=", 40, 5, 16, 8, 1, 1.2), s("49", 64, 0, 30, 22, 1.4, 1.9)]
        let hook = s("hook", 110, -4, 14, 22, 5, 5.4), dot = s("dot", 114, 26, 3, 3, 8.4, 8.45)
        precondition(Grouping.candidate(sum + [hook, dot]) == ["hook", "dot"], "a ? is its hook and dot")
        precondition(Grouping.candidate(sum + [hook]) == ["hook"], "a hook alone, before its dot")
        // Quick writing groups the last strokes that touch, up to four.
        precondition(Grouping.candidate(sum) == ["x", "2", "=", "49"], "\(Grouping.candidate(sum))")
        precondition(Grouping.candidate([]) == [], "nothing written")

        // Two nib taps in one spot, 0.2 s apart: a double dot. A colon is too far apart; three quick dots are an ellipsis.
        let tap1 = s("t1", 200, 200, 2, 2, 10, 10.02), tap2 = s("t2", 201, 201, 2, 2, 10.2, 10.22)
        precondition(Grouping.doubleDot(sum + [tap1, tap2], reach: 4) == ["t1", "t2"], "double dot")
        precondition(Grouping.doubleDot([tap1, s("t2", 201, 214, 2, 2, 10.2, 10.22)], reach: 4) == nil, "a colon")
        precondition(Grouping.doubleDot([tap1, s("t2", 201, 201, 2, 2, 11, 11.02)], reach: 4) == nil, "too slow")
        let tap0 = s("t0", 199, 200, 2, 2, 9.7, 9.72)
        precondition(Grouping.doubleDot([tap0, tap1, tap2], reach: 4) == nil, "an ellipsis")
        print("grouping ok")
    }
}
