import XCTest
@testable import OfferlaneCore

final class OffersTests: XCTestCase {
    func visa(sponsor: Bool) -> Visa {
        var p = Profile(); p.authorization.authorizedCountries = ["United Kingdom"]; p.authorization.needsSponsorship = sponsor
        return Visa(profile: p, sponsorsDir: URL(fileURLWithPath: "/nonexistent"))
    }
    func job(_ id: String, _ title: String, _ desc: String, location: String = "London, UK") -> Job {
        var j = Job(company: "Co\(id)", title: title, location: location, id: id); j.description = desc; return j
    }
    var jobs: [Job] {
        [job("a", "Data Scientist", "Pay: $120,000 - $150,000 per year."),
         job("b", "Senior Data Scientist", "Salary range $130k–$170k plus equity."),
         job("c", "Data Scientist", "We raised $5M - $10M in funding. No range here."),
         job("d", "Product Designer", "£60k to £75k"),
         job("e", "Data Scientist", "$1,000 - $2,000 sign-on bonus")]
    }

    func testBandsComeFromMatchingPostingsOnly() {
        let b = Offers.bands(jobs: jobs, role: "Data Scientist")
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].low, 120_000); XCTAssertEqual(b[0].high, 170_000); XCTAssertEqual(b[0].median, 142_500)
        XCTAssertEqual(b[0].jobIds.sorted(), ["a", "b"])
        XCTAssertEqual(Offers.bands(jobs: jobs, role: "Plumber"), [])
    }

    func testCompareTotalsPositionAndVisa() {
        var o = Offer(); o.company = "Initech"; o.title = "Data Scientist"; o.location = "New York, NY"
        o.base = 110_000; o.bonus = 10_000; o.equityPerYear = 5_000; o.signOn = 20_000
        var p = o; p.id = "p"; p.location = "London, UK"; p.base = 160_000; p.signOn = 0; p.bonus = 0; p.equityPerYear = 0
        let rows = Offers.compare([p, o], jobs: jobs, visa: visa(sponsor: true))
        XCTAssertEqual(rows.map(\.offer.firstYear), [160_000, 145_000])
        XCTAssertEqual(rows[1].offer.yearly, 125_000)
        XCTAssertEqual(rows.map(\.position), ["within", "below"])
        XCTAssertEqual(rows.map(\.visa), ["ok", "h1b-lottery"])
        var j = job("x", "Analyst", ""); j.status = .offer
        XCTAssertEqual(Offers.drafts(jobs: jobs + [j], existing: []).map(\.jobId), ["x"])
        XCTAssertEqual(Offers.drafts(jobs: [j], existing: Offers.drafts(jobs: [j], existing: [])), [])
    }

    func row(sponsor: Bool = true) -> OfferRow {
        var o = Offer(); o.company = "Initech"; o.title = "Data Scientist"; o.location = "New York, NY"; o.base = 125_000
        return Offers.compare([o], jobs: jobs, visa: visa(sponsor: sponsor))[0]
    }
    func ai(_ body: String) -> AI {
        AI(client: FakeLLM(rules: [{ _ in String(data: try! JSONSerialization.data(withJSONObject: ["body": body]), encoding: .utf8)! }]), store: nil)
    }

    // Invariant: a script never carries a number, link or recipient name the user and the postings didn't supply.
    func testScriptGuardAndTemplate() async {
        for bad in ["Hi [Name], I have a competing offer of $190,000.", "Hi [Name], see https://levels.example.com", "Hi Priya, can we talk?"] {
            let s = await Offers.script(row(), expected: "", name: "Sam Lee", ai: ai(bad))
            XCTAssertEqual(s.body, Offers.template(row(), expected: "", name: "Sam Lee"), bad); XCTAssertNotNil(s.note)
        }
        let ok = await Offers.script(row(), expected: "", name: "Sam Lee", ai: ai("Hi [Name], postings list $120k–$170k; could we reach $170,000?"))
        XCTAssertNil(ok.note)
        let fake = await Offers.script(row(), expected: "", name: "", ai: AI(client: FakeLLM.prototype, store: nil))
        XCTAssertNil(fake.note); XCTAssertTrue(fake.body.hasPrefix("Hi [Name]"))
        for r in [row(), row(sponsor: false)] {
            for exp in ["", "150000 USD"] {
                let t = Offers.template(r, expected: exp, name: "Sam Lee")
                XCTAssertTrue(Guard.check(t, source: Offers.facts(r, expected: exp)).ok, t)
            }
        }
        XCTAssertTrue(Offers.template(row(), expected: "", name: "").contains("sponsor my work visa"))
        XCTAssertFalse(Offers.template(row(sponsor: false), expected: "", name: "").contains("sponsor"))
        XCTAssertTrue(Offers.template(row(), expected: "", name: "").contains("$170,000"))
    }

    func testNoAIOrBrokenAIUsesTemplate() async {
        let none = await Offers.script(row(), expected: "", name: "", ai: nil)
        XCTAssertTrue(none.note?.contains("No AI") == true); XCTAssertTrue(none.body.hasSuffix("[Your name]"))
        let broken = await Offers.script(row(), expected: "", name: "", ai: AI(client: FakeLLM(rules: [{ _ in "nope" }]), store: nil))
        XCTAssertTrue(broken.note?.contains("couldn't") == true)
    }
}
