import PencilKit
import os

nonisolated let logger = Logger(subsystem: "dev.maple", category: "marks")

/// After each pen pause, finds the mark just made, asks the agent about it, and keeps its answers on the page. Marks are
/// measured in the reading frame, the page turned the way it lies on screen, so writing that runs level on screen is level
/// there at any page angle.
final class Marks {
    // Calibration knobs: tune with a real Pencil.
    static let pause: Duration = .milliseconds(600)  // how long the pen rests before a mark is read
    static let doubleDotReach: CGFloat = 4  // screen points two nib taps may land apart and still be one double dot
    static let nearPad: CGFloat = 90  // page points of context around the mark in the close-up
    static let maxAsking = 3  // questions in flight at once; more pauses wait for the next one
    static let rest: Duration = .milliseconds(800)  // how long the pen rests before Maple writes on the page
    static let restCap: Duration = .seconds(6)  // past this, Maple writes in the next gap between strokes
    static let landing: Duration = .milliseconds(300)  // the longest a finished stroke takes to reach the drawing
    static let pagesButton: CGFloat = 92  // screen points kept clear at the top-left for the Pages button
    static let editPause: Duration = .milliseconds(1500)  // how long the pen rests after the edit brush before Maple edits
    static let editReach: CGFloat = 24  // screen points from an edit mark to the ink it points at
    static let maxTargets = 4  // drawings and answers one edit changes at most, nearest the marks first
    static let fading: TimeInterval = 0.5  // seconds edit marks take to fade once read

