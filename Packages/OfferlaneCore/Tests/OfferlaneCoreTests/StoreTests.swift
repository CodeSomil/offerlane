import XCTest
@testable import OfferlaneCore

final class StoreTests: XCTestCase {
    func testUpsertDedupesAndDeclinedNeverReturns() throws {
        let s = try Store()
        var j = Job(company: "Stripe", title: "Data Scientist", location: "London, UK", url: "https://x/1"); j.description = "Long JD"
        XCTAssertTrue(try s.upsert(j))
        XCTAssertFalse(try s.upsert(Job(company: "stripe", title: "Data  Scientist!", location: "London", url: "https://x/2")))
        XCTAssertEqual(try s.job(j.id)?.url, "https://x/2")
        try s.transition(j.id, to: .declined, by: "you", detail: "declined")
        let hidden = try XCTUnwrap(s.job(j.id))
        XCTAssertEqual(hidden.status, .declined); XCTAssertEqual(hidden.description, "")
        var again = Job(company: "Stripe", title: "Data Scientist", location: "London", url: "https://x/3"); again.description = "Even longer JD text"
        XCTAssertFalse(try s.upsert(again))
        XCTAssertEqual(try s.job(j.id)?.status, .declined)
        XCTAssertEqual(try s.job(j.id)?.url, "https://x/2", "hidden roles aren't refreshed")
        XCTAssertEqual(try s.events(for: j.id).first?.status, "declined")
    }

    func testIllegalTransitionIsRejectedAndNothingChanges() throws {
        let s = try Store(); let j = Job(company: "A", title: "B"); try s.upsert(j)
        XCTAssertThrowsError(try s.transition(j.id, to: .applied, by: "test"))
        XCTAssertEqual(try s.job(j.id)?.status, .found)
        XCTAssertTrue(try s.events(for: j.id).isEmpty)
    }

    func testJobIDMatchesPrototype() {
        // Values computed by the prototype's core.job_id, so imported roles keep their fingerprints.
        XCTAssertEqual(Text.jobID(company: "Stripe", title: "Data Scientist", location: "London, UK"), "324632528fb2")
        XCTAssertEqual(Text.jobID(company: "Hugging Face", title: "Senior Machine Learning Engineer, Voice Agents - EMEA Remote",
                                  location: "Paris, France"), "042d8c45d181")
    }

    func testProfileDecodesPrototypeJSONWithNumbers() throws {
        let json = """
        {"personal":{"first_name":"Jane","last_name":"Doe","email":"a@b.c"},"work":{"years_experience":4,"willing_to_relocate":true},
         "education":{"graduation_year":2022},"authorization":{"authorized_countries":["India"],"needs_sponsorship":true}}
        """
        let p = try JSONCoding.decoder.decode(Profile.self, from: Data(json.utf8))
        XCTAssertEqual(p.work.yearsExperience, "4"); XCTAssertEqual(p.education.graduationYear, "2022")
        XCTAssertTrue(p.work.willingToRelocate); XCTAssertTrue(p.work.openToRemote, "missing booleans take their default")
        XCTAssertEqual(p.eeo.gender, Profile.EEO.decline); XCTAssertEqual(p.fileStem, "Jane_Doe_Resume")
        let s = try Store(); try s.set(.profile, p); XCTAssertEqual(try s.profile(), p)
    }

    func testResumeDefaultHandling() throws {
        let s = try Store()
        try s.saveResume(ResumeVersion(name: "ic", label: "IC", content: ResumeContent(), sourceText: "", sourceFile: "a.tex"))
        try s.saveResume(ResumeVersion(name: "lead", label: "Lead", content: ResumeContent(), sourceText: "", sourceFile: "b.tex"))
        XCTAssertEqual(try s.resume()?.name, "ic")
        try s.setDefaultResume("lead"); XCTAssertEqual(try s.resume()?.name, "lead"); XCTAssertEqual(try s.resume("ic")?.name, "ic")
        try s.deleteResume("lead"); XCTAssertEqual(try s.resume()?.name, "ic")
        XCTAssertTrue(ResumeVersion.validName("lead-2")); XCTAssertFalse(ResumeVersion.validName("Lead 2"))
        XCTAssertEqual(ResumeVersion.makeName(from: "Manager (Lead)"), "manager-lead")
    }

    func testUsageAndEmailsSeen() throws {
        let s = try Store()
        try s.meter(input: 100, output: 20, cached: 50, usd: 0.01); try s.meter(input: 1, output: 1, cached: 0, usd: 0.02)
        let u = try XCTUnwrap(s.usage().first)
        XCTAssertEqual(u.calls, 2); XCTAssertEqual(u.inputTokens, 101); XCTAssertEqual(u.usd, 0.03, accuracy: 1e-9)
        XCTAssertEqual(try s.markEmailsSeen(["a", "b"]), ["a", "b"]); XCTAssertEqual(try s.markEmailsSeen(["b", "c"]), ["c"])
    }

    func testOnDiskDatabaseMigrates() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try Store(url: url).upsert(Job(company: "A", title: "B"))
        XCTAssertEqual(try Store(url: url).jobs().count, 1)
    }
}

final class SettingsCodingTests: XCTestCase {
    func testRoundTripAndOldDocuments() throws {
        var s = AppSettings(); s.provider = .ollama; s.baseUrl = "http://localhost:11434/v1"; s.email.user = "a@b.c"
        let store = try Store(); try store.set(.settings, s)
        XCTAssertEqual(try store.settings(), s)
        let old = try JSONCoding.decoder.decode(AppSettings.self, from: Data(#"{"provider":"claude_cli","email":{"user":"x"}}"#.utf8))
        XCTAssertEqual(old.provider, .claudeCLI); XCTAssertEqual(old.email.user, "x"); XCTAssertEqual(old.email.host, "imap.gmail.com")
        XCTAssertTrue(old.notify.ntfyTopic.hasPrefix("offerlane-"))
    }
}

final class ProfilePrefillTests: XCTestCase {
    func testPrefillFromResumeAndValidation() {
        var r = ResumeContent(); r.name = "Test Person"; r.email = "test@example.com"; r.location = "London, UK"; r.yearsExperience = "5"
        r.experience = [.init(id: "e1", title: "Senior Data Scientist", company: "Acme")]
        var p = Profile(); p.personal.phone = "+44 1"
        p.prefill(from: r)
        XCTAssertEqual(p.personal.firstName, "Test"); XCTAssertEqual(p.personal.lastName, "Person"); XCTAssertEqual(p.personal.country, "United Kingdom")
        XCTAssertEqual(p.work.currentCompany, "Acme"); XCTAssertEqual(p.authorization.authorizedCountries, ["United Kingdom"])
        XCTAssertEqual(p.personal.phone, "+44 1", "typed values are kept")
        XCTAssertEqual(Set(p.validationErrors.keys), ["phone"])
        p.personal.email = "nope"; XCTAssertNotNil(p.validationErrors["email"])
    }
}
