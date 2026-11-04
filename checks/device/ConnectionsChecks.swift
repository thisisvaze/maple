import Contacts
import EventKit
import Photos
import Testing
import UIKit
@testable import Maple

extension DeviceChecks {
    /// Calendar, reminders and contacts each find a real item and read it back, then remove it. Run on a simulator after
    /// granting access, as the README's Checks section shows.
    @Test func connectionsRead() async throws {
        for kind in [Connections.Kind.calendar, .reminders, .contacts] { try #require(kind.authorized, "Grant \(kind.rawValue) to dev.maple.muse first.") }

        // A day as the end runs to its end; a day as the start, from midnight.
        let (start, end) = try Connections.range("2026-11-06", "2026-11-06")
        #expect(Connections.formatter().string(from: start) == "Fri 2026-11-06 00:00" && Calendar.current.dateComponents([.day], from: start, to: end).day == 1)
        #expect(try Connections.range("2026-11-06T13:00", "2026-11-06T14:30:00").1.timeIntervalSince(start) == 14.5 * 3600)
        #expect(throws: Muse.Failure.self) { try Connections.range("next Friday", "2026-11-06") }
        #expect(throws: Muse.Failure.self) { try Connections.range("2026-11-07", "2026-11-06") }

        // Only what's switched on and allowed reaches Muse.
        let defaults = UserDefaults.standard, keys = Connections.Kind.allCases.map(\.key), previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        for key in keys { defaults.set(false, forKey: key) }
        #expect(!Connections.functions.contains { $0.name.hasPrefix("find_") })
        for key in keys { defaults.set(true, forKey: key) }
        let names = Set(Connections.functions.map(\.name))
        #expect(names.isSuperset(of: ["find_events", "find_reminders", "find_contacts"]) && names.contains("find_photos") == Connections.Kind.photos.authorized)

        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        let slot = try Connections.range("2026-11-06T13:00", "2026-11-06T14:00")
        event.title = "Lunch with Priya"
        event.location = "Blue Bottle, 66 Mint St"
        event.calendar = store.defaultCalendarForNewEvents
        event.startDate = slot.0
        event.endDate = slot.1
        try store.save(event, span: .thisEvent)
        defer { try? store.remove(event, span: .thisEvent) }
        let events = text(try await call(Connections.findEvents, ["from": "2026-11-06", "to": "2026-11-06", "text": "priya"]))
        #expect(events.contains("Lunch with Priya") && events.contains("Fri 2026-11-06 13:00") && events.contains("66 Mint St"), "\(events)")
        #expect(text(try await call(Connections.findEvents, ["from": "2026-11-06", "to": "2026-11-06", "text": "dentist"])) == "No events then.")

        let reminder = EKReminder(eventStore: store)
        reminder.title = "Buy 3.18 m of oak trim"
        reminder.calendar = store.defaultCalendarForNewReminders()
        try store.save(reminder, commit: true)
        defer { try? store.remove(reminder, commit: true) }
        let reminders = text(try await call(Connections.findReminders, ["text": "oak", "completed": false]))
        #expect(reminders.contains("Buy 3.18 m of oak trim"), "\(reminders)")
        #expect(text(try await call(Connections.findReminders, ["text": "oak", "completed": true])) == "No reminders match.")

        let person = CNMutableContact()
        person.givenName = "Priya"
        person.familyName = "Okafor-Check"
        person.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "415 555 0182"))]
        person.birthday = DateComponents(month: 3, day: 14)
        let save = CNSaveRequest()
        save.add(person, toContainerWithIdentifier: nil)
        try CNContactStore().execute(save)
        defer { let remove = CNSaveRequest(); remove.delete(person); try? CNContactStore().execute(remove) }
        let people = text(try await call(Connections.findContacts, ["name": "Okafor-Check"]))
        #expect(people.contains("Priya Okafor-Check") && people.contains("mobile: 415 555 0182") && people.contains("\"birthday\":\"03-14\""), "\(people)")

    }

    /// The simulator's privacy grant doesn't reach PhotoKit (iOS 26.5, 4 Nov), so this runs once Photos is allowed from
    /// Maple's Settings. On a simulator it adds a photo dated 3 Feb 2001 and leaves it, since deleting one asks the person;
    /// on an iPad it only reads the newest photos.
    @Test(.enabled(if: Connections.Kind.photos.authorized, "Photos access")) func photosRead() async throws {
        #if targetEnvironment(simulator)
        let taken = try Connections.range("2001-02-03T09:30", "2001-02-03T10:00").0
        try await PHPhotoLibrary.shared().performChanges {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            }
            PHAssetChangeRequest.creationRequestForAsset(from: image).creationDate = taken
        }
        let photos = try await call(Connections.findPhotos, ["from": "2001-02-03", "to": "2001-02-03"])
        #expect(text(photos).contains("Taken Sat 2001-02-03 09:30"), "\(text(photos))")
        #else
        let photos = try await call(Connections.findPhotos, ["from": "2000-01-01", "to": Connections.formatter("yyyy-MM-dd").string(from: .now)])
        #endif
        #expect(photos.contains { if case .jpeg(let data) = $0 { UIImage(data: data) != nil } else { false } }, "the photo itself goes to Muse")
    }
}

private func text(_ parts: [Muse.Part]) -> String {
    parts.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
}

private func call(_ run: (Data) async throws -> [Muse.Part], _ arguments: [String: Any]) async throws -> [Muse.Part] {
    try await run(try JSONSerialization.data(withJSONObject: arguments))
}
