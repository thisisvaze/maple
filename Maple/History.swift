import PencilKit

/// Serializable changes, shared by the Pencil and Maple. PencilKit's private undo callbacks cannot survive a reload.
final class History: UndoManager {
    static let limit = 100
    var past: [Step] = [], future: [Step] = []
    var restore: ((Step, Bool) -> Void)?
    var prepare: (() -> Bool)?

    override init() {
        super.init()
        disableUndoRegistration()  // tool gestures are recorded once, after their final drawing arrives
    }

    override var canUndo: Bool { !past.isEmpty }
    override var canRedo: Bool { !future.isEmpty }
    override var undoCount: Int { past.count }
    override var redoCount: Int { future.count }

    override func undo() {
        guard prepare?() != false, let step = past.popLast() else { return }
        future.append(step)
        restore?(step, true)
    }

    override func redo() {
        guard prepare?() != false, let step = future.popLast() else { return }
        past.append(step)
        restore?(step, false)
    }

    override func removeAllActions() {
        super.removeAllActions()
        if isUndoRegistrationEnabled { disableUndoRegistration() }
        past.removeAll()
        future.removeAll()
    }

    func record(from before: State, to after: State) {
        let step = Step(before, after)
        guard !step.before.empty || !step.after.empty else { return }
        past.append(step)
        if past.count > Self.limit { past.removeFirst(past.count - Self.limit) }
        future.removeAll()
    }

    nonisolated struct State: Codable, Sendable {
        var drawing: PKDrawing
        var notes: [Note]

        private enum CodingKeys: String, CodingKey { case drawing, notes }
        init(drawing: PKDrawing, notes: [Note]) { self.drawing = drawing; self.notes = notes }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            drawing = try PKDrawing(data: c.decode(Data.self, forKey: .drawing))
            notes = try c.decode([Note].self, forKey: .notes)
        }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(drawing.dataRepresentation(), forKey: .drawing)
            try c.encode(notes, forKey: .notes)
        }
    }

    /// Only the changed strokes and notes, with their original positions so erased ink returns to its own layer.
    nonisolated struct Patch: Codable, Sendable {
        var state: State
        var positions: [Int], notePositions: [Int], filePositions: [Int]
        var empty: Bool { positions.isEmpty && notePositions.isEmpty }

        init(_ state: State, comparedTo other: State) {
            let byID = Dictionary(grouping: other.drawing.strokes, by: Marks.id)
            let notes = Dictionary(uniqueKeysWithValues: other.notes.map { ($0.id, $0) })
            // Pixel erasure splits one logical stroke into pieces with the same ID; undo replaces the whole group.
            let changed = Set(Dictionary(grouping: state.drawing.strokes, by: Marks.id).compactMap { id, pieces -> String? in
                guard let old = byID[id], old.count == pieces.count else { return id }
                let different = zip(pieces, old).contains { s, old in
                    // PencilKit copies stroke wrappers but shares unchanged paths.
                    if #available(iOS 27, *), s.renderGroupID != old.renderGroupID || s.renderState != old.renderState { return true }
                    return (s.path as PKStrokePathReference) !== (old.path as PKStrokePathReference)
                        || s.ink.inkType != old.ink.inkType || !s.ink.color.isEqual(old.ink.color)
                        || s.transform != old.transform || s.mask?.cgPath != old.mask?.cgPath
                }
                return different ? id : nil
            })
            positions = state.drawing.strokes.indices.filter { changed.contains(Marks.id(state.drawing.strokes[$0])) }
            notePositions = state.notes.indices.filter { notes[state.notes[$0].id] != state.notes[$0] }
            var kept = 0
            let offsets = state.drawing.strokes.map { stroke in
                defer { if !AgentPen.edit(stroke) { kept += 1 } }
                return kept
            }
            filePositions = positions.map { offsets[$0] }
            self.state = State(drawing: PKDrawing(strokes: positions.map { state.drawing.strokes[$0] }), notes: notePositions.map { state.notes[$0] })
        }

        var forSaving: Self {
            var patch = self
            let kept = state.drawing.strokes.indices.filter { !AgentPen.edit(state.drawing.strokes[$0]) }
            patch.state.drawing = PKDrawing(strokes: kept.map { state.drawing.strokes[$0] })
            patch.positions = kept.map { filePositions[$0] }
            patch.filePositions = patch.positions
            return patch
        }
    }

    nonisolated struct Step: Codable, Sendable {
        var before: Patch, after: Patch
        init(_ before: State, _ after: State) {
            self.before = Patch(before, comparedTo: after)
            self.after = Patch(after, comparedTo: before)
        }

        func applying(to state: State, backwards: Bool) -> State {
            let target = backwards ? before : after
            let ids = Set((before.state.drawing.strokes + after.state.drawing.strokes).map(Marks.id))
            let noteIDs = Set((before.state.notes + after.state.notes).map(\.id))
            var strokes = state.drawing.strokes.filter { !ids.contains(Marks.id($0)) }
            var notes = state.notes.filter { !noteIDs.contains($0.id) }
            for (i, stroke) in zip(target.positions, target.state.drawing.strokes) { strokes.insert(stroke, at: min(i, strokes.count)) }
            for (i, note) in zip(target.notePositions, target.state.notes) { notes.insert(note, at: min(i, notes.count)) }
            return State(drawing: PKDrawing(strokes: strokes), notes: notes)
        }
    }

    /// One atomic file holds the page and both stacks; unchanged ink appears only in the current page.
    nonisolated struct Archive: Codable, Sendable {
        var version = 1
        var current: State
        var past: [Step], future: [Step]

        var forSaving: Self {
            var archive = self
            archive.current.drawing.strokes.removeAll(where: AgentPen.edit)
            func clean(_ steps: [Step]) -> [Step] {
                steps.compactMap { step in
                    var saved = step
                    saved.before = step.before.forSaving
                    saved.after = step.after.forSaving
                    return saved.before.empty && saved.after.empty ? nil : saved
                }
            }
            archive.past = clean(past)
            archive.future = clean(future)
            return archive
        }

        func validated() throws -> Self {
            guard version == 1, past.count + future.count <= 100 else { throw CocoaError(.fileReadCorruptFile) }
            for state in [current] + (past + future).flatMap({ [$0.before.state, $0.after.state] }) {
                guard Set(state.notes.map(\.id)).count == state.notes.count else { throw CocoaError(.fileReadCorruptFile) }
            }
            for patch in (past + future).flatMap({ [$0.before, $0.after] }) {
                guard patch.positions.count == patch.state.drawing.strokes.count,
                      patch.notePositions.count == patch.state.notes.count,
                      patch.filePositions == patch.positions,
                      patch.positions.allSatisfy({ $0 >= 0 }), patch.notePositions.allSatisfy({ $0 >= 0 }),
                      patch.positions == patch.positions.sorted(), Set(patch.positions).count == patch.positions.count,
                      patch.notePositions == patch.notePositions.sorted(), Set(patch.notePositions).count == patch.notePositions.count else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            return self
        }
    }
}
