import XCTest
@testable import OfferlaneCore

final class ContactsTests: XCTestCase {
    let now = Dates.isoDay.date(from: "2026-11-11")!

    func contact(_ name: String, followUp: String?) -> Contact {
        var c = Contact(name: name); c.company = "Initech"; c.followUp = followUp; return c
    }

    func testSavedAndLoaded() throws {
        let s = try Store()
        XCTAssertEqual(try Contacts.load(s), [])
        let c = contact("Ana", followUp: "2026-11-20")
        try Contacts.save([c], to: s)
        XCTAssertEqual(try Contacts.load(s), [c])
        try s.eraseEverything()
        XCTAssertEqual(try Contacts.load(s), [])
    }

    func testDueIsTodayOrEarlierOnly() {
        let cs = [contact("past", followUp: "2026-11-01"), contact("today", followUp: "2026-11-11"),
                  contact("later", followUp: "2026-11-12"), contact("none", followUp: nil), contact("bad", followUp: "soon")]
        XCTAssertEqual(Contacts.due(cs, now: now).map(\.name), ["past", "today"])
    }

    func testRemindsOncePerFollowUpDate() {
        var cs = [contact("Ana", followUp: "2026-11-10")]
        XCTAssertEqual(Contacts.toRemind(cs, now: now).map(\.name), ["Ana"])
        cs = Contacts.markReminded(cs, now: now)
        XCTAssertEqual(Contacts.toRemind(cs, now: now), [])
        XCTAssertEqual(Contacts.due(cs, now: now).map(\.name), ["Ana"], "still shown as due on Today")
        // Moving the date re-arms the reminder.
        cs[0].followUp = "2026-11-11"
        XCTAssertEqual(Contacts.toRemind(cs, now: now).map(\.name), ["Ana"])
    }

    func testMarkContactedSetsNextFollowUp() {
        var c = contact("Ana", followUp: "2026-11-01"); c.remindedFor = "2026-11-01"
        c = Contacts.markContacted(c, now: now)
        XCTAssertEqual(c.lastContacted, "2026-11-11")
        XCTAssertEqual(c.followUp, "2026-11-18")
        XCTAssertNil(c.remindedFor)
        XCTAssertEqual(Contacts.markContacted(c, now: now, days: 0).followUp, nil, "0 days means no follow-up")
    }

    func testOldDocumentsWithMissingFieldsStillDecode() throws {
        let c = try JSONCoding.decoder.decode(Contact.self, from: Data(#"{"id":"x","name":"Ana"}"#.utf8))
        XCTAssertEqual(c.name, "Ana"); XCTAssertNil(c.followUp); XCTAssertEqual(c.company, "")
    }

    func testSavingAStaleCopyKeepsTheRecordedReminder() throws {
        let s = try Store()
        let a = contact("Ana", followUp: "2026-11-10"), b = contact("Bo", followUp: nil)
        try Contacts.save([a, b], to: s)
        let stale = try Contacts.load(s)                       // what a view held before the reminder ran
        try Contacts.change(s) { $0 = Contacts.markReminded($0, now: self.now) }
        try Contacts.upsert(stale[0], in: s)                   // e.g. the editor saving Ana unchanged
        try Contacts.upsert(Contacts.markContacted(stale[1], now: now), in: s)
        XCTAssertEqual(Contacts.toRemind(try Contacts.load(s), now: now), [], "no second notification")
        try Contacts.remove(id: b.id, in: s)
        XCTAssertEqual(try Contacts.load(s).map(\.name), ["Ana"])
        var moved = stale[0]; moved.followUp = "2026-11-11"
        try Contacts.upsert(moved, in: s)
        XCTAssertEqual(Contacts.toRemind(try Contacts.load(s), now: now).map(\.name), ["Ana"], "a new date re-arms it")
    }

    func testFollowUpIsSevenCalendarDaysAcrossAClockChange() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/London")!
        let lateNight = cal.date(from: DateComponents(year: 2026, month: 3, day: 24, hour: 23, minute: 30))!   // spring forward is 29 March
        let c = Contacts.markContacted(Contact(name: "Ana"), now: lateNight, calendar: cal)
        XCTAssertEqual(c.followUp, "2026-03-31")
    }
}
