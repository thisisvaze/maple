import CoreGraphics
import Foundation

/// An answer on the page, saved in the page's notes.json.
nonisolated struct Note: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var mark: String  // "question", "double_dot", or "frame" for a drawing in a box
    var trigger: [String]  // ids of the strokes it answers
    var anchor: CGPoint  // page point at the mark's top right, where its dot sits
    var zoom: CGFloat  // the page's zoom when the mark was made; the bubble is sized for it and grows with the page
    var reading: String
    var reply: String
    var steps: [String]  // a ?'s nudge and hint, opened one at a time before the answer
    var stage = 0  // how far it's open: 0 shows the first part, steps.count shows the answer too

    var parts: [String] { steps + [reply] }
    /// What the person has opened so far; follow-ups build on this, not on unopened steps.
    var shown: String { parts.prefix(stage + 1).joined(separator: "\n\n") }
    var finished: Bool { stage >= steps.count }
}
