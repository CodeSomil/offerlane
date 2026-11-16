import XCTest
@testable import OfferlaneCore

final class NetworkingTests: XCTestCase {
    func resume() -> ResumeContent {
        var r = ResumeContent()
        r.name = "Sam Lee"
        r.experience = [.init(id: "exp1", title: "Data Scientist", company: "Acme", bullets: [.init(id: "b1", text: "Cut churn by 12% with a Python model.")]),
                        .init(id: "exp2", title: "Analyst", company: "Globex", bullets: [])]
        var e = ResumeContent.EducationItem(); e.school = "State University"; r.education = [e]
        return r
    }
    func job(_ company: String = "Initech") -> Job {
        var j = Job(company: company, title: "Senior Data Scientist", location: "London", url: "https://example.com/j"); j.description = "Python and SQL. Team of 8."
        return j
    }
    func ai(_ body: String) -> AI {
        AI(client: FakeLLM(rules: [{ _ in "{\"subject\":\"Hello\",\"body\":\(String(data: try! JSONSerialization.data(withJSONObject: [body]), encoding: .utf8)!.dropFirst().dropLast())}" }]), store: nil)
    }

    func testIdeasComeFromResumeEmployersAndSchools() {
        let ideas = Networking.ideas(job: job(), resume: resume()).map(\.text)
        XCTAssertEqual(ideas, ["Former colleagues from Acme who now work at Initech", "Former colleagues from Globex who now work at Initech",
                               "State University alumni who work at Initech", "The recruiter hiring for Senior Data Scientist at Initech",
                               "The hiring manager or a future teammate on the Senior Data Scientist team"])
        XCTAssertTrue(Networking.ideas(job: job("acme"), resume: resume()).first!.text.hasPrefix("You worked at acme before"))
        XCTAssertEqual(Networking.ideas(job: job(), resume: nil).count, 2)
    }

    func testFakeAIDraftIsKept() async {
        let d = await Networking.draft(.referral, job: job(), resume: resume(), ai: AI(client: FakeLLM.prototype, store: nil))
        XCTAssertNil(d.note); XCTAssertTrue(d.body.hasPrefix("Hi [Name]")); XCTAssertTrue(d.body.contains("Senior Data Scientist"))
    }

    // Invariant: a draft never carries a number, link or recipient name the resume and posting don't have.
    func testInventedFactsFallBackToTemplate() async {
        for bad in ["Hi [Name], I grew revenue 300%.", "Hi [Name], see https://me.example.com", "Hi Priya, I'd love to chat."] {
            let d = await Networking.draft(.recruiter, job: job(), resume: resume(), ai: ai(bad))
            XCTAssertEqual(d.body, Networking.template(.recruiter, job: job(), resume: resume()).body, bad)
            XCTAssertNotNil(d.note)
        }
        let ok = await Networking.draft(.recruiter, job: job(), resume: resume(), ai: ai("Hi there, I cut churn by 12% and work in a team of 8."))
        XCTAssertNil(ok.note)
        for k in OutreachKind.allCases {
            let t = Networking.template(k, job: job(), resume: resume())
            XCTAssertTrue(Guard.check(t.subject + "\n" + t.body, source: Networking.facts(job: job(), resume: resume())).ok)
            XCTAssertTrue(t.body.hasPrefix("Hi [Name]") && t.body.hasSuffix("Sam Lee"))
        }
    }

    func testNoAIOrBrokenAIUsesTemplate() async {
        let none = await Networking.draft(.followUp, job: job(), resume: nil, ai: nil)
        XCTAssertTrue(none.body.hasSuffix("[Your name]")); XCTAssertTrue(none.note?.contains("No AI") == true)
        let broken = await Networking.draft(.manager, job: job(), resume: resume(), ai: AI(client: FakeLLM(rules: [{ _ in "not json" }]), store: nil))
        XCTAssertTrue(broken.note?.contains("couldn't") == true)
    }
}
