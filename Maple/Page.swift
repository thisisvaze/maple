import PencilKit

/// A page is a folder in Documents/pages holding its ink and cached thumbnails.
nonisolated struct Page: Identifiable, Hashable {
    static let folder = URL.documentsDirectory.appending(path: "pages")
    static let aspect: CGFloat = 3 / 4  // card shape: the iPad held upright
    let url: URL
    var edited: Date  // when its ink was last saved, or when it was made
    var id: URL { url }
    var ink: URL { url.appending(path: "ink.drawing") }
    var notesFile: URL { url.appending(path: "notes.json") }
    var viewportKey: String { "viewport-\(url.lastPathComponent)" }

    /// Last written in first.
    static func all() -> [Page] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return urls.map { url in
            let page = Page(url: url, edited: .distantPast)
            return Page(url: url, edited: max(modified(page.ink), modified(url)))
        }.sorted { $0.edited > $1.edited }
    }

    static func create() -> Page {
        let page = Page(url: folder.appending(path: UUID().uuidString), edited: .now)
        try? FileManager.default.createDirectory(at: page.url, withIntermediateDirectories: true)  // a failure shows up as a save error
        return page
    }

    func load() throws -> PKDrawing {
        FileManager.default.fileExists(atPath: ink.path) ? try PKDrawing(data: Data(contentsOf: ink)) : PKDrawing()
    }

    func loadNotes() throws -> [Note] {
        FileManager.default.fileExists(atPath: notesFile.path) ? try JSONDecoder().decode([Note].self, from: Data(contentsOf: notesFile)) : []
    }

    func delete() throws {
        try Store.queue.sync { try FileManager.default.removeItem(at: url) }  // after any save still queued
        UserDefaults.standard.removeObject(forKey: viewportKey)
    }

    /// The ink framed at the card's shape, cached as a PNG per appearance until the ink is saved again.
    @concurrent func thumbnail(dark: Bool) async -> UIImage? {
        let cached = url.appending(path: dark ? "thumb-dark.png" : "thumb-light.png")
        if modified(cached) >= modified(ink), let image = UIImage(contentsOfFile: cached.path) { return image }
        guard let drawing = try? load(), !drawing.strokes.isEmpty else { return nil }
        let b = drawing.bounds.insetBy(dx: -40, dy: -40)
        // Never closer than about a screen width, so a single word stays word-sized on its card.
        let width = max(b.width, b.height * Page.aspect, 1032)
        let frame = CGRect(x: b.midX - width / 2, y: b.midY - width / Page.aspect / 2, width: width, height: width / Page.aspect)
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
            image = drawing.image(from: frame, scale: 600 / width)  // 600 px wide
        }
        try? image?.pngData()?.write(to: cached, options: .atomic)
        return image
    }
}

/// Saves run one at a time, in order, off the main thread.
nonisolated enum Store {
    static let queue = DispatchQueue(label: "maple.save", qos: .utility)
}

nonisolated func modified(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
}
