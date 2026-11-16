import XCTest
@testable import OfferlaneCore

final class PipelineHintsTests: XCTestCase {
    let now = Dates.isoSeconds.date(from: "2026-11-11T12:00:00")!
    func job(_ s: JobStatus, daysAgo: Int) -> Job {
        var j = Job(company: "Co", title: "T"); j.status = s
        j.updated = Dates.now(now.addingTimeInterval(Double(-daysAgo) * 86_400)); return j
    }

    func testStaleOnlyWhileWaitingOnEmployer() {
        XCTAssertEqual(PipelineHints.age(job(.applied, daysAgo: 16), now: now), 16)
        XCTAssertTrue(PipelineHints.isStale(job(.applied, daysAgo: 14), now: now), "14 days is the threshold")
        XCTAssertFalse(PipelineHints.isStale(job(.applied, daysAgo: 13), now: now))
        XCTAssertTrue(PipelineHints.isStale(job(.acknowledged, daysAgo: 30), now: now))
        XCTAssertFalse(PipelineHints.isStale(job(.interview, daysAgo: 30), now: now), "the ball is in the user's court, not quiet")
    }

    func testNextStepByStageAndAge() {
        XCTAssertEqual(PipelineHints.nextStep(job(.applied, daysAgo: 2), now: now), "Nothing to do yet")
        XCTAssertEqual(PipelineHints.nextStep(job(.applied, daysAgo: 8), now: now), "Wait; replies usually come in 7–10 days")
        XCTAssertEqual(PipelineHints.nextStep(job(.applied, daysAgo: 20), now: now), "Send a short follow-up")
        XCTAssertEqual(PipelineHints.nextStep(job(.interview, daysAgo: 1), now: now), "Prepare your STAR stories")
        XCTAssertEqual(PipelineHints.nextStep(job(.offer, daysAgo: 1), now: now), "Compare offers")
    }

    /// Calendar days, so the US clock change on 1 Nov can't make 14 days read as 13 (review finding).
    func testAgeCountsCalendarDaysAcrossClockChange() {
        var j = job(.applied, daysAgo: 0); j.updated = "2026-10-28T23:30:00"
        XCTAssertEqual(PipelineHints.age(j, now: now), 14)
        XCTAssertTrue(PipelineHints.isStale(j, now: now))
    }

    func testUnreadableDateIsAgeZero() {
        var j = job(.applied, daysAgo: 0); j.updated = "garbage"
        XCTAssertEqual(PipelineHints.age(j, now: now), 0)
        XCTAssertFalse(PipelineHints.isStale(j, now: now))
    }

    /// The shared cases (libs/core runs the same file).
    func testSharedCases() throws {
        struct Case: Decodable { let status: JobStatus; let updated: String; let age: Int; let stale: Bool; let next: String; let why: String }
        struct File: Decodable { let now: String; let cases: [Case] }
        let f = try JSONDecoder().decode(File.self, from: Fixture.data("core/pipeline_cases.json"))
        let now = Dates.isoSeconds.date(from: f.now)!
        XCTAssertGreaterThan(f.cases.count, 10)
        for c in f.cases {
            var j = Job(company: "Co", title: "T"); j.status = c.status; j.updated = c.updated
            XCTAssertEqual(PipelineHints.age(j, now: now), c.age, c.why)
            XCTAssertEqual(PipelineHints.isStale(j, now: now), c.stale, c.why)
            XCTAssertEqual(PipelineHints.nextStep(j, now: now), c.next, c.why)
        }
    }
}
