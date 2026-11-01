import XCTest
@testable import OfferlaneCore

final class AnswerRulesTests: XCTestCase {
    /// Every label/consent combination and pick case gives the same answer as the prototype's browser.py.
    func testMatchesPrototype() throws {
        let fx = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("answers_expected.json"))
        let profileData = try JSONEncoder().encode(fx["profile"]!)
        let p = try JSONCoding.decoder.decode(Profile.self, from: profileData)
        let answers = AnswerRules.parseAnswers(fx["answers_md"]!.string!)
        XCTAssertEqual(answers.map(\.0), ["Cover letter", "Why Globex?", "Why do you want to work here?", "What is your biggest strength?"])
        let visa = Visa(profile: p, sponsorsDir: URL(fileURLWithPath: "/nonexistent"))
        var checked = 0
        for c in fx["want"]!.array! {
            var consent = false; if case .bool(true) = c["consent"]! { consent = true }
            let R = AnswerRules.rules(p, jobLocation: "London, UK", consent: consent, visa: visa)
            let f = FormField(type: c["type"]!.string!, label: c["label"]!.string!)
            let (v, _) = AnswerRules.want(f, R, answers)
            XCTAssertEqual(v, c["value"]?.string, "\(f.label) consent=\(consent)"); checked += 1
        }
        XCTAssertEqual(checked, 60)
        for c in fx["pick"]!.array! {
            XCTAssertEqual(AnswerRules.pick(c["options"]!.array!.compactMap(\.string), c["v"]!.string), c["pick"]?.string)
        }
    }

    func testFormURL() {
        var j = Job(company: "Spotify", title: "x", url: "https://jobs.lever.co/spotify/abc"); j.ats = "lever"
        XCTAssertEqual(AnswerRules.formURL(j), "https://jobs.lever.co/spotify/abc/apply")
        j = Job(company: "Scale", title: "x", url: "https://job-boards.greenhouse.io/scaleai/jobs/4567890?gh_src=x"); j.ats = "greenhouse"; j.atsSlug = "scaleai"
        XCTAssertEqual(AnswerRules.formURL(j), "https://job-boards.greenhouse.io/embed/job_app?for=scaleai&token=4567890")
        j = Job(company: "P", title: "x", url: "https://jobs.ashbyhq.com/perplexity/123"); j.ats = "ashby"
        XCTAssertEqual(AnswerRules.formURL(j), "https://jobs.ashbyhq.com/perplexity/123/application")
    }
}
