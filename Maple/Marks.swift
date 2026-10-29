import PencilKit
import os

nonisolated let logger = Logger(subsystem: "dev.maple", category: "marks")

/// After each pen pause, finds the mark just made, asks the agent about it, and keeps the answers as bubbles on the page.
final class Marks {
    // Calibration knobs: tune with a real Pencil.
    static let pause: Duration = .milliseconds(600)  // how long the pen rests before a mark is read
    static let doubleDotReach: CGFloat = 4  // screen points two nib taps may land apart and still be one double dot
    static let nearPad: CGFloat = 90  // page points of context around the mark in the close-up
    static let maxAsking = 3  // questions in flight at once; more pauses wait for the next one

    static let ink = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x7F / 255, green: 0xA6 / 255, blue: 0xF0 / 255, alpha: 1)
        : UIColor(red: 0x2F / 255, green: 0x5D / 255, blue: 0xB8 / 255, alpha: 1) }

    let canvas: PKCanvasView
    let page: Page
    let agent = Muse.bundled.map { Agent(muse: $0) }
    let jev = Jev.bundled
    var notes: [Note]
    var bubbles: [Bubble] = []
    var grids: [(view: Thinking, box: CGRect)] = []  // over boxes being drawn in
    var waiting: Task<Void, Never>?
    var lastTrigger: [String] = []
    var asking = 0
    weak var lastTag: UILabel?

    init(canvas: PKCanvasView, page: Page, notes: [Note]) {
        self.canvas = canvas
        self.page = page
        self.notes = notes
        notes.filter { $0.mark != "frame" }.forEach { add(Bubble(anchor: $0.anchor, zoom: $0.zoom, note: $0)) }  // a drawing is its own ink
        if agent == nil { logger.error("No MODEL_API_KEY in Secrets.xcconfig: marks are off") }
        if jev == nil { logger.error("No TYPESAFE_API_KEY in Secrets.xcconfig: only double dots are read") }
    }

    func penDown() { waiting?.cancel() }

    func penUp() {
        waiting?.cancel()
        waiting = Task {
            try? await Task.sleep(for: Self.pause)
            if !Task.isCancelled { look() }
        }
    }

    func stop() { waiting?.cancel() }

    static func id(_ stroke: PKStroke) -> String { "\(stroke.path.creationDate.timeIntervalSince1970)-\(stroke.randomSeed)" }

    /// Reads the latest strokes for a mark and, if they're new, asks about them.
    func look() {
        guard let agent, asking < Self.maxAsking else { return }
        let drawing = canvas.drawing, zoom = canvas.zoomScale
        let recent = drawing.strokes.filter { !AgentPen.wrote($0) }.suffix(12).map { stroke in
            let started = stroke.path.creationDate.timeIntervalSince1970
            return Grouping.Stroke(id: Self.id(stroke), bounds: stroke.renderBounds, started: started, ended: started + (stroke.path.last?.timeOffset ?? 0))
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
        let mark = marked.strokes.filter { selected.contains(Self.id($0)) }.reduce(CGRect.null) { $0.union($1.renderBounds) }
        let side = max(mark.width, mark.height) + 2 * Self.nearPad
        let near = CGRect(x: mark.midX - side / 2, y: mark.midY - side / 2, width: side, height: side)
        let visible = CGRect(x: canvas.contentOffset.x / zoom, y: canvas.contentOffset.y / zoom,
                             width: canvas.bounds.width / zoom, height: canvas.bounds.height / zoom)
        let around = visible.union(near)
        let threads = notes.filter { around.contains($0.anchor) }.map { Agent.Thread(id: $0.id, reading: $0.reading, shown: $0.shown) }
        let target = notes.filter { mark.insetBy(dx: -60 / zoom, dy: -60 / zoom).contains($0.anchor) }
            .min { hypot($0.anchor.x - mark.midX, $0.anchor.y - mark.midY) < hypot($1.anchor.x - mark.midX, $1.anchor.y - mark.midY) }?.id
        // A double dot is known on the device, so its orb shows at once. Anything else, Jev looks at first, and only a ? or
        // an empty box goes on to Muse.
        let thinking = dots == nil ? nil : add(Bubble(anchor: Self.anchor(mark, zoom), zoom: zoom))
        Task {
            let (nearPNG, aroundPNG) = await Self.crops(marked, near, around)
            var gesture = "double_dot"
            if dots == nil {
                guard let jev else { return }
                let start = ContinuousClock.now
                do {
                    let verdict = try await jev.mark(nearPNG)
                    gesture = verdict.mark
                    tag(verdict)
                } catch {
                    return logger.error("jev failed: \(error.localizedDescription, privacy: .public)")
                }
                logger.notice("jev mark=\(gesture, privacy: .public) ms=\(Int(start.duration(to: .now) / .milliseconds(1)))")
            }
            switch gesture {
            case "question":  // the orb shows from the moment Jev sees the ?
                await ask(agent, nearPNG, aroundPNG, gesture: gesture, threads: threads, target: target, trigger: trigger, mark: mark, zoom: zoom,
                          bubble: add(Bubble(anchor: Self.anchor(mark, zoom), zoom: zoom)))
            case "double_dot":
                await ask(agent, nearPNG, aroundPNG, gesture: gesture, threads: threads, target: target, trigger: trigger, mark: mark, zoom: zoom, bubble: thinking)
            case "frame":
                await draw(agent, nearPNG, aroundPNG, threads: threads, trigger: trigger, box: mark, zoom: zoom)
            default: break  // writing, circles, underlines and the rest are the person's own; nothing wakes
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

    /// Where a mark's dot sits: just right of its top-right corner.
    static func anchor(_ mark: CGRect, _ zoom: CGFloat) -> CGPoint { CGPoint(x: mark.maxX + 6 / zoom, y: mark.minY) }

    /// Whether the mark's strokes are all still on the page; the person may erase them while Muse reads or draws.
    func present(_ trigger: [String]) -> Bool { Set(canvas.drawing.strokes.map(Self.id)).isSuperset(of: trigger) }

    func remove(_ bubble: Bubble?) {
        bubble?.removeFromSuperview()
        bubbles.removeAll { $0 === bubble }
    }

    /// Answers a ? (as a quiet dot, with a nudge and a hint first) or a double dot. The dot is the thinking orb meanwhile.
    func ask(_ agent: Agent, _ near: Data, _ around: Data, gesture: String, threads: [Agent.Thread], target: String?,
             trigger: [String], mark: CGRect, zoom: CGFloat, bubble: Bubble?) async {
        guard present(trigger) else { return remove(bubble) }
        asking += 1
        defer { asking -= 1 }
        let start = ContinuousClock.now
        do {
            let answer = try await agent.ask(near: near, around: around, gesture: gesture, threads: threads, target: target)
            logger.notice("answered gesture=\(gesture, privacy: .public) ms=\(Int(start.duration(to: .now) / .milliseconds(1)))")
            guard present(trigger), !answer.reply.isEmpty else { return remove(bubble) }
            let note = Note(mark: gesture, trigger: trigger, anchor: Self.anchor(mark, zoom), zoom: zoom, reading: answer.reading,
                            reply: answer.reply, steps: gesture == "question" ? Array(answer.steps.prefix(2)) : [])
            notes.append(note)
            save()
            if let bubble { bubble.note = note } else { add(Bubble(anchor: note.anchor, zoom: zoom, note: note)) }
        } catch {
            logger.error("ask failed: \(error.localizedDescription, privacy: .public)")
            bubble?.retry = { [weak self, weak bubble] in
                bubble?.retry = nil
                Task { await self?.ask(agent, near, around, gesture: gesture, threads: threads, target: target,
                                       trigger: trigger, mark: mark, zoom: zoom, bubble: bubble) }
            }
        }
    }

    /// Fills an empty box with the agent's ink: a drawing, or a graph the app computes. A pixel grid shimmers in the box
    /// meanwhile; if drawing fails, an orange dot at its corner tries again.
    func draw(_ agent: Agent, _ near: Data, _ around: Data, threads: [Agent.Thread], trigger: [String], box: CGRect, zoom: CGFloat) async {
        guard present(trigger) else { return }
        let grid = Thinking(style: .pixels)
        canvas.addSubview(grid)
        grids.append((grid, box))
        grid.place(over: box, zoom: canvas.zoomScale)
        defer {
            grid.removeFromSuperview()
            grids.removeAll { $0.view === grid }
        }
        asking += 1
        defer { asking -= 1 }
        let start = ContinuousClock.now
        do {
            let drawing = try await agent.draw(near: near, around: around, size: box.size, threads: threads)
            guard present(trigger) else { return }
            let lines = try drawing.lines(in: box.size)
            // Bound the filled-in points too: a few huge strokes must not become millions of PencilKit samples.
            let step = 2 / zoom
            let length = lines.reduce(CGFloat(0)) { sum, line in sum + zip(line, line.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } }
            guard length / step < 100_000 else { throw Plot.Failure("The drawing is too complex") }
            let strokes = lines.map { line in
                AgentPen.stroke(line.map { CGPoint(x: box.minX + $0.x, y: box.minY + $0.y) }, width: AgentPen.width(at: zoom), step: step)
            }
            logger.notice("drew kind=\(drawing.kind, privacy: .public) strokes=\(strokes.count) ms=\(Int(start.duration(to: .now) / .milliseconds(1)))")
            let before = canvas.drawing
            var after = before
            after.strokes += strokes
            place(after, note: Note(mark: "frame", trigger: trigger, anchor: Self.anchor(box, zoom), zoom: zoom, reading: drawing.reading,
                                    reply: drawing.say, steps: []), replacing: before)
        } catch {
            logger.error("draw failed: \(error.localizedDescription, privacy: .public)")
            let failed = add(Bubble(anchor: Self.anchor(box, zoom), zoom: zoom))
            failed.retry = { [weak self, weak failed] in
                self?.remove(failed)
                Task { await self?.draw(agent, near, around, threads: threads, trigger: trigger, box: box, zoom: zoom) }
            }
        }
    }

    /// A drawing and its note arrive together and leave together, as one step of undo.
    func place(_ drawing: PKDrawing, note: Note, replacing previous: PKDrawing) {
        canvas.drawing = drawing
        notes.append(note)
        save()
        canvas.undoManager?.registerUndo(withTarget: self) { marks in
            marks.canvas.drawing = previous
            marks.notes.removeAll { $0.id == note.id }
            marks.save()
            marks.canvas.undoManager?.registerUndo(withTarget: marks) { $0.place(drawing, note: note, replacing: previous) }
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
        bubble.opened = { [weak self] note in
            guard let self, let i = notes.firstIndex(where: { $0.id == note.id }) else { return }
            notes[i] = note
            save()
        }
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
        grids.forEach { $0.view.place(over: $0.box, zoom: canvas.zoomScale) }
    }

    func save() {
        let notes = notes, url = page.notesFile
        Store.queue.async {
            do { try JSONEncoder().encode(notes).write(to: url, options: .atomic) }
            catch { logger.error("notes save failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
