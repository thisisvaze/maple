import PencilKit
import os

nonisolated let log = Logger(subsystem: "dev.maple", category: "marks")

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
    var notes: [Note]
    var bubbles: [Bubble] = []
    var waiting: Task<Void, Never>?
    var lastTrigger: [String] = []
    var asking = 0

    init(canvas: PKCanvasView, page: Page, notes: [Note]) {
        self.canvas = canvas
        self.page = page
        self.notes = notes
        notes.forEach { add(Bubble(anchor: $0.anchor, zoom: $0.zoom, note: $0)) }
        if agent == nil { log.error("No MODEL_API_KEY in Secrets.xcconfig: marks are off") }
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
        let recent = drawing.strokes.suffix(12).map { stroke in
            let started = stroke.path.creationDate.timeIntervalSince1970
            return Grouping.Stroke(id: Self.id(stroke), bounds: stroke.renderBounds, started: started, ended: started + (stroke.path.last?.timeOffset ?? 0))
        }
        let dots = Grouping.doubleDot(recent, reach: Self.doubleDotReach / zoom)
        let trigger = dots ?? Grouping.candidate(recent)
        // ponytail: every pen pause costs one Muse call (~0.5¢); filter on the device first if pages get long.
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
        let gesture = dots == nil ? nil : "double_dot"
        let anchor = CGPoint(x: mark.maxX + 6 / zoom, y: mark.minY)

        // A double dot is known on the device, so it shows thinking at once; a ? only shows once Muse calls it one.
        let bubble = gesture == nil ? nil : add(Bubble(anchor: anchor, zoom: zoom))
        Task {
            let (nearPNG, aroundPNG) = await Self.crops(marked, near, around)
            await ask(agent, nearPNG, aroundPNG, gesture: gesture, threads: threads, target: target,
                      trigger: trigger, anchor: anchor, zoom: zoom, bubble: bubble)
        }
    }

    func ask(_ agent: Agent, _ near: Data, _ around: Data, gesture: String?, threads: [Agent.Thread], target: String?,
             trigger: [String], anchor: CGPoint, zoom: CGFloat, bubble: Bubble?) async {
        asking += 1
        defer { asking -= 1 }
        let start = ContinuousClock.now
        do {
            let answer = try await agent.ask(near: near, around: around, gesture: gesture, threads: threads, target: target)
            log.notice("mark=\(answer.mark, privacy: .public) gesture=\(gesture ?? "-", privacy: .public) ms=\(Int(start.duration(to: .now) / .milliseconds(1)))")
            // The person may have erased the mark while Muse was reading it.
            let present = Set(canvas.drawing.strokes.map(Self.id))
            guard trigger.allSatisfy(present.contains), gesture != nil || answer.mark == "question", !answer.reply.isEmpty else {
                bubble?.removeFromSuperview()
                bubbles.removeAll { $0 === bubble }
                return
            }
            let note = Note(mark: gesture ?? "question", trigger: trigger, anchor: anchor, zoom: zoom, reading: answer.reading,
                            reply: answer.reply, steps: gesture == nil ? Array(answer.steps.prefix(2)) : [])
            notes.append(note)
            save()
            if let bubble { bubble.note = note } else { add(Bubble(anchor: anchor, zoom: zoom, note: note)) }
        } catch {
            log.error("ask failed: \(error.localizedDescription, privacy: .public)")
            bubble?.retry = { [weak self, weak bubble] in
                bubble?.retry = nil
                Task { await self?.ask(agent, near, around, gesture: gesture, threads: threads, target: target,
                                       trigger: trigger, anchor: anchor, zoom: zoom, bubble: bubble) }
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
    func layout() { bubbles.forEach { $0.place(zoom: canvas.zoomScale) } }

    func save() {
        let notes = notes, url = page.notesFile
        Store.queue.async {
            do { try JSONEncoder().encode(notes).write(to: url, options: .atomic) }
            catch { log.error("notes save failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
