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

    /// The agent's blue for dots, bubbles and their text: the ink's blue, and in dark mode the colour PencilKit draws it in.
    static let ink = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x69 / 255, green: 0x8F / 255, blue: 0xE0 / 255, alpha: 1)
        : AgentPen.blue }

    let canvas: PKCanvasView
    let page: Page
    let agent = Muse.bundled.map { Agent(muse: $0) }
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

    /// One step of Maple's own changes, made by stroke and note id, so undoing it never reverts anything else on the page.
    struct Change {
        var add: [PKStroke] = []
        var remove: Set<String> = []
        var notes: [Note] = []
        var dropping: Set<String> = []
        var undoable = true  // false for fading, which isn't the person's to undo
        var landed: () -> Void = {}  // runs once it's on the page
    }

    init(canvas: PKCanvasView, page: Page, notes: [Note]) {
        self.canvas = canvas
        self.page = page
        self.notes = notes
        notes.filter { $0.mark != "frame" && $0.inked == nil }.forEach { add(Bubble(anchor: $0.anchor, zoom: $0.zoom, turn: $0.turn ?? 0, note: $0)) }
        sync()
        if agent == nil { logger.error("No MODEL_API_KEY in Secrets.xcconfig: marks are off") }
        if jev == nil { logger.error("No TYPESAFE_API_KEY in Secrets.xcconfig: only double dots are read") }
    }

    func penDown() {
        penOn = true
        busy = true
        [waiting, settling, flushing].forEach { $0?.cancel() }
    }

    /// The pen left the page; `writing` when it was inking, so there may be a mark to read.
    func penUp(writing: Bool) {
        penOn = false
        erasing = !writing
        settling = Task {
            try? await Task.sleep(for: Self.landing)
            if !Task.isCancelled { settle() }
        }
        guard writing, !closed else { return }
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
        [waiting, settling, flushing].forEach { $0?.cancel() }
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
        marked.strokes = drawing.strokes.map { stroke in
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

    /// Keeps an answer as a quiet dot: a ?'s waits to be tapped, a double dot's opens at once.
    func show(_ note: Note, bubble: Bubble?) {
        notes.append(note)
        save()
        let shown = bubble ?? add(Bubble(anchor: note.anchor, zoom: note.zoom, turn: note.turn ?? 0))
        shown.note = note
        if note.mark == "double_dot" { shown.toggle(true) }
    }

    /// Writes an answer in ink where Room finds space beside its mark on the screen it was asked from, or keeps it a quiet
    /// dot when there's none. Worked out as the pen rests, against the page as it is then.
    func write(_ text: String, note: Note, view: (screen: [CGPoint], avoid: [[CGPoint]]), bubble: Bubble?) -> Change? {
        guard present(note.trigger) else {
            remove(bubble)
            return nil
        }
        let pen = Handwriting.answers, zoom = note.zoom, turn = note.turn ?? 0
        let dots = bubbles.filter { $0 !== bubble && $0.note != nil }.map { dot in
            [CGPoint(x: dot.frame.minX, y: dot.frame.minY), CGPoint(x: dot.frame.maxX, y: dot.frame.minY),
             CGPoint(x: dot.frame.maxX, y: dot.frame.maxY), CGPoint(x: dot.frame.minX, y: dot.frame.maxY)].map { CGPoint(x: $0.x / canvas.zoomScale, y: $0.y / canvas.zoomScale) }
        }
        let request = Room.Request(strokes: ink(around: view.screen, marking: Set(note.trigger), zoom: zoom), doubleDot: note.mark == "double_dot",
                                   screen: view.screen, avoid: view.avoid + dots, screenAngle: turn, zoom: zoom, nib: nib(after: note.trigger))
        let start = ContinuousClock.now
        guard let place = Room.place(request, layout: { cap, width in
            let lines = pen.wrap(text, cap: cap, width: width)
            return (pen.extent(lines, cap: cap), lines.count)
        }) else {
            logger.notice("no room: a quiet dot")
            show(note, bubble: bubble)
            return nil
        }
        let lines = pen.wrap(text, cap: place.cap, width: place.width)
        let glyphs = pen.pen(lines, at: place.origin, cap: place.cap)  // reading frame
        let reading = CGAffineTransform(rotationAngle: place.angle), page = reading.inverted(), date = Date()
        let strokes = (place.leader + glyphs.map { $0.map { $0.applying(page) } }).map {
            AgentPen.stroke($0, width: AgentPen.width(at: zoom), step: 2 / zoom, date: date)
        }
        logger.notice("wrote kind=\(place.kind.rawValue, privacy: .public) lines=\(lines.count) ms=\(Int(start.duration(to: .now) / .milliseconds(1)))")
        var note = note
        note.anchor = place.rect.origin.applying(page)
        note.turn = place.angle
        note.rect = place.rect
        note.inked = date
        remove(bubble)
        return Change(add: strokes, notes: [note]) { [weak self] in
            self?.written.first { $0.note.id == note.id }?.reveal(place.leader.map { $0.map { $0.applying(reading) } } + glyphs, letters: text.count)
            UIAccessibility.post(notification: .announcement, argument: note.reply)
        }
    }

    /// The ink on and around the screen as Room reads it: what the eraser left of each stroke, the person's and Maple's.
    func ink(around screen: [CGPoint], marking trigger: Set<String>, zoom: CGFloat) -> [Room.Stroke] {
        let area = screen.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -40 / zoom, dy: -40 / zoom)
        return canvas.drawing.strokes.filter { $0.renderBounds.intersects(area) }.flatMap { stroke in
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

    /// Takes away an answer or drawing the person scratched out, and the scratching, as one step of undo.
    func scratch(_ note: Note, _ trigger: [String]) {
        enqueue { [weak self] in
            guard let self else { return nil }
            return Change(remove: Set(strokes(of: note).map(Self.id) + trigger), dropping: [note.id])
        }
    }

    /// Keeps a view over each answer written in ink, for VoiceOver and its reveal, as notes come and go with undo.
    func sync() {
        let alive = Set(canvas.drawing.strokes.lazy.filter(AgentPen.wrote).map(\.path.creationDate))
        let inked = notes.filter { $0.mark != "frame" && $0.inked.map(alive.contains) == true }
        written.removeAll { view in
            guard !inked.contains(where: { $0.id == view.note.id }) else { return false }
            view.removeFromSuperview()
            return true
        }
        for note in inked where !written.contains(where: { $0.note.id == note.id }) {
            let view = Written(note: note)
            canvas.addSubview(view)
            view.place(zoom: canvas.zoomScale)
            written.append(view)
        }
    }

    /// Fills an empty box, drawn level in the page turned by `turn`, with the agent's ink: a drawing, or a graph the app
    /// computes. A pixel grid shimmers in the box until the ink is written; if drawing fails, an orange dot at its corner
    /// tries again.
    func draw(_ agent: Agent, _ near: Data, _ around: Data, threads: [Agent.Thread], trigger: [String], box: CGRect, turn: CGFloat, zoom: CGFloat) async {
        guard present(trigger) else { return }
        let grid = Thinking(style: .pixels)
        canvas.addSubview(grid)
        grids.append((grid, box, turn))
        grid.place(over: box, turn: turn, zoom: canvas.zoomScale)
        let done = { [weak self, weak grid] in
            grid?.removeFromSuperview()
            self?.grids.removeAll { $0.view === grid }
        }
        asking += 1
        defer { asking -= 1 }
        let start = ContinuousClock.now
        do {
            let drawing = try await agent.draw(near: near, around: around, size: box.size, threads: threads)
            guard !closed else { return }
            guard present(trigger) else { return done() }
            let lines = try drawing.lines(in: box.size)
            // Bound the filled-in points too: a few huge strokes must not become millions of PencilKit samples.
            let step = 2 / zoom
            let length = lines.reduce(CGFloat(0)) { sum, line in sum + zip(line, line.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } }
            guard length / step < 100_000 else { throw Plot.Failure("The drawing is too complex") }
            let page = CGAffineTransform(rotationAngle: -turn), date = Date()
            let strokes = lines.map { line in
                AgentPen.stroke(line.map { CGPoint(x: box.minX + $0.x, y: box.minY + $0.y).applying(page) }, width: AgentPen.width(at: zoom), step: step, date: date)
            }
            logger.notice("drew kind=\(drawing.kind, privacy: .public) strokes=\(strokes.count) ms=\(Int(start.duration(to: .now) / .milliseconds(1)))")
            let note = Note(mark: "frame", trigger: trigger, anchor: Self.anchor(box, zoom).applying(page), zoom: zoom, reading: drawing.reading,
                            reply: drawing.say, turn: turn, rect: box, inked: date, source: drawing)
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

    /// The close-up and the working area as Muse sees them: dark ink on white, the mark in red, at most 1568 px a side.
    @concurrent nonisolated static func crops(_ drawing: PKDrawing, _ near: CGRect, _ around: CGRect) async -> (Data, Data) {
        func png(_ rect: CGRect) -> Data {
            let scale = min(2, 1568 / max(rect.width, rect.height))
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
