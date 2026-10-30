import Foundation

/// What Maple remembers about the person, shared by every agent on every page. Agents never write it: they propose
/// changes and this plain code checks them. A claim has to quote the person's own words, so Maple's answers and page text
/// can't make facts about them. What they struck stays out, and what they wrote themselves no agent can change. Foundation
/// only, so `checks/memory-check.swift` can run it on the Mac.
nonisolated struct Memory: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        var id, text: String
        var author: String  // "maple", or "you" for what the person wrote on the Me page
        var because: String  // the person's words it rests on
        var page: String  // where they said it
        var date: Date
        var gone: String? = nil  // nil while it holds: "struck" by the person, or "replaced" by something they said later
    }

    /// What an agent asks to remember, and the person's words that show it.
    struct Proposal: Codable, Equatable, Sendable { var text, because: String }
    struct Forget: Codable, Equatable, Sendable { var id, because: String }

    /// What agents are shown.
    struct Line: Codable, Equatable, Sendable { var id, text: String }

    /// Every proposal and what became of it.
    struct Logged: Codable, Equatable, Sendable {
        var date: Date
        var action, text, why: String
    }

    var entries: [Entry] = []
    var log: [Logged] = []
    var next = 1

    // Calibration knobs.
    static let most = 40  // lines in memory: every call carries them, and recall gets worse as a prompt grows
    static let perMark = 2  // lines one mark can add
    static let longest = 90  // characters in a line, which is written on the Me page
    static let similar = 0.6  // how much two lines' words overlap to count as the same thing
    static let kept = 200  // log lines kept

    static let idle: Set<String> = ["a", "an", "the", "is", "are", "am", "i", "my", "me", "they", "their", "them", "to", "of", "and", "in", "on", "for", "with", "at", "by", "person", "user"]

    var active: [Entry] { entries.filter { $0.gone == nil } }
    var lines: [Line] { active.map { Line(id: $0.id, text: $0.text) } }

    /// Checks what an agent proposes against `evidence`, the person's words at this mark, and commits what holds up. Returns
    /// what went in and what went out.
    mutating func propose(_ proposals: [Proposal], forgetting: [Forget], evidence: String, page: String, date: Date = .now) -> (added: [Entry], forgotten: [Entry]) {
        var added: [Entry] = [], forgotten: [Entry] = []
        for forget in forgetting {
            guard let i = entries.firstIndex(where: { $0.id == forget.id && $0.gone == nil }) else { continue }
            guard entries[i].author == "maple" else { note(date, "refused", entries[i].text, "the person wrote it"); continue }
            guard Self.quotes(evidence, forget.because) else { note(date, "refused", entries[i].text, "no words of theirs say so"); continue }
            entries[i].gone = "replaced"
            forgotten.append(entries[i])
            note(date, "replaced", entries[i].text, forget.because)
        }
        for proposal in proposals {
            let text = proposal.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let why = refusal(text, proposal.because, evidence: evidence, adding: added.count) {
                note(date, "refused", text, why)
                continue
            }
            let entry = Entry(id: "m\(next)", text: text, author: "maple", because: proposal.because, page: page, date: date)
            next += 1
            entries.append(entry)
            added.append(entry)
            note(date, "added", text, proposal.because)
        }
        return (added, forgotten)
    }

    func refusal(_ text: String, _ because: String, evidence: String, adding: Int) -> String? {
        if text.isEmpty || text.count > Self.longest { return "not one short line" }
        if !Self.quotes(evidence, because) { return "it doesn't quote the person" }
        if entries.contains(where: { $0.gone == "struck" && Self.same($0.text, text) }) { return "the person struck it" }
        if active.contains(where: { Self.same($0.text, text) }) { return "already known" }
        if adding >= Self.perMark { return "too many at once" }
        if active.count >= Self.most { return "memory is full" }
        return nil
    }

    /// The person struck `ids` out, or undid that. Theirs to do with any line.
    mutating func strike(_ ids: Set<String>, date: Date = .now) -> [Entry] {
        var struck: [Entry] = []
        for i in entries.indices where ids.contains(entries[i].id) && entries[i].gone == nil {
            entries[i].gone = "struck"
            struck.append(entries[i])
            note(date, "struck", entries[i].text, "the person")
        }
        return struck
    }

    mutating func restore(_ ids: Set<String>, date: Date = .now) {
        for i in entries.indices where ids.contains(entries[i].id) && entries[i].gone == "struck" {
            entries[i].gone = nil
            note(date, "restored", entries[i].text, "the person")
        }
    }

    /// What the person has written on the Me page now, read line by line. It stands in for what they wrote before, since
    /// their ink is the record: a line they rubbed out goes.
    mutating func written(_ lines: [String], page: String, date: Date = .now) {
        let lines = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(Self.most)
        for entry in entries where entry.author == "you" && !lines.contains(entry.text) { note(date, "rubbed out", entry.text, "the person") }
        entries.removeAll { $0.author == "you" && !lines.contains($0.text) }
        for line in lines where !entries.contains(where: { $0.author == "you" && $0.text == line }) {
            entries.append(Entry(id: "m\(next)", text: String(line.prefix(200)), author: "you", because: line, page: page, date: date))
            next += 1
            note(date, "written", line, "the person")
        }
    }

    mutating func note(_ date: Date, _ action: String, _ text: String, _ why: String) {
        log.append(Logged(date: date, action: action, text: text, why: why))
        if log.count > Self.kept { log.removeFirst(log.count - Self.kept) }
    }

    /// `words` as plain lower-case words, however they're punctuated.
    static func plain(_ words: String) -> String {
        words.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }.reduce(into: "") { $0.append($1) }.split(separator: " ").joined(separator: " ")
    }

    /// Whether `quote` is really in `evidence`, as whole words.
    static func quotes(_ evidence: String, _ quote: String) -> Bool {
        let quote = plain(quote)
        return !quote.isEmpty && (" " + plain(evidence) + " ").contains(" " + quote + " ")
    }

    /// Whether two lines say the same thing, by the words they share.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Set(plain(a).split(separator: " ").map(String.init)).subtracting(idle), y = Set(plain(b).split(separator: " ").map(String.init)).subtracting(idle)
        guard !x.isEmpty, !y.isEmpty else { return plain(a) == plain(b) }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= similar
    }
}
