import XCTest
@testable import OfferlaneCore

final class CoachingTests: XCTestCase {
    let now = Dates.isoDay.date(from: "2026-11-11")!

    func report(this: Int, last: Int, replies: Int = 0, total: Int? = nil) -> AnalyticsReport {
        var r = AnalyticsReport()
        r.thisWeek.sent = this; r.thisWeek.responses = replies; r.lastWeek.sent = last; r.total.sent = total ?? (this + last)
        return r
    }
    func job(_ status: JobStatus, updated: String = "2026-11-10T09:00:00") -> Job {
        var j = Job(company: "Co", title: "Role"); j.status = status; j.updated = updated; return j
    }

    func testNothingSentYet() {
        let c = Coaching.weekly(report: AnalyticsReport(), tracked: [], contactsDue: 0, now: now)
        XCTAssertTrue(c.headline.hasPrefix("No applications yet"))
        XCTAssertEqual(c.points, ["Nothing urgent. Pick your best new match and tailor it."])
    }

    func testMomentumHeadline() {
        XCTAssertTrue(Coaching.weekly(report: report(this: 5, last: 2), tracked: [], contactsDue: 0, now: now).headline.contains("5 this week, 2 last week"))
        XCTAssertTrue(Coaching.weekly(report: report(this: 1, last: 4), tracked: [], contactsDue: 0, now: now).headline.hasPrefix("Fewer"))
        XCTAssertTrue(Coaching.weekly(report: report(this: 3, last: 3), tracked: [], contactsDue: 0, now: now).headline.hasPrefix("Steady"))
        XCTAssertTrue(Coaching.weekly(report: report(this: 0, last: 0, total: 9), tracked: [], contactsDue: 0, now: now).headline.hasPrefix("Nothing sent"))
    }

    func testPointsComeFromCountsOnly() {
        var r = report(this: 2, last: 1, replies: 2)
        r.byVersion = [AnalyticsGroup(name: "ml", sent: 4, responses: 2), AnalyticsGroup(name: "data", sent: 3, responses: 0)]
        let tracked = [job(.applied, updated: "2026-10-01T09:00:00"), job(.interview), job(.screen)]
        let c = Coaching.weekly(report: r, tracked: tracked, contactsDue: 2, now: now)
        XCTAssertEqual(c.points, [
            "2 replies arrived this week. Answer them within a day.",
            "2 roles are at screen or interview. Prepare one STAR story for each.",
            "1 application has been quiet for 14+ days. A short follow-up is worth sending.",
            "2 follow-ups with people are due (Pipeline → People).",
            "Resume \"ml\" gets the most replies (50% of 4). Use it for similar roles.",
        ])
        let digits = Set(c.points.joined().filter(\.isNumber))
        XCTAssertTrue(digits.isSubset(of: Set("0124568")), "only counts from the inputs")
    }

    func testSmallSamplesAreNotCompared() {
        var r = report(this: 1, last: 1)
        r.byVersion = [AnalyticsGroup(name: "ml", sent: 2, responses: 2), AnalyticsGroup(name: "data", sent: 2, responses: 0)]
        XCTAssertFalse(Coaching.weekly(report: r, tracked: [], contactsDue: 0, now: now).points.joined().contains("Resume"))
    }
}
