import CoreGraphics
import Foundation

/// What Maple has read on a page, kept beside its ink in readings.json: each piece of the person's writing as text, and
/// each mark Jev named, with where it sits and the strokes it's made of. Facts, never meanings: what the writing is for,
/// and how the pieces connect, is left to the model that gets them with the page's pictures.
nonisolated struct Reading: Codable, Equatable, Sendable {
    var strokes: [String]  // the strokes it reads; a newer reading of any of them replaces this one
    var kind: String  // what Jev saw: "writing", "arrow", "circle", "box", "underline", "frame", "question", ...
    var text: String?  // what it says, for writing and for the marks Muse read; nil until read, "" when it says nothing
    var rect: CGRect  // where, in page points in the frame turned by `turn`
    var turn: CGFloat

    /// Kinds whose words Maple reads itself; the marks it answers are read by the answer.
    static let worded: Set<String> = ["writing", "other"]
    static let kept = 400  // calibration knob: readings a page keeps, newest first; old ones of erased ink go first

    /// Writing no one has read yet.
    var unread: Bool { text == nil && Self.worded.contains(kind) }

    /// `readings` with `new` in place of any reading of the same strokes, newest last: a line read again as it grows
    /// replaces its shorter reading.
    static func replacing(_ readings: [Reading], with new: Reading) -> [Reading] {
        let strokes = Set(new.strokes)
        return readings.filter { strokes.isDisjoint(with: $0.strokes) } + [new]
    }

    /// Where it sits in the frame turned by `turn` instead: its corners carried over and boxed again.
    func rect(in turn: CGFloat) -> CGRect {
        guard turn != self.turn else { return rect }
        let across = CGAffineTransform(rotationAngle: -self.turn).concatenating(CGAffineTransform(rotationAngle: turn))
        return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            .reduce(CGRect.null) { $0.union(CGRect(origin: $1.applying(across), size: .zero)) }
    }

    static func load(_ url: URL) -> [Reading] {
        (try? JSONDecoder().decode([Reading].self, from: Data(contentsOf: url))) ?? []
    }

    /// The `kept` newest, keeping first those whose strokes are all on the page, `present`: undo can bring erased
    /// ink back, so its readings stay while there's room.
    static func trimmed(_ readings: [Reading], present: Set<String>) -> [Reading] {
        guard readings.count > kept else { return readings }
        let live = readings.filter { present.isSuperset(of: $0.strokes) }
        let spare = max(0, kept - live.count)
        let gone = readings.filter { !present.isSuperset(of: $0.strokes) }.suffix(spare)
        return readings.filter { r in live.contains(r) || gone.contains(r) }.suffix(kept)
    }
}
