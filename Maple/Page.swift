import PencilKit

/// A page is a folder in Documents/pages holding its ink.
struct Page: Identifiable, Hashable {
    static let folder = URL.documentsDirectory.appending(path: "pages")
    let url: URL
    var edited: Date  // when its ink was last saved, or when it was made
    var id: URL { url }
    var ink: URL { url.appending(path: "ink.drawing") }
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
}

/// Saves run one at a time, in order, off the main thread.
enum Store {
    static let queue = DispatchQueue(label: "maple.save", qos: .utility)
}

func modified(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
}
