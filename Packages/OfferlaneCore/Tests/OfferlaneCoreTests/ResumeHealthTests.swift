import XCTest
@testable import OfferlaneCore

final class ResumeHealthTests: XCTestCase {
    static func resume() -> ResumeContent {
        var r = ResumeContent()
        r.name = "Ada Lovelace"; r.email = "ada@example.com"; r.phone = "+44 20 0000 0000"
        r.summary = String(repeating: "Partnerships lead working with founders and investors across Europe. ", count: 4)
        r.skills = [.init(label: "Core", items: "Partnerships, Python")]
        r.experience = [.init(id: "e1", title: "Partner Manager", company: "Cloudco", bullets: [
            .init(id: "b1", text: "Grew startup partnerships revenue 40% in 12 months"),
            .init(id: "b2", text: "Ran founder office hours"),
            .init(id: "b3", text: String(repeating: "word ", count: 40)),
        ])]
        return r
    }
    let role = "Head of AI Startups, EMEA"

    func testStructureChecksWithoutRole() {
        let r = Self.resume()
        let h = ResumeHealth.check(r, pdf: ResumePDF.render(r).0)
        let by = Dictionary(uniqueKeysWithValues: h.checks.map { ($0.id, $0) })
        XCTAssertTrue(by["ats"]!.pass); XCTAssertTrue(by["contact"]!.pass); XCTAssertTrue(by["skills"]!.pass)
        XCTAssertFalse(by["impact"]!.pass, "1 of 3 bullets has a number")
        XCTAssertEqual(by["impact"]!.bulletIds, ["b2", "b3"])
        XCTAssertEqual(by["length"]!.bulletIds, ["b3"])
        XCTAssertNil(by["keywords"], "no role, no keyword check")
        XCTAssertEqual(h.score, Int((55.0 / 80 * 100).rounded()))
    }

    func testKeywordsForRoleComeFromPostingsAndPDF() {
        let r = Self.resume()
        let scan = MarketScan.scan(SkillGapTests.postings, role: role)
        let h = ResumeHealth.check(r, pdf: ResumePDF.render(r).0, scan: scan)
        XCTAssertEqual(h.postings, 3)
        XCTAssertTrue(h.readable.contains { $0.lowercased().contains("partnership") })
        XCTAssertFalse(h.missing.isEmpty)
        XCTAssertEqual(Set(h.readable + h.missing), Set(scan.demand.prefix(ResumeHealth.topSkills).map(\.name)), "only skills employers asked for")
        XCTAssertNotNil(h.checks.first { $0.id == "keywords" })
    }

    func testUnreadablePDFFailsATS() {
        let h = ResumeHealth.check(Self.resume(), pdf: Data())
        XCTAssertFalse(h.checks.first { $0.id == "ats" }!.pass)
    }

    /// Invariant: findings cite only the resume's own bullets, and every number shown is a count, never a claim about the user.
    func testFindingsCiteOnlyResumeContent() {
        let r = Self.resume()
        let h = ResumeHealth.check(r, pdf: ResumePDF.render(r).0, scan: MarketScan.scan(SkillGapTests.postings, role: role))
        let ids = Set(r.sections.flatMap(\.bullets).map(\.id))
        for c in h.checks {
            XCTAssertTrue(Set(c.bulletIds).isSubset(of: ids), c.id)
            XCTAssertFalse(c.detail.contains("40%"), "the resume's figure is not echoed or altered")
        }
        let lexNames = Set(SkillLexicon.bundled.entries.map(\.name))
        XCTAssertTrue(Set(h.missing + h.readable).isSubset(of: lexNames), "skills only from the lexicon")
    }
}
