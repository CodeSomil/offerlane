import XCTest
@testable import OfferlaneCore

final class CareerPathTests: XCTestCase {
    let tracks = CareerPaths.bundled

    func testBundledLaddersAreWellFormed() {
        XCTAssertGreaterThanOrEqual(tracks.count, 10)
        let ids = Set(tracks.map(\.id))
        for t in tracks {
            XCTAssertGreaterThanOrEqual(t.ladder.count, 4, t.id)
            XCTAssertTrue(Set(t.pivots).isSubset(of: ids), "\(t.id) pivots to known tracks")
            XCTAssertFalse(t.pivots.contains(t.id))
        }
    }

    func testLocateKeepsSeniorityAndRejectsUnknownTitles() {
        XCTAssertEqual(CareerPaths.locate("Senior Data Scientist")?.level, 1)
        XCTAssertEqual(CareerPaths.locate("Data Scientist")?.level, 0)
        XCTAssertEqual(CareerPaths.locate("senior data scientist, forecasting")?.track.id, "data-science")
        XCTAssertNil(CareerPaths.locate("Pastry Chef"))
        XCTAssertNil(CareerPaths.locate(""))
    }

    func testHorizonsPivotsAndReadinessFromStoredPostings() throws {
        let st = try Store()
        for (c, t) in [("A", "Staff Data Scientist"), ("B", "Staff Data Scientist"), ("C", "Machine Learning Engineer")] {
            var j = Job(company: c, title: t, location: "London", url: "https://example.com/\(c)")
            j.description = "Python, SQL and Spark."; try st.upsert(j)
        }
        var r = ResumeContent(); r.skills = [.init(label: "Core", items: "Python")]
        try st.saveResume(ResumeVersion(name: "main", label: "Main", content: r, sourceText: "", sourceFile: "cv.txt"))

        let m = try CareerPaths.explore(current: "Senior Data Scientist", store: st)
        XCTAssertEqual(m.track?.id, "data-science"); XCTAssertEqual(m.level, 1)
        XCTAssertEqual(m.steps.map(\.role), ["Staff Data Scientist", "Principal Data Scientist", "Head of Data Science"])
        XCTAssertEqual(m.steps.map(\.years), [1, 3, 5])
        let staff = m.steps[0].report
        XCTAssertEqual(staff.postings, 2)
        XCTAssertTrue(staff.gaps.contains { $0.id == "sql" }); XCTAssertFalse(staff.gaps.contains { $0.id == "python" }, "resume covers Python")
        XCTAssertEqual(m.pivots.first?.role, "Senior Machine Learning Engineer", "pivot keeps the same level")

        // Invariant: every role comes from the curated ladders; every gap cites stored postings.
        let curated = Set(tracks.flatMap(\.ladder)), stored = Set(try st.jobs().map(\.id))
        for s in m.steps + m.pivots {
            XCTAssertTrue(curated.contains(s.role), s.role)
            for g in s.report.items { XCTAssertTrue(Set(g.demand.jobIds).isSubset(of: stored)) }
        }
    }

    func testTopOfLadderAndHandPickedTrack() throws {
        let st = try Store()
        let top = try CareerPaths.explore(current: "Head of Data Science", store: st)
        XCTAssertTrue(top.steps.isEmpty, "nothing above the top rung"); XCTAssertFalse(top.pivots.isEmpty)
        let near = try CareerPaths.explore(current: "Principal Data Scientist", store: st)
        XCTAssertEqual(near.steps.map(\.years), [1], "the 3- and 5-year steps would repeat the top rung")
        let none = try CareerPaths.explore(current: "Pastry Chef", store: st)
        XCTAssertNil(none.track); XCTAssertTrue(none.steps.isEmpty)
        let picked = try CareerPaths.explore(current: "Pastry Chef", trackId: "design", store: st)
        XCTAssertNil(picked.level); XCTAssertEqual(picked.steps.first?.role, "Product Designer")
    }

    func testSetGoalPutsRoleFirstAndKeepsFallbackRoles() throws {
        let st = try Store()
        var search = SearchConfig(); search.targetTitles = ["Data Scientist"]
        try CareerPaths.setGoal("Staff Data Scientist", years: 1, search: search, store: st)
        let s: SkillPlanState = try XCTUnwrap(st.get(.skillPlan))
        XCTAssertEqual(s.roles, ["Staff Data Scientist", "Data Scientist"]); XCTAssertEqual(s.goal, "Staff Data Scientist"); XCTAssertEqual(s.goalYears, 1)
        try CareerPaths.setGoal("Data Scientist", years: nil, search: search, store: st)
        XCTAssertEqual(try XCTUnwrap(st.get(.skillPlan) as SkillPlanState?).roles, ["Data Scientist", "Staff Data Scientist"])
    }
}
