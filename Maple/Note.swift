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
    var reply: String  // the answer, or for a drawing, one line about it
    // Ink Maple wrote: optional, so notes saved before ink answers still load.
    var turn: CGFloat? = nil  // the reading frame it was written in: page points turned by this angle
    var rect: CGRect? = nil  // the written block or the drawing's box, in that frame
    var inked: Date? = nil  // the creation date all its strokes share
    var source: Drawing? = nil  // what a drawing was made from
}
