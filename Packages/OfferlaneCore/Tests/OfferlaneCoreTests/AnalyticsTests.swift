import XCTest
@testable import OfferlaneCore

final class AnalyticsTests: XCTestCase {
    let now = Dates.isoSeconds.date(from: "2026-11-10T12:00:00")!

    func job(_ i: Int, _ title: String, _ status: JobStatus, variant: String, source: String) -> Job {
        var j = Job(company: "Co\(i)", title: title, id: "j\(i)"); j.status = status; j.variant = variant; j.source = source; return j
    }
    func ev(_ id: String, _ s: JobStatus, _ ts: String) -> JobEvent { JobEvent(jobId: id, status: s.rawValue, source: "t", detail: "", ts: ts) }

    /// 4 on "main" via greenhouse (2 replies, 1 interview), 3 on "ds" via remotive (0 replies), 1 not yet submitted.
    func fixture() -> ([Job], [JobEvent]) {
        let jobs = [
            job(1, "Data Scientist", .rejected, variant: "main", source: "ats:greenhouse"),
            job(2, "Senior Data Scientist", .screen, variant: "main", source: "ats:greenhouse"),
            job(3, "Data Scientist", .acknowledged, variant: "main", source: "ats:greenhouse"),
            job(4, "Software Engineer", .applied, variant: "main", source: "ats:greenhouse"),
            job(5, "Data Scientist", .applied, variant: "ds", source: "api:remotive"),
            job(6, "Data Scientist", .withdrawn, variant: "ds", source: "api:remotive"),
            job(7, "Data Scientist", .applied, variant: "ds", source: "api:remotive"),
            job(8, "Data Scientist", .review, variant: "main", source: ""),
        ]
        let events = [
            ev("j1", .applied, "2026-11-01T09:00:00"), ev("j1", .interview, "2026-11-03T09:00:00"), ev("j1", .rejected, "2026-11-08T09:00:00"),
            ev("j2", .applied, "2026-11-08T09:00:00"), ev("j2", .screen, "2026-11-09T09:00:00"),
            ev("j3", .applied, "2026-11-09T09:00:00"), ev("j3", .acknowledged, "2026-11-09T10:00:00"),
            ev("j4", .applied, "2026-10-01T09:00:00"),
            ev("j5", .applied, "2026-11-02T09:00:00"), ev("j6", .applied, "2026-11-02T09:00:00"), ev("j7", .applied, "2026-11-09T09:00:00"),
        ]
        return (jobs, events)
    }

    func testRatesAndBreakdowns() {
        let (jobs, events) = fixture()
        let r = Analytics.report(jobs: jobs, events: events, labels: ["main": "Main"], now: now)
        XCTAssertEqual(r.total.sent, 7, "the role still in review isn't submitted")
        XCTAssertEqual(r.total.responses, 2, "acknowledged and withdrawn aren't replies")
        XCTAssertEqual(r.total.interviews, 2, "a rejection after an interview still counts the interview")
        let v = Dictionary(uniqueKeysWithValues: r.byVersion.map { ($0.name, $0) })
        XCTAssertEqual(v["Main"]?.responseRate, 50); XCTAssertEqual(v["ds"]?.responseRate, 0)
        XCTAssertEqual(r.bySource.map(\.name), ["Greenhouse", "Remotive"])
        XCTAssertEqual(Set(r.byRole.map(\.name)), ["Data science", "Software engineering"])
    }

    func testRollingWeeks() {
        let (jobs, events) = fixture()
        let r = Analytics.report(jobs: jobs, events: events, now: now)
        XCTAssertEqual(r.thisWeek.sent, 3); XCTAssertEqual(r.lastWeek.sent, 3)
        XCTAssertEqual(r.thisWeek.responses, 1, "j2's screen; j1's first reply was last week")
        XCTAssertEqual(r.lastWeek.responses, 1)
    }

    func testSmallSlicesAreNotCompared() {
        let (jobs, events) = fixture()
        let r = Analytics.report(jobs: Array(jobs.prefix(2)), events: events, now: now)
        XCTAssertTrue(r.insights.last!.hasPrefix("Too few to compare"))
        XCTAssertTrue(Analytics.report(jobs: [], events: [], now: now).insights.isEmpty)
    }

    /// Invariant: no invented numbers. Every number in the insights is a count or rate in the report.
    func testInsightNumbersComeFromReport() {
        let (jobs, events) = fixture()
        let r = Analytics.report(jobs: jobs, events: events, now: now)
        XCTAssertTrue(r.insights.contains { $0.hasPrefix("Resume version \"main\"") })
        let groups = [r.total, r.thisWeek, r.lastWeek] + r.byVersion + r.bySource + r.byRole
        let known = Set(groups.flatMap { [$0.sent, $0.responses, $0.interviews, $0.responseRate, $0.interviewRate] } + [Analytics.minSample])
        for line in r.insights {
            let nums = line.split { !$0.isNumber }.compactMap { Int($0) }
            XCTAssertTrue(Set(nums).isSubset(of: known), line)
        }
    }

    func testStoreReportUsesTransitions() throws {
        let store = try Store()
        try DemoData.seedApplications(store)
        let r = try Analytics.report(store: store)
        XCTAssertEqual(r.total.sent, 4); XCTAssertEqual(r.total.responses, 2); XCTAssertEqual(r.thisWeek.sent, 4)
    }
}
