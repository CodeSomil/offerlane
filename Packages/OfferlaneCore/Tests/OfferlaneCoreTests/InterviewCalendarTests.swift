import XCTest
import GRDB
@testable import OfferlaneCore

final class InterviewCalendarTests: XCTestCase {
    let start = ISO8601DateFormatter().date(from: "2026-11-20T15:00:00Z")!
    let stamp = ISO8601DateFormatter().date(from: "2026-11-11T09:30:00Z")!

    func job(_ title: String = "Data Scientist", company: String = "Initech", at: Date?) -> Job {
        var j = Job(company: company, title: title, id: "job1"); j.status = .interview; j.url = "https://jobs.example.com/1"
        j.interviewAt = at.map { Dates.now($0) }   // stored in local time, like the app does
        return j
    }

    func testGoldenEvent() {
        let ics = InterviewCalendar.ics([job(at: start)], now: stamp)
        XCTAssertTrue(ics.contains("\r\n "), "the long description line is folded")
        XCTAssertEqual(ics.replacingOccurrences(of: "\r\n ", with: ""), [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Offerlane//Interviews//EN", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
            "BEGIN:VEVENT", "UID:job1-interview@offerlane.app", "DTSTAMP:20261111T093000Z",
            "DTSTART:20261120T150000Z", "DTEND:20261120T160000Z",
            "SUMMARY:Interview: Data Scientist at Initech",
            "DESCRIPTION:Interview stage in Offerlane.\\nPosting: https://jobs.example.com/1",
            "END:VEVENT", "END:VCALENDAR", "",
        ].joined(separator: "\r\n"))
    }

    /// Stored times are local wall-clock; across the US fall-back (2026-11-01) the same 10:00 must map to different UTC hours.
    func testLocalTimesAcrossDaylightSavingChange() {
        Dates.isoSeconds.timeZone = TimeZone(identifier: "America/New_York")
        defer { Dates.isoSeconds.timeZone = nil }   // nil = follow the system zone again, as before
        var before = job(at: nil); before.interviewAt = "2026-10-31T10:00:00"   // EDT, UTC-4
        var after = job(at: nil); after.interviewAt = "2026-11-02T10:00:00"     // EST, UTC-5
        let ics = InterviewCalendar.ics([before, after], now: stamp)
        XCTAssertTrue(ics.contains("DTSTART:20261031T140000Z"), ics)
        XCTAssertTrue(ics.contains("DTSTART:20261102T150000Z"), ics)
        XCTAssertTrue(ics.contains("DTEND:20261102T160000Z"), ics)
    }

    func testUndatedRolesAreLeftOut() {
        XCTAssertFalse(InterviewCalendar.ics([job(at: nil)], now: stamp).contains("BEGIN:VEVENT"))
        var bad = job(at: start); bad.interviewAt = "next tuesday"
        XCTAssertFalse(InterviewCalendar.ics([bad], now: stamp).contains("BEGIN:VEVENT"))
    }

    func testEscapesText() {
        let ics = InterviewCalendar.ics([job("ML, Search; Ads\\Infra", company: "A\nB", at: start)], now: stamp)
        XCTAssertTrue(ics.contains("SUMMARY:Interview: ML\\, Search\\; Ads\\\\Infra at A\\nB"), ics)
    }

    func testFoldsLongLinesAt75OctetsWithoutSplittingCharacters() {
        let ics = InterviewCalendar.ics([job(String(repeating: "é", count: 80), at: start)], now: stamp)
        for line in ics.components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.utf8.count, 75, line) }
        let unfolded = ics.replacingOccurrences(of: "\r\n ", with: "")
        XCTAssertTrue(unfolded.contains("SUMMARY:Interview: " + String(repeating: "é", count: 80) + " at Initech"))
        XCTAssertFalse(ics.contains("\u{FFFD}"))
    }

    func testInterviewDateMigrationKeepsOldRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v3-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let q = try DatabaseQueue(path: url.path)
            try Store.migrator.migrate(q, upTo: "v3-job-tier")
            try q.write { try $0.execute(sql: "INSERT INTO job(id, company, title, location, status) VALUES ('j', 'Globex', 'Analyst', 'London', 'interview')") }
        }
        let store = try Store(url: url)
        XCTAssertNil(try store.job("j")?.interviewAt)
        _ = try store.update("j") { $0.interviewAt = Dates.now(self.start) }
        XCTAssertEqual(try Store(url: url).job("j")?.interviewAt, Dates.now(start))
    }
}
