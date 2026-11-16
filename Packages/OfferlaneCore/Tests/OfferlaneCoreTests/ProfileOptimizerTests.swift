import XCTest
@testable import OfferlaneCore

final class ProfileOptimizerTests: XCTestCase {
    func resume() -> ResumeContent {
        var r = ResumeContent()
        r.name = "Sam Lee"
        r.experience = [.init(id: "exp1", title: "Data Scientist", company: "Acme", bullets: [.init(id: "b1", text: "Cut churn by 12% with a Python model."),
                                                                                             .init(id: "b2", text: "Built SQL dashboards for sales.")])]
        r.projects = [.init(id: "p1", name: "Churn Lab", bullets: [.init(id: "b3", text: "Open-source churn toolkit in Python.")])]
        r.skills = [.init(label: "Tools", items: "Python, SQL")]
        return r
    }
    func ai(_ json: String) -> AI { AI(client: FakeLLM(rules: [{ _ in json }]), store: nil) }

    func testLinkChecks() {
        let r = resume()
        let missing = ProfileOptimizer.checks(resume: r, links: [:]).map(\.text)
        XCTAssertEqual(missing.count, 3); XCTAssertTrue(missing.allSatisfy { $0.hasPrefix("No ") })
        let bad = ProfileOptimizer.checks(resume: r, links: ["linkedin": "http://linkedin.com/company/acme?trk=x", "github": "https://gitlab.com/sam", "portfolio": "sam.dev"]).map(\.text)
        XCTAssertEqual(bad.count, 4, "\(bad)")  // http, not own profile, tracking, wrong host
        XCTAssertTrue(ProfileOptimizer.checks(resume: r, links: ["linkedin": "https://www.linkedin.com/in/sam-lee", "github": "github.com/sam", "portfolio": "https://sam.dev"]).isEmpty)
    }

    func testPastedTextCrossCheck() {
        let ok = ["linkedin": "https://linkedin.com/in/sam", "github": "https://github.com/sam", "portfolio": "https://sam.dev"]
        let f = ProfileOptimizer.checks(resume: resume(), links: ok, pasted: "Data Scientist at Globex. I love Python.")
        XCTAssertEqual(f.map(\.text), ["Your LinkedIn text doesn't mention Acme.", "Skills on your resume your LinkedIn text doesn't mention: SQL"])
        XCTAssertEqual(f.map(\.cites), [["exp1"], ["skills"]])
    }

    func testTemplateIsVerbatimResume() {
        let t = ProfileOptimizer.template(resume())
        XCTAssertEqual(t.map(\.kind), [.headline, .about, .skills, .portfolio, .portfolio])
        XCTAssertEqual(t[0].text, "Data Scientist | Python | SQL")
        XCTAssertEqual(t[3].title, "Churn Lab"); XCTAssertEqual(t[4].text, "Cut churn by 12% with a Python model.")
    }

    func testFakeAIKeptAndMergedWithTemplate() async {
        let a = await ProfileOptimizer.suggest(resume: resume(), role: "Data Scientist", ai: AI(client: FakeLLM.prototype, store: nil))
        XCTAssertNil(a.note)
        XCTAssertEqual(a.suggestions.first?.text, "Building useful tools with data")
        XCTAssertEqual(a.suggestions.first?.cites, ["b1"])
        XCTAssertTrue(a.suggestions.contains { $0.kind == .skills })  // AI gave none: the template's fills in
    }

    // Invariant: every suggestion cites real resume ids, and no number or link the resume lacks survives.
    func testInventedFactsAreDropped() async {
        let bad = """
        {"headline":{"text":"Grew revenue 300%","cites":["b1"]},
         "about":{"text":"See https://sam.dev","cites":["b1"]},
         "skills":{"items":["Python","Kubernetes"],"cites":["skills"]},
         "portfolio":[{"title":"Churn Lab","text":"Churn toolkit in Python.","cites":["nope"]},{"title":"Dash","text":"SQL dashboards.","cites":[]}]}
        """
        let a = await ProfileOptimizer.suggest(resume: resume(), role: "", ai: ai(bad))
        XCTAssertEqual(a.suggestions, ProfileOptimizer.template(resume()))
        XCTAssertTrue(a.note?.hasPrefix("5 AI suggestions") == true, a.note ?? "")
        let r = resume(), ids = ProfileOptimizer.ids(r), src = ProfileOptimizer.source(r)
        for s in a.suggestions {
            XCTAssertFalse(s.cites.isEmpty); XCTAssertTrue(s.cites.allSatisfy(ids.contains), s.text)
            XCTAssertTrue(Guard.check(s.text, source: src).ok, s.text)
        }
        let good = await ProfileOptimizer.suggest(resume: r, role: "", ai: ai(#"{"skills":{"items":["Python","SQL"],"cites":["skills"]}}"#))
        XCTAssertNil(good.note); XCTAssertEqual(good.suggestions.first { $0.kind == .skills }?.text, "Python, SQL")
    }

    func testNoAIOrBrokenAIUsesTemplate() async {
        let none = await ProfileOptimizer.suggest(resume: resume(), role: "", ai: nil)
        XCTAssertTrue(none.note?.contains("No AI") == true); XCTAssertEqual(none.suggestions, ProfileOptimizer.template(resume()))
        let broken = await ProfileOptimizer.suggest(resume: resume(), role: "", ai: ai("not json"))
        XCTAssertTrue(broken.note?.contains("couldn't") == true)
    }
}
