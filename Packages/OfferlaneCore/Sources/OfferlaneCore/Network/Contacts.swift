import Foundation

/// A person the user is talking to about a role. Entered by the user only; Offerlane never looks people up or messages them.
public struct Contact: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID().uuidString
    public var name: String
    public var role = "", company = "", jobId = ""
    /// Where to reach them, as the user typed it (an email address, "LinkedIn", a phone note).
    public var channel = ""
    public var notes = ""
    /// ISO days ("yyyy-MM-dd").
    public var lastContacted: String?
    public var followUp: String?
    /// The follow-up day a notification was already posted for, so each date reminds once.
    public var remindedFor: String?

    public init(name: String) { self.name = name }

    enum CodingKeys: String, CodingKey { case id, name, role, company, jobId, channel, notes, lastContacted, followUp, remindedFor }
    /// Missing fields take their defaults, so a document written by an older or newer build never resets the list.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil) ?? "" }
        func o(_ k: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        id = o(.id) ?? UUID().uuidString
        name = s(.name); role = s(.role); company = s(.company); jobId = s(.jobId); channel = s(.channel); notes = s(.notes)
        lastContacted = o(.lastContacted); followUp = o(.followUp); remindedFor = o(.remindedFor)
    }
}

/// The contact and referral tracker: saved contacts plus follow-up reminders. Pure logic over the `contacts` document.
public enum Contacts {
    public static let defaultFollowUpDays = 7

    public static func load(_ store: Store) throws -> [Contact] { try store.get(.contacts) ?? [] }
    public static func save(_ contacts: [Contact], to store: Store) throws { try store.set(.contacts, contacts) }

    /// Read-modify-write on the stored list, so a screen's older copy never overwrites newer state (such as a recorded reminder).
    @discardableResult
    public static func change(_ store: Store, _ edit: (inout [Contact]) -> Void) throws -> [Contact] {
        var cs = try load(store); edit(&cs); try save(cs, to: store); return cs
    }
    /// Adds or replaces one contact by id. An unchanged follow-up date keeps its stored reminder mark.
    public static func upsert(_ c: Contact, in store: Store) throws {
        try change(store) { cs in
            var c = c
            if let i = cs.firstIndex(where: { $0.id == c.id }) {
                if cs[i].followUp == c.followUp { c.remindedFor = cs[i].remindedFor }
                cs[i] = c
            } else { cs.append(c) }
        }
    }
    public static func remove(id: String, in store: Store) throws { try change(store) { $0.removeAll { $0.id == id } } }

    /// Follow-ups dated today or earlier. Unreadable dates are never due.
    public static func due(_ contacts: [Contact], now: Date = Date()) -> [Contact] {
        let today = Dates.today(now)
        return contacts.filter { c in c.followUp.flatMap(Dates.day).map { Dates.today($0) <= today } ?? false }
    }
    /// Due follow-ups that haven't had a notification for their current date yet.
    public static func toRemind(_ contacts: [Contact], now: Date = Date()) -> [Contact] {
        due(contacts, now: now).filter { $0.remindedFor != $0.followUp }
    }
    public static func markReminded(_ contacts: [Contact], now: Date = Date()) -> [Contact] {
        let ids = Set(toRemind(contacts, now: now).map(\.id))
        return contacts.map { c in var c = c; if ids.contains(c.id) { c.remindedFor = c.followUp }; return c }
    }
    /// "I reached out today": records it and sets the next follow-up `days` later (0 = none).
    public static func markContacted(_ c: Contact, now: Date = Date(), days: Int = defaultFollowUpDays, calendar: Calendar = .current) -> Contact {
        var c = c
        c.lastContacted = day(now, calendar)
        c.followUp = days > 0 ? followUpDay(from: now, days: days, calendar: calendar) : nil
        c.remindedFor = nil
        return c
    }
    /// `days` calendar days later (not 24-hour blocks, so a clock change can't shift it by a day).
    public static func followUpDate(from now: Date = Date(), days: Int = defaultFollowUpDays, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: now) ?? now
    }
    static func followUpDay(from now: Date, days: Int, calendar: Calendar) -> String { day(followUpDate(from: now, days: days, calendar: calendar), calendar) }
    static func day(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
