import Contacts
import EventKit
import Photos
import UIKit

/// The iPad's own calendar, reminders, contacts and photos, each switched on in Settings. Muse reads them through
/// functions and never changes them; what it reads goes to Meta with the question.
nonisolated enum Connections {
    enum Kind: String, CaseIterable, Identifiable {
        case calendar = "Calendar", reminders = "Reminders", contacts = "Contacts", photos = "Photos"

        var id: String { rawValue }
        var key: String { "connect" + rawValue }
        var symbol: String {
            switch self {
            case .calendar: "calendar"
            case .reminders: "checklist"
            case .contacts: "person.crop.circle"
            case .photos: "photo.on.rectangle"
            }
        }

        /// Switched on in Settings, with access from iPadOS.
        var on: Bool { UserDefaults.standard.bool(forKey: key) && authorized }

        var authorized: Bool {
            switch self {
            case .calendar: EKEventStore.authorizationStatus(for: .event) == .fullAccess
            case .reminders: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
            case .contacts: [.authorized, .limited].contains(CNContactStore.authorizationStatus(for: .contacts))
            case .photos: [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite))
            }
        }

        /// Asks iPadOS the first time; after that it answers with what the person chose.
        func requestAccess() async -> Bool {
            switch self {
            case .calendar: (try? await EKEventStore().requestFullAccessToEvents()) ?? false
            case .reminders: (try? await EKEventStore().requestFullAccessToReminders()) ?? false
            case .contacts: (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
            case .photos: [.authorized, .limited].contains(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
            }
        }
    }

    /// Muse's functions for everything connected, Gmail included.
    static var functions: [Muse.Function] {
        let now = formatter().string(from: .now) + " (" + TimeZone.current.identifier + ")"
        let range = """
         "from": {"type": "string", "description": "Start: a day like 2026-11-06, or a time like 2026-11-06T14:30, in their time zone."},
         "to": {"type": "string", "description": "End, the same way. A day runs to its end."}
        """
        return Gmail.functions + [
            Kind.calendar.on ? Muse.Function(
                name: "find_events",
                description: "Finds events in the person's calendar between two times, newest last, optionally only those whose title, place or notes mention some words. It's now \(now). Use it when they ask what's on, when they're free, or when something is.",
                parameters: """
                {"type": "object", "additionalProperties": false, "required": ["from", "to", "text"], "properties": {\(range),
                 "text": {"type": "string", "description": "Words to look for, or empty for every event."}}}
                """) { try await findEvents($0) } : nil,
            Kind.reminders.on ? Muse.Function(
                name: "find_reminders",
                description: "Finds the person's reminders, with their lists, due dates and notes, optionally only those that mention some words. It's now \(now). Use it when they ask what they need to do or whether something's on a list.",
                parameters: """
                {"type": "object", "additionalProperties": false, "required": ["text", "completed"], "properties": {
                 "text": {"type": "string", "description": "Words to look for, or empty for every reminder."},
                 "completed": {"type": "boolean", "description": "true for ones they've checked off, false for ones still to do."}}}
                """) { try await findReminders($0) } : nil,
            Kind.contacts.on ? Muse.Function(
                name: "find_contacts",
                description: "Finds people in the person's contacts by name, with their phone numbers, email addresses, postal addresses, company and birthday.",
                parameters: """
                {"type": "object", "additionalProperties": false, "required": ["name"], "properties": {
                 "name": {"type": "string", "description": "A first name, last name or both, like: Priya, or: Sam Okafor"}}}
                """) { try await findContacts($0) } : nil,
            Kind.photos.on ? Muse.Function(
                name: "find_photos",
                description: "Shows you up to 4 of the person's photos taken between two times, newest first, with when and where each was taken. It's now \(now). Use it when they ask about a photo they took, like a whiteboard, a receipt, a sign or a menu, or where they were on a day. Narrow the times to find an older one.",
                parameters: """
                {"type": "object", "additionalProperties": false, "required": ["from", "to"], "properties": {\(range)}}
                """) { try await findPhotos($0) } : nil,
        ].compactMap { $0 }
    }

    static func findEvents(_ arguments: Data) async throws -> [Muse.Part] {
        struct Arguments: Decodable { var from, to, text: String }
        struct Event: Encodable { var title, start, end, place, calendar, notes: String; var allDay: Bool }
        let asked = try JSONDecoder().decode(Arguments.self, from: arguments)
        let (start, end) = try range(asked.from, asked.to)
        let store = EKEventStore(), time = formatter()
        let found = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { event in asked.text.isEmpty || [event.title, event.location, event.notes].contains { $0?.localizedCaseInsensitiveContains(asked.text) == true } }
            .prefix(30)
            .map { Event(title: $0.title ?? "", start: time.string(from: $0.startDate), end: time.string(from: $0.endDate), place: $0.location ?? "",
                         calendar: $0.calendar.title, notes: String(($0.notes ?? "").prefix(300)), allDay: $0.isAllDay) }
        return [.text(found.isEmpty ? "No events then." : json(found))]
    }

    static func findReminders(_ arguments: Data) async throws -> [Muse.Part] {
        struct Arguments: Decodable { var text: String; var completed: Bool }
        struct Reminder: Encodable, Sendable { var title, list, due, notes: String }
        let asked = try JSONDecoder().decode(Arguments.self, from: arguments)
        let store = EKEventStore()
        let predicate = asked.completed ? store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: nil)
                                        : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let found: [Reminder] = await withCheckedContinuation { done in
            store.fetchReminders(matching: predicate) { reminders in
                let time = formatter()
                done.resume(returning: (reminders ?? [])
                    .filter { asked.text.isEmpty || [$0.title, $0.notes].contains { $0?.localizedCaseInsensitiveContains(asked.text) == true } }
                    .prefix(50)
                    .map { Reminder(title: $0.title ?? "", list: $0.calendar.title, due: $0.dueDateComponents?.date.map(time.string) ?? "",
                                    notes: String(($0.notes ?? "").prefix(300))) })
            }
        }
        return [.text(found.isEmpty ? "No reminders match." : json(found))]
    }

    static func findContacts(_ arguments: Data) async throws -> [Muse.Part] {
        struct Arguments: Decodable { var name: String }
        struct Contact: Encodable { var name, company, birthday: String; var phones, emails, addresses: [String] }
        let asked = try JSONDecoder().decode(Arguments.self, from: arguments)
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactPhoneNumbersKey,
                    CNContactEmailAddressesKey, CNContactPostalAddressesKey, CNContactBirthdayKey] as [any CNKeyDescriptor]
        let found = try CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingName: asked.name), keysToFetch: keys)
            .prefix(10)
            .map { person in
                func labeled(_ label: String?, _ value: String) -> String {
                    label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) + ": " + value } ?? value
                }
                return Contact(name: [person.givenName, person.familyName].filter { !$0.isEmpty }.joined(separator: " "), company: person.organizationName,
                               birthday: person.birthday.map { b in [b.year, b.month, b.day].compactMap { $0 }.map { String(format: "%02d", $0) }.joined(separator: "-") } ?? "",
                               phones: person.phoneNumbers.map { labeled($0.label, $0.value.stringValue) },
                               emails: person.emailAddresses.map { labeled($0.label, $0.value as String) },
                               addresses: person.postalAddresses.map { labeled($0.label, CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress).replacing("\n", with: ", ")) })
            }
        return [.text(found.isEmpty ? "No one by that name." : json(found))]
    }

    static func findPhotos(_ arguments: Data) async throws -> [Muse.Part] {
        struct Arguments: Decodable { var from, to: String }
        let asked = try JSONDecoder().decode(Arguments.self, from: arguments)
        let (start, end) = try range(asked.from, asked.to)
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        guard assets.count > 0 else { return [.text("No photos then.")] }
        let time = formatter()
        var parts: [Muse.Part] = [.text("\(assets.count) photos then; the newest \(min(4, assets.count)) follow.")]
        for asset in assets.objects(at: IndexSet(integersIn: 0..<min(4, assets.count))) {
            let place = asset.location.map { String(format: " at %.4f, %.4f", $0.coordinate.latitude, $0.coordinate.longitude) } ?? ""
            parts.append(.text("Taken " + (asset.creationDate.map(time.string) ?? "at an unknown time") + place + ":"))
            let request = PHImageRequestOptions()
            request.deliveryMode = .highQualityFormat  // one callback, with the finished image
            request.isNetworkAccessAllowed = true  // photos kept in iCloud
            let jpeg: Data? = await withCheckedContinuation { done in
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1024, height: 1024), contentMode: .aspectFit, options: request) { image, _ in
                    done.resume(returning: image?.jpegData(compressionQuality: 0.7))
                }
            }
            parts.append(jpeg.map(Muse.Part.jpeg) ?? .text("(This photo couldn't be loaded.)"))
        }
        return parts
    }

    /// From and to as Muse gives them: a day ("2026-11-06") or a time on one ("2026-11-06T14:30"), in the person's time
    /// zone. A day as the end runs to its end, so from and to can be the same day.
    static func range(_ from: String, _ to: String) throws -> (Date, Date) {
        func date(_ text: String, end: Bool) throws -> Date {
            for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
                guard let date = formatter(format).date(from: text) else { continue }
                return end && format == "yyyy-MM-dd" ? Calendar.current.date(byAdding: .day, value: 1, to: date)! : date
            }
            throw Muse.Failure("A date is a day like 2026-11-06 or a time like 2026-11-06T14:30, not \(text)")
        }
        let range = (try date(from, end: false), try date(to, end: true))
        guard range.0 < range.1 else { throw Muse.Failure("to must come after from") }
        return range
    }

    /// Times as Muse reads them, in the person's time zone: "Fri 2026-11-06 13:00".
    static func formatter(_ format: String = "EEE yyyy-MM-dd HH:mm") -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}
