import PencilKit

/// A page is a folder in Documents/pages holding its ink and cached thumbnails.
nonisolated struct Page: Identifiable, Hashable {
    static let folder = URL.documentsDirectory.appending(path: "pages")
    static let aspect: CGFloat = 3 / 4  // card shape: the iPad held upright
    static let sheet: CGFloat = 131_072  // how wide and tall a page is
    let url: URL
    var edited: Date  // when its ink or answers were last saved, or when it was made
    var name: String?  // what the person called it, or else what Maple did
    var id: URL { url }
    var ink: URL { url.appending(path: "ink.drawing") }
    var notesFile: URL { url.appending(path: "notes.json") }
    var stateFile: URL { url.appending(path: "history.plist") }  // current ink, notes and the last 100 changes, atomically
    var contentFile: URL { FileManager.default.fileExists(atPath: stateFile.path) ? stateFile : ink }
    var nameFile: URL { url.appending(path: "name.txt") }  // the person's name for it, which Maple never changes
    var autoNameFile: URL { url.appending(path: "auto-name.txt") }  // Maple's, from the ink as it was then
    var readFile: URL { url.appending(path: "read.txt") }  // on the Me page: touched when its ink was last read
    var pictures: URL { url.appending(path: "pictures") }  // what Muse Image painted and the app computed, by file name
    var viewportKey: String { "viewport-\(url.lastPathComponent)" }
    var title: String { name ?? "Untitled page" }
    /// Maple names a page again once its ink has changed, until the person names it.
    var needsName: Bool { !FileManager.default.fileExists(atPath: nameFile.path) && modified(autoNameFile) < modified(contentFile) }

    /// The page of what Maple remembers, pinned first in the gallery. It's a page like any other, but it can't be deleted.
    static var me: Page { Page(url: folder.appending(path: "me"), edited: .distantPast) }
    var isMe: Bool { url.lastPathComponent == "me" }
    /// The person has written on the Me page since Maple last read it.
    var unread: Bool { isMe && modified(readFile) < modified(contentFile) }

    /// Last written in first, after the Me page. Thumbnails and names written into the folder don't count as edits.
    static func all() -> [Page] {
        if !FileManager.default.fileExists(atPath: me.nameFile.path) {
            try? FileManager.default.createDirectory(at: me.url, withIntermediateDirectories: true)
            try? "Me".write(to: me.nameFile, atomically: true, encoding: .utf8)
        }
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return urls.map { url in
            var page = Page(url: url, edited: .distantPast)
            page.edited = max(modified(page.contentFile), modified(page.notesFile), created(url))
            page.name = [page.nameFile, page.autoNameFile].lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first
            return page
        }.sorted { $0.isMe != $1.isMe ? $0.isMe : $0.edited > $1.edited }
    }

    static func create() -> Page {
        let page = Page(url: folder.appending(path: UUID().uuidString), edited: .now)
        try? FileManager.default.createDirectory(at: page.url, withIntermediateDirectories: true)  // a failure shows up as a save error
        return page
    }

    func load() throws -> PKDrawing {
        if let archive = try loadArchive() { return archive.current.drawing }
        return FileManager.default.fileExists(atPath: ink.path) ? try PKDrawing(data: Data(contentsOf: ink)) : PKDrawing()
    }

    func loadNotes() throws -> [Note] {
        if let archive = try loadArchive() { return archive.current.notes }
        return FileManager.default.fileExists(atPath: notesFile.path) ? try JSONDecoder().decode([Note].self, from: Data(contentsOf: notesFile)) : []
    }

    func loadArchive() throws -> History.Archive? {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return nil }
        return try PropertyListDecoder().decode(History.Archive.self, from: Data(contentsOf: stateFile)).validated()
    }

    /// Keeps a picture in the page's pictures folder, and gives its file name. Undo may bring it back, so it stays there.
    // ponytail: files of undone pictures pile up; sweep the ones no note or history step names if pages grow.
    func keep(_ picture: Data, as kind: String) throws -> String {
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        let name = UUID().uuidString + "." + kind
        try picture.write(to: pictures.appending(path: name), options: .atomic)
        return name
    }

    /// The person's name for the page; an empty one hands naming back to Maple.
    func rename(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { try? FileManager.default.removeItem(at: nameFile) }
        else { try? text.write(to: nameFile, atomically: true, encoding: .utf8) }
    }

    /// Muse names the page from all its ink, level as it last lay on screen, and what Maple read in the marks it answered.
    /// True when the name changed or was cleared: a page with no ink left goes back to Untitled.
    @concurrent func nameFromInk() async -> Bool {
        guard Marks.aiEnabled, !Task.isCancelled else { return false }
        guard let muse = Muse.bundled else { return false }
        let archive = try? loadArchive()
        guard let drawing = try? archive?.current.drawing ?? load() else { return false }
        guard !drawing.strokes.isEmpty else { return (try? FileManager.default.removeItem(at: autoNameFile)) != nil }
        let v = UserDefaults.standard.array(forKey: viewportKey) as? [Double] ?? []
        let level = drawing.transformed(using: CGAffineTransform(rotationAngle: v.count == 4 ? v[3] : 0))
        // ponytail: one picture of all the ink, so writing spread far apart gets small; crop to the densest part if names suffer.
        let png = Marks.png(level, level.bounds.insetBy(dx: -40, dy: -40))
        let readings = ((try? archive?.current.notes ?? loadNotes()) ?? []).map(\.reading)
        let current = try? String(contentsOf: autoNameFile, encoding: .utf8)
        guard Marks.aiEnabled, !Task.isCancelled else { return false }
        guard let name = try? await Agent(muse: muse).name(page: png, readings: readings, current: current) else { return false }
        guard Marks.aiEnabled, !Task.isCancelled else { return false }
        try? name.write(to: autoNameFile, atomically: true, encoding: .utf8)  // fails, rightly, if the page was deleted meanwhile
        return name != current
    }

    /// What the person wrote on the Me page, one line each, read from their ink alone. Nil if it couldn't be read.
    @concurrent func handwriting() async -> [String]? {
        guard Marks.aiEnabled, !Task.isCancelled else { return nil }
        guard let muse = Muse.bundled, var drawing = try? load() else { return nil }
        drawing.strokes.removeAll { !AgentPen.person($0) }
        guard !drawing.strokes.isEmpty else { return [] }
        let png = Marks.png(drawing, drawing.bounds.insetBy(dx: -40, dy: -40))
        guard Marks.aiEnabled, !Task.isCancelled else { return nil }
        return try? await Agent(muse: muse).readMe(page: png)
    }

    func delete() throws {
        try Store.queue.sync { try FileManager.default.removeItem(at: url) }  // after any save still queued
        UserDefaults.standard.removeObject(forKey: viewportKey)
    }

    /// The ink framed at the card's shape, cached as a PNG per appearance until the ink is saved again.
    @concurrent func thumbnail(dark: Bool) async -> UIImage? {
        let cached = url.appending(path: dark ? "thumb-dark.png" : "thumb-light.png")
        if modified(cached) >= modified(contentFile), let image = UIImage(contentsOfFile: cached.path) { return image }
        let archive = try? loadArchive()
        guard let drawing = try? archive?.current.drawing ?? load(), !drawing.strokes.isEmpty else { return nil }
        let b = drawing.bounds.insetBy(dx: -40, dy: -40)
        // Never closer than about a screen width, so a single word stays word-sized on its card.
        let width = max(b.width, b.height * Page.aspect, 1032)
        let frame = CGRect(x: b.midX - width / 2, y: b.midY - width / Page.aspect / 2, width: width, height: width / Page.aspect)
        let scale = 600 / width  // 600 px wide
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let painted = ((try? archive?.current.notes ?? loadNotes()) ?? []).filter { $0.picture != nil }
        let image = UIGraphicsImageRenderer(size: CGSize(width: frame.width * scale, height: frame.height * scale), format: format).image { context in
            context.cgContext.scaleBy(x: scale, y: scale)
            context.cgContext.translateBy(x: -frame.minX, y: -frame.minY)
            for note in painted {
                guard let rect = note.rect, let picture = UIImage(contentsOfFile: pictures.appending(path: note.picture ?? "").path) else { continue }
                context.cgContext.saveGState()
                context.cgContext.rotate(by: -(note.turn ?? 0))
                picture.fill(rect)
                context.cgContext.restoreGState()
            }
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
                drawing.image(from: frame, scale: scale).draw(in: frame)
            }
        }
        try? image.pngData()?.write(to: cached, options: .atomic)
        return image
    }
}

/// The one memory, in Documents. All of it changes here, on the main actor, and saves in order.
final class Memories {
    static let shared = Memories(file: URL.documentsDirectory.appending(path: "memory.json"))
    let file: URL
    private(set) var memory: Memory

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file) {
            if let saved = try? JSONDecoder().decode(Memory.self, from: data) {
                memory = saved
                return
            }
            try? data.write(to: file.deletingPathExtension().appendingPathExtension("unreadable.json"))  // never save over what we couldn't read
        }
        memory = Memory()
    }

    func change<Result>(_ edit: (inout Memory) -> Result) -> Result {
        let result = edit(&memory)
        let memory = memory, file = file
        Store.queue.async {
            do { try JSONEncoder().encode(memory).write(to: file, options: .atomic) }
            catch { logger.error("memory save failed: \(error.localizedDescription, privacy: .public)") }
        }
        return result
    }
}

/// Saves run one at a time, in order, off the main thread.
nonisolated enum Store {
    static let queue = DispatchQueue(label: "maple.save", qos: .utility)
}

nonisolated func modified(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
}

nonisolated func created(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
}