    /// The agent's blue for dots, bubbles and their text: the ink's blue, and in dark mode the colour PencilKit draws it in.
    static let ink = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x69 / 255, green: 0x8F / 255, blue: 0xE0 / 255, alpha: 1)
        : AgentPen.blue }

    let canvas: PKCanvasView
    let page: Page
    var agent = Muse.bundled.map { Agent(muse: $0) }  // a var so canvas-check can give it an offline Muse
    let jev = Jev.bundled
    var notes: [Note]
    var bubbles: [Bubble] = []
    var written: [Written] = []  // over answers written in ink
    var grids: [(view: Thinking, box: CGRect, turn: CGFloat)] = []  // over boxes being drawn in
    var waiting: Task<Void, Never>?
    var lastTrigger: [String] = []
    var asking = 0
    weak var lastTag: UILabel?
    var work: [UUID: Task<Void, Never>] = [:]  // reading and answering in flight, cancelled when the page closes
    var closed = false

    // Maple writes on the page only while the pen rests: a finished stroke can take a moment to reach the drawing, and
    // setting the drawing under a live stroke can cut it short.
    var penOn = false
    var busy = false  // the pen is on the page, or its last stroke hasn't landed yet
    var lastInk = ContinuousClock.now
    var settling: Task<Void, Never>?
    var pending: [(since: ContinuousClock.Instant, change: () -> Change?)] = []
    var flushing: Task<Void, Never>?
    var erasing = false
    var fadedBy: [String: Set<String>] = [:]  // answers faded under the person's writing, and the strokes that faded them
    var editWait: Task<Void, Never>?  // the pen resting after the edit brush
    var editing: Set<String> = []  // the marks, and the notes they change, of edits in flight
    var retrying: [(dot: Bubble, marks: Set<String>)] = []  // failed edits' orange dots, and the marks each tries again

    /// One step of Maple's own changes, made by stroke and note id, so undoing it never reverts anything else on the page.
    struct Change {
        var add: [PKStroke] = []
        var remove: Set<String> = []
        var notes: [Note] = []
        var dropping: Set<String> = []
        var undoable = true  // false for fading, which isn't the person's to undo
        var landed: () -> Void = {}  // runs once it's on the page
    }

    /// One edit: the edit brush's marks, the drawings and answers they point at (Muse knows them as "1", "2", ...,
    /// nearest first), and the screen they were made on.
    struct Batch {
        var marks: [PKStroke]
        var targets: [Note]
        var screen: [CGPoint], avoid: [[CGPoint]]
        var turn, zoom: CGFloat
        var ids: Set<String> { Set(marks.map(Marks.id) + targets.map(\.id)) }
    }

    init(canvas: PKCanvasView, page: Page, notes: [Note]) {
        self.canvas = canvas
        self.page = page
        self.notes = notes
        sync()
        if agent == nil { logger.error("No MODEL_API_KEY in Secrets.xcconfig: marks are off") }
        if jev == nil { logger.error("No TYPESAFE_API_KEY in Secrets.xcconfig: only double dots are read") }
    }

    /// The pen touched the page; `editing` with the edit brush, which keeps Maple from editing yet.
    func penDown(editing: Bool = false) {
        penOn = true
        busy = true
        [waiting, settling, flushing].forEach { $0?.cancel() }
        if editing { editWait?.cancel() }
    }

    /// The pen left the page; `writing` when it was inking, so there may be a mark to read, or with `editing`, the edit
    /// brush's marks, which Maple reads once the pen has rested a little longer.
    func penUp(writing: Bool, editing: Bool = false) {
        penOn = false
        erasing = !writing
        settling = Task {
            try? await Task.sleep(for: Self.landing)
            if !Task.isCancelled { settle() }
        }
        guard writing, !closed else { return }
        if editing {
            editWait = Task {
                try? await Task.sleep(for: Self.editPause)
                if !Task.isCancelled { edit() }
            }
            return
        }
        waiting = Task {
            try? await Task.sleep(for: Self.pause)
            if !Task.isCancelled { look() }
        }
    }

    /// The drawing changed; after the pen lifts, that's its stroke landing. A faded answer comes back once the writing
    /// over it is gone.
    func drawingChanged() {
        if busy, !penOn { settle() }
        guard !fadedBy.isEmpty else { return }
        let present = Set(canvas.drawing.strokes.map(Self.id))
        for (id, strokes) in fadedBy where present.isDisjoint(with: strokes) {
            fadedBy[id] = nil
            if let note = notes.first(where: { $0.id == id }) { fade(note, true) }
        }
    }

    func settle() {
        settling?.cancel()
        busy = false
        lastInk = .now
        if erasing { sync() }  // an answer erased away leaves VoiceOver too
        schedule()
    }

    /// Writes everything queued, cancels what's in flight, and stops writing to the page, which is closing.
    func stop() {
        flush()
        closed = true
        [waiting, settling, flushing, editWait].forEach { $0?.cancel() }
        work.values.forEach { $0.cancel() }
    }

    /// Starts reading or answering, cancelled if the page closes first.
    func run(_ body: @escaping () async -> Void) {
        let key = UUID()
        work[key] = Task {
            await body()
            work[key] = nil
        }
    }

    /// Queues a change for when the pen rests. It's worked out then, against the page as it is, and dropped if it returns nil.
    func enqueue(_ change: @escaping () -> Change?) {
        pending.append((.now, change))
        schedule()
    }

    func schedule() {
        flushing?.cancel()
        guard let first = pending.first, !busy, !closed else { return }
        let due = min(lastInk + Self.rest, first.since + Self.restCap)
        flushing = Task {
            try? await Task.sleep(until: due)
            if !Task.isCancelled { flush() }
        }
    }

    /// Writes the queued changes now.
    func flush() {
        flushing?.cancel()
        let queued = pending
        pending = []
        for item in queued {
            guard let change = item.change() else { continue }
            apply(change)
            change.landed()
        }
    }

    /// Makes one step of Maple's changes to the page, undone and redone on its own. A stroke both removed and added is
    /// changed in place, so it keeps its depth among the person's strokes.
    func apply(_ change: Change) {
        var drawing = canvas.drawing, removed: [PKStroke] = []
        var adding = Dictionary(change.add.map { (Self.id($0), $0) }) { first, _ in first }
        drawing.strokes = drawing.strokes.compactMap { stroke in
            let id = Self.id(stroke)
            guard change.remove.contains(id) else { return stroke }
            removed.append(stroke)
            return adding.removeValue(forKey: id)
        }
        drawing.strokes += change.add.filter { adding[Self.id($0)] != nil }
        let dropped = notes.filter { change.dropping.contains($0.id) }
        notes.removeAll { change.dropping.contains($0.id) }
        notes += change.notes
        canvas.drawing = drawing
        save()
        sync()
        guard change.undoable else { return }
        canvas.undoManager?.registerUndo(withTarget: self) {
            $0.apply(Change(add: removed, remove: Set(change.add.map(Self.id)), notes: dropped, dropping: Set(change.notes.map(\.id))))
        }
    }

    static func id(_ stroke: PKStroke) -> String { "\(stroke.path.creationDate.timeIntervalSince1970)-\(stroke.randomSeed)" }

    /// A stroke's visible ink, a point every `step` page points along each part the eraser left, transform applied.
    static func points(_ stroke: PKStroke, every step: CGFloat) -> [[CGPoint]] {
        stroke.maskedPathRanges.map { range in
            stroke.path.interpolatedPoints(in: range, by: .distance(step)).map { $0.location.applying(stroke.transform) }
        }
    }

    /// A stroke's box in the page turned by `turn`, as wide as its ink; null if it was erased.
    static func bounds(_ stroke: PKStroke, turn: CGFloat, zoom: CGFloat) -> CGRect {
        let frame = CGAffineTransform(rotationAngle: turn), half = (stroke.path.first?.size.width ?? 0) / 2
        let box = points(stroke, every: 1 / zoom).joined().reduce(CGRect.null) { $0.union(CGRect(origin: $1.applying(frame), size: .zero)) }
        return box.isNull ? box : box.insetBy(dx: -half, dy: -half)
    }

    /// The screen's corners in page points, clockwise from the top-left.
    var screen: [CGPoint] { onPage(canvas.superview?.bounds ?? .zero) }

    /// The Pages button's corner of the screen, which answers keep clear of, in page points.
    var pagesCorner: [CGPoint] {
        let safe = canvas.superview?.safeAreaInsets ?? .zero
        return onPage(CGRect(x: 0, y: 0, width: safe.left + Self.pagesButton, height: safe.top + Self.pagesButton))
    }

    /// A rect on screen as the page points under its corners, clockwise from the top-left.
    func onPage(_ rect: CGRect) -> [CGPoint] {
        guard let view = canvas.superview else { return [] }
        let zoom = canvas.zoomScale
        return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY)].map {
            let p = canvas.convert($0, from: view)
            return CGPoint(x: p.x / zoom, y: p.y / zoom)
        }
    }

    /// How far a page point is from an answer: from its written block or box, or from its dot.
    static func distance(_ point: CGPoint, _ note: Note) -> CGFloat {
        guard let rect = note.rect, let turn = note.turn else { return hypot(point.x - note.anchor.x, point.y - note.anchor.y) }
        let q = point.applying(CGAffineTransform(rotationAngle: turn))
        return hypot(max(rect.minX - q.x, 0, q.x - rect.maxX), max(rect.minY - q.y, 0, q.y - rect.maxY))
    }

    /// Reads the latest strokes for a mark and, if they're new, asks about them.
    func look() {
        guard let agent, asking < Self.maxAsking, !closed else { return }
        let drawing = canvas.drawing, zoom = canvas.zoomScale
        let turn = atan2(canvas.transform.b, canvas.transform.a), reading = CGAffineTransform(rotationAngle: turn)
        let recent = drawing.strokes.filter(AgentPen.person).suffix(12).compactMap { stroke -> Grouping.Stroke? in
            let bounds = Self.bounds(stroke, turn: turn, zoom: zoom)
            let started = stroke.path.creationDate.timeIntervalSince1970
            return bounds.isNull ? nil : Grouping.Stroke(id: Self.id(stroke), bounds: bounds, started: started,
                                                         ended: started + (stroke.path.last?.timeOffset ?? 0))
        }
        let dots = Grouping.doubleDot(recent, reach: Self.doubleDotReach / zoom)
        let trigger = dots ?? Grouping.candidate(recent)
        guard !trigger.isEmpty, trigger != lastTrigger, !notes.contains(where: { !Set($0.trigger).isDisjoint(with: trigger) }) else { return }
        lastTrigger = trigger

        let selected = Set(trigger)
        var marked = drawing
        marked.strokes = drawing.strokes.filter { !AgentPen.edit($0) }.map { stroke in  // edit marks are for edits, never a mark's context
            var stroke = stroke
            if selected.contains(Self.id(stroke)) { stroke.ink = PKInk(stroke.ink.inkType, color: .systemRed) }
            return stroke
        }
        // In the reading frame: the mark, a close-up around it, and the screen with the close-up.
        let mark = recent.filter { selected.contains($0.id) }.reduce(CGRect.null) { $0.union($1.bounds) }
        let side = max(mark.width, mark.height) + 2 * Self.nearPad
        let near = CGRect(x: mark.midX - side / 2, y: mark.midY - side / 2, width: side, height: side)
        let around = screen.reduce(near) { $0.union(CGRect(origin: $1.applying(reading), size: .zero)) }
        let threads = notes.filter { around.contains($0.anchor.applying(reading)) }.map { Agent.Thread(id: $0.id, reading: $0.reading, answer: $0.reply) }
        let middle = CGPoint(x: mark.midX, y: mark.midY).applying(reading.inverted()), reach = max(mark.width, mark.height) / 2 + 60 / zoom
        let target = notes.filter { Self.distance(middle, $0) <= reach }.min { Self.distance(middle, $0) < Self.distance(middle, $1) }?.id
        let anchor = Self.anchor(mark, zoom).applying(reading.inverted()), view = (screen: screen, avoid: [pagesCorner])
        // A double dot is known on the device, so its orb shows at once. Anything else, Jev looks at first, and only a ? or
        // an empty box goes on to Muse.
        let thinking = dots == nil ? nil : add(Bubble(anchor: anchor, zoom: zoom, turn: turn))
        run { [self] in
            let (nearPNG, aroundPNG) = await Self.crops(marked.transformed(using: reading), near, around)
            guard !Task.isCancelled else { return }
            var gesture = "double_dot", sure = true
            if dots == nil {
                guard let jev else { return }
                let start = ContinuousClock.now
                do {
                    let verdict = try await jev.mark(nearPNG)
                    gesture = verdict.mark
                    sure = verdict.top == verdict.mark
                    tag(verdict)
                } catch {
                    return logger.error("jev failed: \(error.localizedDescription, privacy: .public)")
                }
                logger.notice("jev mark=\(gesture, privacy: .public) ms=\(Int(start.duration(to: .now) / .milliseconds(1)))")
            }
            switch gesture {
            case "question":  // the orb shows from the moment Jev sees the ?
                await ask(agent, nearPNG, aroundPNG, gesture: gesture, threads: threads, target: target, trigger: trigger, anchor: anchor,
                          turn: turn, zoom: zoom, view: view, bubble: add(Bubble(anchor: anchor, zoom: zoom, turn: turn)))
            case "double_dot":
                await ask(agent, nearPNG, aroundPNG, gesture: gesture, threads: threads, target: target, trigger: trigger, anchor: anchor,
                          turn: turn, zoom: zoom, view: view, bubble: thinking)
            case "frame":
                await draw(agent, nearPNG, aroundPNG, threads: threads, trigger: trigger, box: mark, turn: turn, zoom: zoom)
            case "scribble", "strike":  // scratching out an answer or a drawing removes it
                if let note = answer(touching: trigger) { scratch(note, trigger) }
            case "writing" where sure, "other" where sure:  // writing over an answer fades it under the writing
                if let note = answer(touching: trigger), note.mark != "frame" {
                    fadedBy[note.id, default: []].formUnion(trigger)
                    fade(note, false)
                }
            default: break  // circles, underlines and the rest are the person's own; nothing wakes
            }
        }
    }

    /// Jev's verdict in the top-right corner for 3 s, for tuning: what it saw and how sure, "maybe" when that fell short.
    func tag(_ verdict: Jev.Verdict) {
        guard let screen = canvas.superview else { return }
        lastTag?.removeFromSuperview()
        let label = UILabel()
        label.text = (verdict.mark == verdict.top ? "" : "maybe ") + verdict.top.replacingOccurrences(of: "_", with: " ") + " \(Int((verdict.probability * 100).rounded()))%"
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.sizeToFit()
        let safe = screen.safeAreaLayoutGuide.layoutFrame
        label.frame.origin = CGPoint(x: safe.maxX - label.bounds.width - 16, y: safe.minY + 12)
        label.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
        screen.addSubview(label)
        lastTag = label
        UIView.animate(withDuration: 0.6, delay: 3) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }

    /// Where a mark's dot sits, in the mark's frame: just right of its top-right corner.
    static func anchor(_ mark: CGRect, _ zoom: CGFloat) -> CGPoint { CGPoint(x: mark.maxX + 6 / zoom, y: mark.minY) }

    /// Whether the mark's strokes are all still on the page; the person may erase them while Muse reads or draws.
    func present(_ trigger: [String]) -> Bool { Set(canvas.drawing.strokes.map(Self.id)).isSuperset(of: trigger) }

    func remove(_ bubble: Bubble?) {
        bubble?.removeFromSuperview()
        bubbles.removeAll { $0 === bubble }
    }

    /// Answers a ? or a double dot in ink beside it, once the pen rests. Exact texts, and answers the pen can't write or
    /// that find no room, stay a quiet dot to tap open, or for a double dot, opened at once. The dot is the thinking orb
    /// meanwhile.
    func ask(_ agent: Agent, _ near: Data, _ around: Data, gesture: String, threads: [Agent.Thread], target: String?, trigger: [String],
             anchor: CGPoint, turn: CGFloat, zoom: CGFloat, view: (screen: [CGPoint], avoid: [[CGPoint]]), bubble: Bubble?) async {
        guard present(trigger) else { return remove(bubble) }
        asking += 1
        defer { asking -= 1 }
        let start = ContinuousClock.now
        do {
            let answer = try await agent.ask(near: near, around: around, gesture: gesture, threads: threads, target: target)
            logger.notice("answered gesture=\(gesture, privacy: .public) passage=\(answer.passage) ms=\(Int(start.duration(to: .now) / .milliseconds(1)))")
            guard !closed else { return }
            guard present(trigger), !answer.reply.isEmpty else { return remove(bubble) }
            let note = Note(mark: gesture, trigger: trigger, anchor: anchor, zoom: zoom, reading: answer.reading, reply: answer.reply, turn: turn)
            guard !answer.passage, let text = Handwriting.answers.writable(answer.reply) else { return show(note, bubble: bubble) }
            enqueue { [weak self] in self?.write(text, note: note, view: view, bubble: bubble) }
        } catch {
            logger.error("ask failed: \(error.localizedDescription, privacy: .public)")
            guard !closed else { return }
            bubble?.retry = { [weak self, weak bubble] in
                bubble?.retry = nil
                self?.run { await self?.ask(agent, near, around, gesture: gesture, threads: threads, target: target, trigger: trigger,
                                            anchor: anchor, turn: turn, zoom: zoom, view: view, bubble: bubble) }
            }
        }
    }

    /// Answers a spoken question about the visible page, using the same crops and saved threads as pen questions.
    func askVoice(_ transcript: String) async throws {
        guard !closed, let agent, let view = canvas.superview else { throw CancellationError() }
        try Task.checkCancellation()
        let turn = atan2(canvas.transform.b, canvas.transform.a), reading = CGAffineTransform(rotationAngle: turn)
        let area = screen.reduce(CGRect.null) { $0.union(CGRect(origin: $1.applying(reading), size: .zero)) }
        guard !area.isEmpty else { throw Muse.Failure("Open a page before asking a question.") }
        let zoom = canvas.zoomScale, safe = view.safeAreaLayoutGuide.layoutFrame
        let near = CGRect(x: area.midX - area.width / 4, y: area.midY - area.height / 4, width: area.width / 2, height: area.height / 2)
        let threads = notes.filter { area.contains($0.anchor.applying(reading)) }.map { Agent.Thread(id: $0.id, reading: $0.reading, answer: $0.reply) }
        let anchor = onPage(CGRect(x: safe.minX + 24, y: safe.minY + 96, width: 0, height: 0))[0]
        let (closeUp, around) = await Self.crops(canvas.drawing.transformed(using: reading), near, area)
        try Task.checkCancellation()
        let answer = try await agent.ask(near: closeUp, around: around, gesture: "voice", threads: threads, target: nil, speech: transcript)
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard !answer.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Muse.Failure("The answer was empty. Please try again.") }
        show(Note(mark: "voice", trigger: [], anchor: anchor, zoom: zoom, reading: transcript, reply: answer.reply, turn: turn), bubble: nil)
    }

    /// Keeps an answer as a quiet dot: a ?'s waits to be tapped; double dots and voice answers open at once.
    func show(_ note: Note, bubble: Bubble?) {
        notes.append(note)
        save()
        let shown = bubble ?? add(Bubble(anchor: note.anchor, zoom: note.zoom, turn: note.turn ?? 0))
        shown.note = note
        if note.mark == "double_dot" || note.mark == "voice" { shown.toggle(true) }
    }

    /// Writes an answer in ink where Room finds space beside its mark on the screen it was asked from, or keeps it a quiet
    /// dot when there's none. Worked out as the pen rests, against the page as it is then.
    func write(_ text: String, note: Note, view: (screen: [CGPoint], avoid: [[CGPoint]]), bubble: Bubble?) -> Change? {
        guard present(note.trigger) else {
            remove(bubble)
            return nil
        }
        guard let hand = handwrite(text, for: note, screen: view.screen, avoid: view.avoid, turn: note.turn ?? 0, nib: nib(after: note.trigger),
                                   besides: bubble) else {
            logger.notice("no room: a quiet dot")
            show(note, bubble: bubble)
            return nil
        }
        remove(bubble)
        return Change(add: hand.strokes, notes: [hand.note]) { [weak self] in
            self?.written.first { $0.note.id == note.id }?.reveal(hand.lines, letters: text.count)
            UIAccessibility.post(notification: .announcement, argument: note.reply)
        }
    }

    /// `text` in the answers' pen where Room finds room beside `note`'s mark, on `screen` turned by `turn`: its strokes,
    /// all dated `date`, their lines in the reading frame to reveal, and the note as written there. Nil when there's no
    /// room. Other answers' dots are in the way, but not `bubble`'s, nor the strokes `leaving`, as an answer rewritten.
    func handwrite(_ text: String, for note: Note, screen: [CGPoint], avoid: [[CGPoint]], turn: CGFloat, nib: CGPoint?, besides bubble: Bubble? = nil,
                   leaving: Set<String> = [], date: Date = Date()) -> (strokes: [PKStroke], lines: [[CGPoint]], note: Note)? {
        let pen = Handwriting.answers, zoom = note.zoom
        let dots = bubbles.filter { $0 !== bubble && $0.note != nil }.map { dot in
            [CGPoint(x: dot.frame.minX, y: dot.frame.minY), CGPoint(x: dot.frame.maxX, y: dot.frame.minY),
             CGPoint(x: dot.frame.maxX, y: dot.frame.maxY), CGPoint(x: dot.frame.minX, y: dot.frame.maxY)].map { CGPoint(x: $0.x / canvas.zoomScale, y: $0.y / canvas.zoomScale) }
        }
        let request = Room.Request(strokes: ink(around: screen, marking: Set(note.trigger), leaving: leaving, zoom: zoom), doubleDot: note.mark == "double_dot",
                                   screen: screen, avoid: avoid + dots, screenAngle: turn, zoom: zoom, nib: nib)
        let start = ContinuousClock.now
        guard let place = Room.place(request, layout: { cap, width in
            let lines = pen.wrap(text, cap: cap, width: width)
            return (pen.extent(lines, cap: cap), lines.count)
        }) else { return nil }
        let lines = pen.wrap(text, cap: place.cap, width: place.width)
        let glyphs = pen.pen(lines, at: place.origin, cap: place.cap)  // reading frame
        let reading = CGAffineTransform(rotationAngle: place.angle), page = reading.inverted()
        let strokes = (place.leader + glyphs.map { $0.map { $0.applying(page) } }).map {
            AgentPen.stroke($0, width: AgentPen.width(at: zoom), step: 2 / zoom, date: date)
        }
        logger.notice("wrote kind=\(place.kind.rawValue, privacy: .public) lines=\(lines.count) ms=\(Int(start.duration(to: .now) / .milliseconds(1)))")
        var note = note
        note.anchor = place.rect.origin.applying(page)
        note.turn = place.angle
        note.rect = place.rect
        note.inked = date
        return (strokes, place.leader.map { $0.map { $0.applying(reading) } } + glyphs, note)
    }

    /// The ink on and around the screen as Room reads it: what the eraser left of each stroke, the person's and Maple's,
    /// and the mark wherever it is, but for the strokes `leaving`.
    func ink(around screen: [CGPoint], marking trigger: Set<String>, leaving: Set<String> = [], zoom: CGFloat) -> [Room.Stroke] {
        let area = screen.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -40 / zoom, dy: -40 / zoom)
        return canvas.drawing.strokes.filter { ($0.renderBounds.intersects(area) || trigger.contains(Self.id($0))) && !leaving.contains(Self.id($0)) }.flatMap { stroke in
            let person = AgentPen.person(stroke), mark = trigger.contains(Self.id(stroke))
            return Self.points(stroke, every: 2 / zoom).map { Room.Stroke(points: $0, person: person, mark: mark) }
        }
    }

    /// Where the pen last wrote, if that was after the mark: the person may still be writing there.
    func nib(after trigger: [String]) -> CGPoint? {
        let strokes = canvas.drawing.strokes
        guard let mark = strokes.lastIndex(where: { trigger.contains(Self.id($0)) }),
              let last = strokes[(mark + 1)...].last(where: AgentPen.person), let end = last.path.last else { return nil }
        return end.location.applying(last.transform)
    }

    /// Maple's strokes for an answer or a drawing.
    func strokes(of note: Note) -> [PKStroke] {
        canvas.drawing.strokes.filter { AgentPen.wrote($0) && $0.path.creationDate == note.inked }
    }

    /// The answer or drawing the strokes `ids` come within a few screen points of, by the ink itself, not its box.
    func answer(touching ids: [String]) -> Note? {
        let marked = canvas.drawing.strokes.filter { ids.contains(Self.id($0)) }
        return notes.first { note in
            guard note.inked != nil else { return false }
            let reach = 4 / note.zoom, ink = strokes(of: note).flatMap { Self.points($0, every: reach).joined() }
            return Self.touches(marked.flatMap { Self.points($0, every: reach).joined() }, ink, within: reach)
        }
    }

    /// Whether any of `points` comes within `reach` of `ink`.
    static func touches(_ points: [CGPoint], _ ink: [CGPoint], within reach: CGFloat) -> Bool {
        struct Cell: Hashable { var x, y: Int }
        func cell(_ p: CGPoint) -> Cell { Cell(x: Int((p.x / reach).rounded(.down)), y: Int((p.y / reach).rounded(.down))) }
        var near: [Cell: [CGPoint]] = [:]
        for p in ink { near[cell(p), default: []].append(p) }
        return points.contains { p in
            let c = cell(p)
            return (-1...1).contains { dx in
                (-1...1).contains { dy in near[Cell(x: c.x + dx, y: c.y + dy)]?.contains { hypot($0.x - p.x, $0.y - p.y) <= reach } ?? false }
            }
        }
    }

    /// Fades an answer toward the paper, or brings it back. A partly erased answer is the person's to change, so it stays.
    func fade(_ note: Note, _ back: Bool) {
        enqueue { [weak self] in
            guard let self else { return nil }
            let mine = strokes(of: note)
            guard !mine.isEmpty, !mine.contains(where: { $0.mask != nil }) else { return nil }
            let recoloured = mine.map { stroke in
                var stroke = stroke
                stroke.ink.color = back ? AgentPen.blue : AgentPen.faded
                return stroke
            }
            return Change(add: recoloured, remove: Set(mine.map(Self.id)), undoable: false)
        }
    }

    /// Takes away an answer or drawing the person scratched out, and the scratching, as one step of undo: its ink as it
    /// is then, which an edit may have rewritten meanwhile.
    func scratch(_ note: Note, _ trigger: [String]) {
        enqueue { [weak self] in
            guard let self, let note = notes.first(where: { $0.id == note.id }) else { return nil }
            return Change(remove: Set(strokes(of: note).map(Self.id) + trigger), dropping: [note.id])
        }
    }

    /// Keeps a view over each answer written in ink, for VoiceOver and its reveal, and a dot for each answer kept quiet,
    /// as notes come, go and change with undo and edits. An answer rewritten under the same id gets a new view. A failed
    /// edit's dot goes once its marks are all gone.
    func sync() {
        let marks = Set(canvas.drawing.strokes.lazy.filter(AgentPen.edit).map(Self.id))
        retire { $0.isDisjoint(with: marks) }
        let alive = Set(canvas.drawing.strokes.lazy.filter(AgentPen.wrote).map(\.path.creationDate))
        let inked = notes.filter { $0.mark != "frame" && $0.inked.map(alive.contains) == true }
        written.removeAll { view in
            guard !inked.contains(where: { $0.id == view.note.id && $0.inked == view.note.inked }) else { return false }
            view.removeFromSuperview()
            return true
        }
        for note in inked where !written.contains(where: { $0.note.id == note.id }) {
            let view = Written(note: note)
            canvas.addSubview(view)
            view.place(zoom: canvas.zoomScale)
            written.append(view)
        }
        let quiet = notes.filter { $0.mark != "frame" && $0.inked == nil }
        bubbles.filter { dot in dot.note.map { note in !quiet.contains { $0.id == note.id } } ?? false }.forEach(remove)
        for note in quiet where !bubbles.contains(where: { $0.note?.id == note.id }) {
            add(Bubble(anchor: note.anchor, zoom: note.zoom, turn: note.turn ?? 0, note: note))
        }
    }

    /// Fills an empty box, drawn level in the page turned by `turn`, with the agent's ink: a drawing, or a graph the app
    /// computes. A pixel grid shimmers in the box until the ink is written; if drawing fails, an orange dot at its corner
    /// tries again.
    func draw(_ agent: Agent, _ near: Data, _ around: Data, threads: [Agent.Thread], trigger: [String], box: CGRect, turn: CGFloat, zoom: CGFloat) async {
        guard present(trigger) else { return }
        let done = shimmer(over: box, turn: turn)
        asking += 1
        defer { asking -= 1 }
        let start = ContinuousClock.now
        do {
            let drawing = try await agent.draw(near: near, around: around, size: box.size, threads: threads)
            guard !closed else { return }
            guard present(trigger) else { return done() }
            let date = Date(), strokes = try Self.drawn(drawing, in: box, turn: turn, zoom: zoom, date: date)
            logger.notice("drew kind=\(drawing.kind, privacy: .public) strokes=\(strokes.count) ms=\(Int(start.duration(to: .now) / .milliseconds(1)))")
            let note = Note(mark: "frame", trigger: trigger, anchor: Self.anchor(box, zoom).applying(CGAffineTransform(rotationAngle: -turn)), zoom: zoom,
                            reading: drawing.reading, reply: drawing.say, turn: turn, rect: box, inked: date, source: drawing)
            enqueue { [weak self] in
                done()
                guard let self, present(trigger) else { return nil }
                return Change(add: strokes, notes: [note])
            }
        } catch {
            logger.error("draw failed: \(error.localizedDescription, privacy: .public)")
            done()
            guard !closed else { return }
            let failed = add(Bubble(anchor: Self.anchor(box, zoom).applying(CGAffineTransform(rotationAngle: -turn)), zoom: zoom, turn: turn))
            failed.retry = { [weak self, weak failed] in
                self?.remove(failed)
                self?.run { await self?.draw(agent, near, around, threads: threads, trigger: trigger, box: box, turn: turn, zoom: zoom) }
            }
        }
    }

    /// A drawing's pen strokes in `box`, a rect drawn level in the page turned by `turn`, as ink written at `zoom`, all
    /// dated `date`. Throws when it can't be drawn, or is too complex to.
    static func drawn(_ drawing: Drawing, in box: CGRect, turn: CGFloat, zoom: CGFloat, date: Date) throws -> [PKStroke] {
        let lines = try drawing.lines(in: box.size)
        // Bound the filled-in points too: a few huge strokes must not become millions of PencilKit samples.
        let step = 2 / zoom
        let length = lines.reduce(CGFloat(0)) { sum, line in sum + zip(line, line.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } }
        guard length / step < 100_000 else { throw Plot.Failure("The drawing is too complex") }
        let page = CGAffineTransform(rotationAngle: -turn)
        return lines.map { line in
            AgentPen.stroke(line.map { CGPoint(x: box.minX + $0.x, y: box.minY + $0.y).applying(page) }, width: AgentPen.width(at: zoom), step: step, date: date)
        }
    }

    /// A pixel grid shimmering over `box`, a rect in the page turned by `turn`, placed as the page zooms until the
    /// returned closure takes it away.
    func shimmer(over box: CGRect, turn: CGFloat) -> () -> Void {
        let grid = Thinking(style: .pixels)
        canvas.addSubview(grid)
        grids.append((grid, box, turn))
        grid.place(over: box, turn: turn, zoom: canvas.zoomScale)
        return { [weak self, weak grid] in
            grid?.removeFromSuperview()
            self?.grids.removeAll { $0.view === grid }
        }
    }

    /// Edits with every edit mark on the page that no edit has yet, as one batch.
    func edit() { edit(Set(canvas.drawing.strokes.filter(AgentPen.edit).map(Self.id))) }

    /// Changes Maple's drawings and answers that the edit marks `ids` point at. A pixel grid shimmers over each while
    /// Muse reads the marks, and the changes land at rest as one step of undo. Marks that point at nothing of Maple's
    /// just fade, and marks on what's already being edited wait for the next edit; if Muse fails or changes nothing,
    /// they stay, and an orange dot by them tries again.
    func edit(_ ids: Set<String>) {
        guard !closed, let batch = batch(ids) else { return }
        let marks = Set(batch.marks.map(Self.id))
        retire { !$0.isDisjoint(with: marks) }  // this edit takes their marks
        editing.formUnion(batch.ids)
        guard !batch.targets.isEmpty else {
            return enqueue { [weak self] in
                guard let self else { return nil }
                editing.subtract(marks)
                let left = canvas.drawing.strokes.filter { marks.contains(Self.id($0)) }
                return Change(remove: marks, undoable: false) { [weak self] in self?.fadeOut(left) }
            }
        }
        guard let agent else { return editing.subtract(batch.ids) }
        let grids = batch.targets.map { shimmer(over: $0.rect ?? .zero, turn: $0.turn ?? 0) }
        let done = { grids.forEach { $0() } }
        run { [self] in
            let (near, around, targets) = await request(batch)
            asking += 1
            defer { asking -= 1 }
            let start = ContinuousClock.now
            do {
                let result = try await agent.edit(near: near, around: around, targets: targets)
                logger.notice("edited targets=\(targets.count) edits=\(result.edits.count) ms=\(Int(start.duration(to: .now) / .milliseconds(1)))")
                guard !closed else { return }
                try land(result, batch, done: done)
            } catch {
                logger.error("edit failed: \(error.localizedDescription, privacy: .public)")
                failed(batch, done: done)
            }
        }
    }

    /// An edit Muse couldn't make: the grids go, and the marks stay, free for the next edit, with an orange dot by them
    /// that tries the same batch again, until an edit takes them or they're erased.
    func failed(_ batch: Batch, done: () -> Void) {
        done()
        editing.subtract(batch.ids)
        let marks = Set(batch.marks.map(Self.id))
        guard !closed, canvas.drawing.strokes.contains(where: { marks.contains(Self.id($0)) }) else { return }
        let box = batch.marks.reduce(CGRect.null) { $0.union(Self.bounds($1, turn: batch.turn, zoom: batch.zoom)) }
        let dot = add(Bubble(anchor: Self.anchor(box, batch.zoom).applying(CGAffineTransform(rotationAngle: -batch.turn)), zoom: batch.zoom, turn: batch.turn))
        dot.retry = { [weak self] in self?.edit(marks) }  // which takes the dot away
        retrying.append((dot, marks))
    }

    /// Takes away the failed edits' dots whose marks `gone` says are gone.
    func retire(_ gone: (Set<String>) -> Bool) {
        retrying.removeAll { entry in
            guard gone(entry.marks) else { return false }
            remove(entry.dot)
            return true
        }
    }

    /// The edit marks among `ids` still on the page and in no edit yet, and the drawings and answers of Maple's they
    /// point at: those whose ink a mark comes within editReach of, a drawing whose box a mark lies in, and those inside
    /// a loop drawn round them. At most maxTargets, nearest the marks first. Nil without marks, or when all they point
    /// at is being edited: they wait for the next edit then.
    func batch(_ ids: Set<String>) -> Batch? {
        let zoom = canvas.zoomScale, turn = atan2(canvas.transform.b, canvas.transform.a), reach = Self.editReach / zoom
        let marks = canvas.drawing.strokes.filter { ids.contains(Self.id($0)) && !editing.contains(Self.id($0)) }
        guard !marks.isEmpty else { return nil }
        let points = marks.flatMap { Self.points($0, every: reach / 4).joined() }
        let loops = marks.compactMap { mark -> CGRect? in  // a circle or box drawn round something: its ends meet
            let box = Self.bounds(mark, turn: turn, zoom: zoom)
            guard let a = mark.path.first?.location.applying(mark.transform), let b = mark.path.last?.location.applying(mark.transform),
                  hypot(a.x - b.x, a.y - b.y) <= hypot(box.width, box.height) / 4 else { return nil }
            return box
        }
        let pointed: [(note: Note, gap: CGFloat)] = notes.compactMap { note in
            guard note.inked != nil, note.mark != "frame" || note.source != nil else { return nil }
            let ink = strokes(of: note), box = ink.reduce(CGRect.null) { $0.union(Self.bounds($1, turn: turn, zoom: zoom)) }
            guard !box.isNull, Self.touches(points, ink.flatMap { Self.points($0, every: reach / 4).joined() }, within: reach)
                || note.mark == "frame" && points.contains(where: { Self.distance($0, note) == 0 }) || loops.contains(where: { $0.contains(box) }),
                  note.source.map({ intact($0, ink, in: note.rect) }) ?? true else { return nil }
            return (note, points.map { Self.distance($0, note) }.min() ?? 0)
        }
        let targets = pointed.filter { !editing.contains($0.note.id) }
        guard pointed.isEmpty || !targets.isEmpty else { return nil }
        return Batch(marks: marks, targets: targets.sorted { $0.gap < $1.gap }.prefix(Self.maxTargets).map(\.note), screen: screen,
                     avoid: [pagesCorner], turn: turn, zoom: zoom)
    }

    /// Whether a drawing's `ink` is all still on the page. One the person partly erased is theirs, as fade() treats
    /// answers: redrawing it would bring back what they rubbed out.
    // ponytail: all or nothing; track which parts were erased and drop them in the patch if people erase to edit.
    func intact(_ source: Drawing, _ ink: [PKStroke], in box: CGRect?) -> Bool {
        guard let box, !ink.contains(where: { $0.mask != nil }) else { return false }
        return ink.count == (try? source.lines(in: box.size))?.count
    }

    /// What Muse sees of a batch: a close-up of the marks and their targets, and the screen around it, in the reading
    /// frame, with the marks in even red pen, never lighter than Maple's ink at zoom 1, and other edits' marks left out;
    /// and the targets as Muse knows them, placed in the close-up's pixels.
    func request(_ batch: Batch) async -> (near: Data, around: Data, targets: [Agent.Target]) {
        let reading = CGAffineTransform(rotationAngle: batch.turn), ids = Set(batch.marks.map(Self.id))
        let thin = CGSize(width: AgentPen.width(at: min(batch.zoom, 1)), height: AgentPen.width(at: min(batch.zoom, 1)))  // crops are in page points
        var marked = canvas.drawing
        marked.strokes = canvas.drawing.strokes.compactMap { stroke in
            guard AgentPen.edit(stroke) else { return stroke }
            guard ids.contains(Self.id(stroke)) else { return nil }
            var red = stroke
            red.ink = PKInk(.pen, color: .systemRed)
            red.path = PKStrokePath(controlPoints: stroke.path.map {
                PKStrokePoint(location: $0.location, timeOffset: $0.timeOffset, size: thin, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }, creationDate: stroke.path.creationDate)
            return red
        }
        let boxes = batch.targets.map { Self.box($0, turn: batch.turn) }
        let area = (boxes + batch.marks.map { Self.bounds($0, turn: batch.turn, zoom: batch.zoom) }).reduce(CGRect.null) { $0.union($1) }
        let side = max(area.width, area.height) + 2 * Self.nearPad
        let near = CGRect(x: area.midX - side / 2, y: area.midY - side / 2, width: side, height: side)
        let around = batch.screen.reduce(near) { $0.union(CGRect(origin: $1.applying(reading), size: .zero)) }
        func numbers(_ r: CGRect, _ scale: CGFloat = 1) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double(($0 * scale).rounded()) } }
        let targets = zip(batch.targets, boxes).enumerated().map { i, target in
            let (note, box) = target, at = numbers(box.offsetBy(dx: -near.minX, dy: -near.minY), Self.scale(near))
            guard note.mark == "frame", let source = note.source, let rect = note.rect else {
                return Agent.Target(id: "\(i + 1)", kind: "answer", at: at, question: note.reading, answer: note.reply)
            }
            // The marks in the drawing's own box points, though the page may have been turned otherwise when it was drawn.
            let own = CGAffineTransform(rotationAngle: note.turn ?? 0).concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            let marks = batch.marks.map { Room.box(Self.points($0, every: 2 / batch.zoom).flatMap { $0 }, own) }.filter { !$0.isNull }
            return Agent.Target(id: "\(i + 1)", kind: "drawing", at: at, box: [Double(rect.width.rounded()), Double(rect.height.rounded())],
                                shows: [note.reading, note.reply].filter { !$0.isEmpty }.joined(separator: " — "),
                                drawing: .init(kind: source.kind, parts: source.parts, plot: source.plot), marks: marks.map { numbers($0) })
        }
        let (nearPNG, aroundPNG) = await Self.crops(marked.transformed(using: reading), near, around)
        return (nearPNG, aroundPNG, targets)
    }

    /// A note's written block or box in the page turned by `turn`.
    static func box(_ note: Note, turn: CGFloat) -> CGRect {
        guard let r = note.rect else { return .null }
        return Room.box([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)],
                        CGAffineTransform(rotationAngle: turn - (note.turn ?? 0)))
    }

    /// Lands Muse's edits for a batch as one step of undo, at rest and against the page as it is then: each changed
    /// drawing redrawn in its own box, each changed answer rewritten where Room finds room (or a quiet dot where it was),
    /// and the batch's marks faded off the page. If the marks were erased meanwhile, the person took the instruction
    /// back and nothing changes. Throws, before anything is queued, for a result that can't be used or changes nothing.
    /// `done` runs as it lands.
    func land(_ result: Agent.Edits, _ batch: Batch, done: @escaping () -> Void = {}) throws {
        // Each drawing patched by its edits in turn; each answer's new text. An edit with nothing in it changes nothing.
        var sources: [String: Drawing] = [:], replies: [String: String] = [:]
        for edit in result.edits {
            guard let n = Int(edit.target), batch.targets.indices.contains(n - 1) else { throw Plot.Failure("No target \(edit.target)") }
            let note = batch.targets[n - 1], reply = edit.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if let source = sources[note.id] ?? note.source {
                guard !edit.parts.isEmpty || !edit.plot.expression.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                sources[note.id] = source.patched(parts: edit.parts, plot: edit.plot, say: edit.say)
            } else if !reply.isEmpty {
                replies[note.id] = reply
            }
        }
        guard !sources.isEmpty || !replies.isEmpty else { throw Plot.Failure("No edits: \(result.reading)") }
        // A drawing's new version is known now: its box is its own. nil when nothing's left of it, so it goes.
        var redrawn: [String: (note: Note?, ink: [PKStroke])] = [:]
        for (n, target) in batch.targets.enumerated() {
            guard let drawing = sources[target.id], let box = target.rect else { continue }
            guard !drawing.blank else { redrawn[target.id] = (nil, []); continue }
            var note = target
            let date = Date() + Double(n + 1) / 1000  // its own date
            let ink = try Self.drawn(drawing, in: box, turn: note.turn ?? 0, zoom: note.zoom, date: date)
            (note.source, note.reply, note.inked) = (drawing, drawing.say, date)
            redrawn[target.id] = (note, ink)
        }
        let marks = Set(batch.marks.map(Self.id))
        enqueue { [weak self] in
            done()
            guard let self else { return nil }
            editing.subtract(batch.ids)
            guard present(Array(marks)) else { return nil }
            var change = Change(remove: marks), reveals: [(id: String, lines: [[CGPoint]], letters: Int)] = [], said: [String] = []
            let base = Date()
            for (i, target) in batch.targets.enumerated() where redrawn[target.id] != nil || replies[target.id] != nil {
                let old = strokes(of: target)
                guard !old.isEmpty, notes.contains(where: { $0.id == target.id && $0.inked == target.inked }) else { continue }
                if let redraw = redrawn[target.id] {
                    change.add += redraw.ink
                    if let note = redraw.note { change.notes.append(note) }
                    said.append(redraw.note?.reply ?? "Removed \(target.reading)")
                } else if let reply = replies[target.id] {
                    var note = target
                    note.reply = reply
                    // A faded answer's ink turns blue first, out of undo, so undoing this never leaves it faded with
                    // nothing over it to bring it back.
                    if fadedBy.removeValue(forKey: target.id) != nil {
                        apply(Change(add: old.map { var blue = $0; blue.ink.color = AgentPen.blue; return blue }, remove: Set(old.map(Self.id)), undoable: false))
                    }
                    if present(note.trigger), let text = Handwriting.answers.writable(reply),
                       let hand = handwrite(text, for: note, screen: batch.screen, avoid: batch.avoid, turn: note.turn ?? batch.turn, nib: nil,
                                            leaving: Set(old.map(Self.id)).union(marks), date: base + Double(i) / 1000) {
                        note = hand.note
                        change.add += hand.strokes
                        reveals.append((note.id, hand.lines, text.count))
                    } else {
                        (note.inked, note.rect) = (nil, nil)  // a quiet dot where it was
                    }
                    change.notes.append(note)
                    said.append(reply)
                }
                change.remove.formUnion(old.map(Self.id))
                change.dropping.insert(target.id)
            }
            let left = canvas.drawing.strokes.filter { marks.contains(Self.id($0)) }
            change.landed = { [weak self] in
                guard let self else { return }
                fadeOut(left)
                for reveal in reveals { written.first { $0.note.id == reveal.id }?.reveal(reveal.lines, letters: reveal.letters) }
                UIAccessibility.post(notification: .announcement, argument: said.isEmpty ? result.reading : said.joined(separator: "\n"))
            }
            return change
        }
    }

    /// Fades edit marks just taken off the page out where they lay: a picture of them over the page, which isn't redrawn
    /// under it.
    // ponytail: placed once, so a pinch in its half second leaves it behind; track it in layout() like the grids if that shows.
    func fadeOut(_ marks: [PKStroke]) {
        let rect = marks.reduce(CGRect.null) { $0.union($1.renderBounds) }, zoom = canvas.zoomScale
        guard !rect.isNull else { return }
        let scale = min(canvas.traitCollection.displayScale * zoom, 2048 / max(rect.width, rect.height))  // sharp, at most 2048 px a side
        var picture = UIImage()
        canvas.traitCollection.performAsCurrent {  // in the colours PencilKit draws them in on this paper
            picture = PKDrawing(strokes: marks).image(from: rect, scale: scale)
        }
        let view = UIImageView(image: picture)
        view.frame = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
        canvas.addSubview(view)
        UIView.animate(withDuration: Self.fading) { view.alpha = 0 } completion: { _ in view.removeFromSuperview() }
    }

    /// Pixels per page point in a crop of `rect`: 2, or fewer to keep its sides within 1568 px.
    nonisolated static func scale(_ rect: CGRect) -> CGFloat { min(2, 1568 / max(rect.width, rect.height)) }

    /// The close-up and the working area as Muse sees them: dark ink on white, the mark in red, at most 1568 px a side.
    @concurrent nonisolated static func crops(_ drawing: PKDrawing, _ near: CGRect, _ around: CGRect) async -> (Data, Data) {
        func png(_ rect: CGRect) -> Data {
            let scale = Self.scale(rect)
            let size = CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    drawing.image(from: rect, scale: scale).draw(in: CGRect(origin: .zero, size: size))
                }
            }
        }
        return (png(near), png(around))
    }

    @discardableResult func add(_ bubble: Bubble) -> Bubble {
        bubble.deleted = { [weak self, weak bubble] in
            guard let self, let bubble else { return }
            notes.removeAll { $0.id == bubble.note?.id }
            bubbles.removeAll { $0 === bubble }
            bubble.removeFromSuperview()
            save()
        }
        bubbles.append(bubble)
        canvas.addSubview(bubble)
        bubble.place(zoom: canvas.zoomScale)
        return bubble
    }

    /// Bubbles sit in the canvas's content, so they scroll with the page by themselves; zoom moves and sizes them.
    func layout() {
        bubbles.forEach { $0.place(zoom: canvas.zoomScale) }
        written.forEach { $0.place(zoom: canvas.zoomScale) }
        grids.forEach { $0.view.place(over: $0.box, turn: $0.turn, zoom: canvas.zoomScale) }
    }

    func save() {
        let notes = notes, url = page.notesFile
        Store.queue.async {
            do { try JSONEncoder().encode(notes).write(to: url, options: .atomic) }
            catch { logger.error("notes save failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
