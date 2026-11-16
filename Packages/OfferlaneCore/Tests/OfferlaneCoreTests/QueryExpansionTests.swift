import XCTest
@testable import OfferlaneCore

final class QueryExpansionTests: XCTestCase {
    func testExpandsTitlesSeniorityAspirationsAndSkillsPerLocation() {
        var s = SearchConfig(); s.targetTitles = ["Senior Data Scientist"]; s.aspirations = ["Head of AI"]
        s.queries = ["machine learning engineer", "Data Scientist"]; s.locations = ["Berlin", "London"]; s.remoteOk = true
        var r = ResumeContent(); r.suggestedTitles = ["ML Engineer"]; r.topSkills = ["PyTorch", "SQL", "Spark"]
        let p = QueryExpansion.phrases(search: s, resume: r)
        XCTAssertEqual(p, ["senior data scientist", "head of ai", "machine learning engineer", "data scientist", "ml engineer",
                           "lead data scientist", "pytorch", "sql"], "deduped, adjacent + seniority + 2 skills")
        let q = QueryExpansion.queries(search: s, resume: r)
        XCTAssertEqual(q.count, 24, "capped")
        XCTAssertEqual(Array(q.prefix(3)), [SearchQuery("senior data scientist", where: "Berlin"), SearchQuery("senior data scientist", where: "London"),
                                           SearchQuery("senior data scientist")])
        s.remoteOk = false
        XCTAssertFalse(QueryExpansion.queries(search: s, resume: r).contains { $0.where == nil }, "no remote query unless remote is ok")
    }
}
