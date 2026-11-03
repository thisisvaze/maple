// swiftc -swift-version 6 -parse-as-library Maple/Memory.swift checks/memory-check.swift -o /tmp/memory-check && /tmp/memory-check
import Foundation

@main
struct Check {
    static func main() throws {
        typealias P = Memory.Proposal
        let said = "I'm a nurse, so what's a safe paracetamol dose for a 20 kg child?"
        var memory = Memory()

        // A claim stands only on the person's own words, however they're punctuated.
        var result = memory.propose([P(text: "Is a nurse", because: "i'm a NURSE,")], forgetting: [], evidence: said, page: "p1")
        precondition(result.added.map(\.text) == ["Is a nurse"] && memory.lines == [.init(id: "m1", text: "Is a nurse")], "a quoted claim goes in")
        for (text, because) in [("Is a doctor", "I'm a doctor"), ("Likes cats", ""), ("Is a nur", "nur"), ("Has a child", "a 20 kg kid")] {
            result = memory.propose([P(text: text, because: because)], forgetting: [], evidence: said, page: "p1")
            precondition(result.added.isEmpty, "\(text) quotes nothing they said")
        }
        precondition(memory.log.last?.action == "refused" && memory.log.last?.why == "it doesn't quote the person", "refusals are logged")
        result = memory.propose([P(text: String(repeating: "long ", count: 30), because: "nurse")], forgetting: [], evidence: said, page: "p1")
        precondition(result.added.isEmpty, "one short line")

        // The same thing isn't added twice, and a mark adds only a little.
        result = memory.propose([P(text: "is a NURSE", because: "nurse")], forgetting: [], evidence: said, page: "p2")
        precondition(result.added.isEmpty && memory.active.count == 1, "already known")
        result = memory.propose(["Works in health care", "Looks after children", "Gives doses"].map { P(text: $0, because: "nurse") }, forgetting: [], evidence: said, page: "p2")
        precondition(result.added.count == 2 && memory.log.last?.why == "too many at once", "two at most from one mark")

        // What they strike stays out, whatever an agent proposes later; undoing the strike brings it back.
        let struck = memory.strike(["m1"])
        precondition(struck.map(\.id) == ["m1"] && !memory.lines.contains { $0.id == "m1" }, "struck")
        result = memory.propose([P(text: "A nurse", because: "nurse")], forgetting: [], evidence: said, page: "p3")
        precondition(result.added.isEmpty && memory.log.last?.why == "the person struck it", "a struck line can't come back")
        memory.restore(["m1"])
        precondition(memory.lines.contains { $0.id == "m1" }, "undone")

        // An agent can retire a line of its own only on the person's words; what they wrote no agent can touch.
        let moved = "I moved to Berlin last week, best bakery nearby?"
        result = memory.propose([], forgetting: [.init(id: "m1", because: "lives in Paris")], evidence: moved, page: "p4")
        precondition(result.forgotten.isEmpty && memory.lines.contains { $0.id == "m1" }, "no words of theirs say so")
        result = memory.propose([], forgetting: [.init(id: "m1", because: "I moved to Berlin")], evidence: moved, page: "p4")
        precondition(result.forgotten.map(\.id) == ["m1"], "replaced")
        result = memory.propose([P(text: "A nurse", because: "nurse")], forgetting: [], evidence: said, page: "p5")
        precondition(result.added.count == 1, "replaced isn't struck: they can say it again")
        memory.written(["Vegetarian", "Exam on Friday"], page: "me")
        let theirs = memory.entries.first { $0.text == "Vegetarian" }!
        result = memory.propose([], forgetting: [.init(id: theirs.id, because: "I moved to Berlin")], evidence: moved, page: "p6")
        precondition(result.forgotten.isEmpty && memory.log.last?.why == "the person wrote it", "their own lines are theirs")

        // Their ink is the record: what they rub out goes, and a line that stays keeps its id.
        memory.written(["Vegetarian"], page: "me")
        precondition(memory.active.filter { $0.author == "you" }.map(\.id) == [theirs.id], "rubbed out")

        // Stored text is capped at 200 characters; rereading the same long line keeps its identity and log.
        var longMemory = Memory()
        let longLine = String(repeating: "a", count: 201)
        longMemory.written([longLine], page: "me")
        let firstRead = longMemory
        longMemory.written([" \(longLine)\n"], page: "me")
        precondition(longMemory == firstRead, "an unchanged long line is not removed and added again")

        // Memory stops growing, the log is bounded, and it all saves.
        for n in 0..<60 { _ = memory.propose([P(text: "Unique thing \(n * 7919) zebra\(n)", because: "nurse")], forgetting: [], evidence: said, page: "p7") }
        precondition(memory.active.count == Memory.most && memory.log.last?.why == "memory is full", "full: \(memory.active.count)")
        for _ in 0..<300 { memory.note(.now, "refused", "x", "y") }
        precondition(memory.log.count == Memory.kept)
        let saved = try JSONDecoder().decode(Memory.self, from: JSONEncoder().encode(memory))
        precondition(saved == memory, "it saves")
        precondition(Memory.same("Prefers hints before answers", "prefers hints before the answers") && !Memory.same("Is a nurse", "Is a pilot"))
        print("memory ok: quoted claims, duplicates, strikes, replacing, the person's lines, limits")
    }
}
