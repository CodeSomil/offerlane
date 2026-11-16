import XCTest
@testable import OfferlaneCore

final class MarketIntelTests: XCTestCase {
    let now = Dates.day("2026-11-10")!
    func job(_ n: Int, _ title: String, _ loc: String, _ desc: String, daysAgo: Int) -> Job {
        var j = SkillGapTests.job("Co\(n)", title, loc, desc)
        j.posted = Dates.today(now.addingTimeInterval(-Double(daysAgo) * 86_400)); return j
    }

    func testCityGroupsByFirstPartAndRemote() {
        XCTAssertEqual(MarketIntel.city("London, UK"), "London")
        XCTAssertEqual(MarketIntel.city("Remote - EMEA"), "Remote")
        XCTAssertEqual(MarketIntel.city("Berlin (Hybrid)"), "Berlin")
        XCTAssertEqual(MarketIntel.city(""), "Unknown")
        let cities = MarketIntel.byCity(SkillGapTests.postings)
        XCTAssertEqual(cities.map(\.name), ["London", "Berlin", "Paris", "Remote"], "most postings first, ties by name")
        XCTAssertEqual(cities[0].postings, 2)
    }

    func testByRoleUsesRoleMatching() {
        let roles = MarketIntel.byRole(SkillGapTests.postings, roles: ["Head of AI Startups, EMEA", "Data Scientist", "Pilot"])
        XCTAssertEqual(roles.map(\.postings), [3, 1, 0])
        XCTAssertEqual(roles[0].top.prefix(2).map(\.id).sorted(), ["llm", "partnerships"], "both in 3 of 3; weight breaks the tie")
        XCTAssertLessThanOrEqual(roles[0].top.count, 5)
    }

    func testTrendNeedsEnoughHistory() {
        let few = (0..<4).map { job($0, "Data Scientist", "London", "Python", daysAgo: 2) } + (4..<10).map { job($0, "Data Scientist", "London", "SQL", daysAgo: 40) }
        let t = MarketIntel.trending(few, now: now)
        XCTAssertFalse(t.enough); XCTAssertTrue(t.rising.isEmpty && t.falling.isEmpty)
        XCTAssertEqual(t.recentPostings, 4); XCTAssertEqual(t.priorPostings, 6)
    }

    func testTrendRisingAndFallingCiteBothWindows() {
        let recent = (0..<5).map { job($0, "Data Scientist", "London", $0 < 4 ? "Python and LLMs" : "SQL", daysAgo: 5) }
        let prior = (5..<10).map { job($0, "Data Scientist", "London", $0 < 6 ? "Python" : "SQL", daysAgo: 45) }
        let old = [job(99, "Data Scientist", "London", "LLMs", daysAgo: 90)]
        let t = MarketIntel.trending(recent + prior + old, now: now)
        XCTAssertTrue(t.enough)
        XCTAssertEqual(t.rising.first?.id, "llm", "0 → 4 of 5 is the biggest rise")
        XCTAssertEqual(t.falling.first?.id, "sql")
        let py = t.rising.first { $0.id == "python" }!
        XCTAssertEqual([py.recent, py.prior], [4, 1])
        XCTAssertEqual(py.demand.jobIds.count, 5, "cites postings from both windows")
        XCTAssertFalse(t.rising.contains { $0.demand.jobIds.contains(old[0].id) }, "postings older than two windows ignored")
    }

    /// Invariant: no invented skills or numbers. Every name is a lexicon entry and every count equals its cited postings.
    func testEverySkillIsFromTheLexiconAndCountsMatchCitations() {
        let jobs = SkillGapTests.postings
        let slices = MarketIntel.byCity(jobs) + MarketIntel.byRole(jobs, roles: ["Head of AI Startups, EMEA"])
        let lex = SkillLexicon.bundled, ids = Set(jobs.map(\.id))
        for s in slices {
            XCTAssertTrue(Set(s.jobIds).isSubset(of: ids))
            for d in s.top {
                XCTAssertEqual(lex.entry(d.id)?.name, d.name)
                XCTAssertEqual(d.count, d.jobIds.count)
                XCTAssertTrue(Set(d.jobIds).isSubset(of: Set(s.jobIds)), "a skill cites only postings in its slice")
            }
        }
    }
}
