import XCTest
import Network
@testable import OfferlaneCore

final class VisaTests: XCTestCase {
    func profile(_ countries: [String], sponsor: Bool) -> Profile {
        var p = Profile(); p.authorization.authorizedCountries = countries; p.authorization.needsSponsorship = sponsor; return p
    }

    /// Expected values printed by the prototype's visa.tag / authorized_for for the same inputs.
    func testTagsMatchPrototype() {
        let v = Visa(profile: profile(["UK"], sponsor: true), sponsorsDir: URL(fileURLWithPath: "/nonexistent"))
        let cases: [(String, String, String)] = [
            ("London, UK", "", "ok"), ("Remote", "", "remote"), ("Berlin, Germany", "We cannot sponsor visas.", "no-sponsorship"),
            ("Berlin, Germany", "Visa sponsorship is available.", "sponsors"), ("New York, NY", "", "h1b-lottery"),
            ("Dublin, Ireland", "", "likely"), ("Tokyo, Japan", "", "unknown"), ("Remote - US", "", "h1b-lottery"),
        ]
        for (loc, jd, want) in cases { XCTAssertEqual(v.tag(company: "Acme", location: loc, description: jd), want, loc) }
        XCTAssertTrue(v.authorizedFor("London, UK")); XCTAssertFalse(v.authorizedFor("Remote"))
        XCTAssertTrue(v.authorizedFor("Remote", label: "Are you authorized to work in the United Kingdom?"))
        XCTAssertEqual(Visa.nname("Stripe Payments UK Ltd"), "stripe payments"); XCTAssertEqual(Visa.nname("The Hut Group Limited"), "hut")
    }

    func testAliasesAndRegister() throws {
        XCTAssertEqual(Visa.canon(" U.S. "), "united states"); XCTAssertEqual(Visa.canon("Holland"), "netherlands"); XCTAssertEqual(Visa.canon("India"), "india")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "adyen\nbooking com\nstripe payments europe".write(to: dir.appendingPathComponent("nl.txt"), atomically: true, encoding: .utf8)
        let v = Visa(profile: profile(["India"], sponsor: true), sponsorsDir: dir)
        XCTAssertEqual(v.tag(company: "Adyen N.V.", location: "Amsterdam, Netherlands", description: ""), "sponsor-register")
        XCTAssertEqual(v.tag(company: "Stripe", location: "Amsterdam", description: ""), "sponsor-register", "prefix match 'stripe payments…'")
        XCTAssertEqual(v.tag(company: "Unknown Co", location: "Amsterdam", description: ""), "likely")
        XCTAssertEqual(Visa(profile: profile(["India"], sponsor: false)).tag(company: "X", location: "Tokyo", description: ""), "ok")
    }
}

final class CareersTests: XCTestCase {
    func testDetectsEveryATS() {
        func d(_ u: String) -> String { let c = Careers.detect(u); return "\(c?.ats ?? "-")|\(c?.slug ?? c?.workday ?? "-")" }
        XCTAssertEqual(d("https://boards.greenhouse.io/scaleai/jobs/123"), "greenhouse|scaleai")
        XCTAssertEqual(d("https://job-boards.greenhouse.io/embed/job_board?for=stripe"), "greenhouse|stripe")
        XCTAssertEqual(d("jobs.lever.co/spotify"), "lever|spotify")
        XCTAssertEqual(d("https://jobs.ashbyhq.com/perplexity/abc"), "ashby|perplexity")
        XCTAssertEqual(d("https://apply.workable.com/huggingface/"), "workable|huggingface")
        XCTAssertEqual(d("https://jobs.smartrecruiters.com/Visa/744000"), "smartrecruiters|visa")
        XCTAssertEqual(d("https://nvidia.wd5.myworkdayjobs.com/en-US/NVIDIAExternalCareerSite/job/US-CA/ML_JR1"),
                       "workday|https://nvidia.wd5.myworkdayjobs.com/NVIDIAExternalCareerSite")
        XCTAssertNil(Careers.detect("https://www.example.com/careers"))
        XCTAssertEqual(Careers.detect("jobs.lever.co/spotify", name: "Spotify")?.name, "Spotify")
    }

    func testWorkdayTenantsBundled() {
        XCTAssertEqual(Careers.workdayTenants.count, 16)
        XCTAssertEqual(Careers.attachWorkday([.init(name: "NVIDIA")]).first?.workday, "https://nvidia.wd5.myworkdayjobs.com/NVIDIAExternalCareerSite")
    }
}

final class SearchSetupTests: XCTestCase {
    func testDraftMergesTargetsAndAttachesWorkday() async throws {
        var r = ResumeContent(); r.headline = "Data Scientist"; r.suggestedTitles = ["Data Scientist", "ML Engineer"]
        var s = SearchConfig(); s.companies = [.init(name: "Nvidia")]
        let out = try await SearchSetup(ai: AI(client: FakeLLM.prototype, store: nil)).draft(s, resume: r, versions: [], profile: Profile())
        XCTAssertEqual(out.targetTitles, ["Data Scientist", "ML Engineer"])
        XCTAssertTrue(out.titleInclude.contains("data scientist") && out.titleInclude.contains("applied ai"))
        XCTAssertEqual(out.companies.map(\.name), ["Nvidia", "Scale AI", "Spotify", "Perplexity"], "AI-drafted search saved; existing kept first")
        XCTAssertNotNil(out.companies[0].workday)
    }
}

/// A scripted IMAP server on localhost (plain TCP) to test the client's protocol handling.
final class IMAPTests: XCTestCase {
    final class FakeServer: @unchecked Sendable {
        let listener: NWListener
        var port: UInt16 { listener.port!.rawValue }
        init(password: String) throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { c in
                c.start(queue: .global())
                func send(_ s: String) { c.send(content: Data(s.utf8), completion: .idempotent) }
                send("* OK IMAP ready\r\n")
                var buf = ""
                func loop() {
                    c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { d, _, done, _ in
                        buf += String(decoding: d ?? Data(), as: UTF8.self)
                        while let r = buf.range(of: "\r\n") {
                            let line = String(buf[..<r.lowerBound]); buf.removeSubrange(..<r.upperBound)
                            let tag = String(line.prefix { $0 != " " }), cmd = line.dropFirst(tag.count + 1)
                            if cmd.hasPrefix("LOGIN") { send(cmd.contains("\"\(password)\"") ? "\(tag) OK logged in\r\n" : "\(tag) NO [AUTHENTICATIONFAILED] Invalid credentials\r\n") }
                            else if cmd.hasPrefix("EXAMINE") { send("* 3 EXISTS\r\n* 0 RECENT\r\n\(tag) OK [READ-ONLY] done\r\n") }
                            else if cmd.hasPrefix("SEARCH") { send("* SEARCH 2 3\r\n\(tag) OK done\r\n") }
                            else if cmd.hasPrefix("FETCH") {
                                let h = "Subject: Interview invitation\r\nFrom: Acme <jobs@acme.com>\r\n\r\n", b = "We'd like to schedule an interview."
                                send("* 3 FETCH (BODY[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)] {\(h.utf8.count)}\r\n\(h) BODY[TEXT]<0> {\(b.utf8.count)}\r\n\(b))\r\n\(tag) OK done\r\n")
                            }
                            else if cmd.hasPrefix("LOGOUT") { send("* BYE\r\n\(tag) OK bye\r\n") }
                            else { send("\(tag) BAD unknown\r\n") }
                        }
                        if !done { loop() }
                    }
                }
                loop()
            }
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.start(queue: .global()); _ = ready.wait(timeout: .now() + 5)
        }
    }

    func testLoginSelectSearchFetch() async throws {
        let srv = try FakeServer(password: "app-pass"); defer { srv.listener.cancel() }
        let c = IMAPClient(host: "127.0.0.1", port: srv.port, tls: false)
        try await c.connect()
        try await c.login(user: "me@x.com", password: "app-pass")
        let n = try await c.select(); XCTAssertEqual(n, 3)
        let ids = try await c.search("SINCE 01-Oct-2026"); XCTAssertEqual(ids, [2, 3])
        let m = try await c.fetchHeaderAndBody(3)
        XCTAssertTrue(String(decoding: m.header, as: UTF8.self).contains("Interview invitation"))
        XCTAssertEqual(String(decoding: m.body, as: UTF8.self), "We'd like to schedule an interview.")
        await c.logout()
    }

    func testWrongPasswordGivesActionableError() async throws {
        let srv = try FakeServer(password: "right"); defer { srv.listener.cancel() }
        let c = IMAPClient(host: "127.0.0.1", port: srv.port, tls: false)
        try await c.connect()
        do { try await c.login(user: "me", password: "wrong"); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("app password"), error.localizedDescription)
        }
    }
}

final class ImporterTests: XCTestCase {
    /// Runs the importer on a real previous-version (v2) folder (read-only) into a temporary store.
    func testImportsLegacyData() throws {
        try XCTSkipUnless(Fixture.hasLegacy, "set OFFERLANE_LEGACY_DIR to a previous-version (v2) data folder")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        let store = try Store()
        let rep = try LegacyImporter(store: store, destination: dest).run(from: Fixture.legacy)
        // Expected values come from the folder's own JSON, so the test works on any v2 data folder.
        func json(_ n: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Fixture.legacy.appendingPathComponent(n))) }
        let jobs = try json("jobs.json")["jobs"]!.object!, search = try json("search.json"), profile = try json("profile.json")
        func count(_ st: String) -> Int { jobs.values.filter { $0["status"]?.string == st }.count }
        XCTAssertEqual(try store.profile().personal.firstName, profile["personal"]?["first_name"]?.string)
        XCTAssertEqual(rep.companies, search["companies"]?.array?.count)
        XCTAssertFalse(rep.resumes.isEmpty)
        XCTAssertEqual(rep.jobs, jobs.count); XCTAssertEqual(rep.skippedJobs, 0)
        XCTAssertEqual(try store.jobs([.declined]).count, count("dismissed"), "dismissed → declined")
        XCTAssertEqual(try store.jobs([.found]).count, count("found"))
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: Fixture.legacy.appendingPathComponent("applications").path))?.filter { !$0.hasPrefix(".") } ?? []
        XCTAssertEqual(rep.applications, apps.count)

        // Every open role's visa tag, recomputed by the Swift port, matches the prototype's visa.tag on the same roles.
        // The expected tags (role id → tag, generated from the Python code) are personal, so they live in the git-ignored
        // Fixtures/private/legacy_visa_tags.json; without it this part is skipped.
        guard let tags = Fixture.privateData("legacy_visa_tags.json") else { return }
        let expected = try JSONDecoder().decode([String: String].self, from: tags)
        let visa = Visa(profile: try store.profile(), sponsorsDir: dest.appendingPathComponent("sponsors"))
        var mismatches: [String] = []
        for j in try store.jobs([.found]) {
            let t = visa.tag(company: j.company, location: j.location, description: j.description)
            if t != expected[j.id] { mismatches.append("\(j.company) | \(j.location) | python=\(expected[j.id] ?? "-") swift=\(t)") }
        }
        XCTAssertEqual(expected.count, try store.jobs([.found]).count)
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count)/\(expected.count) differ:\n" + mismatches.prefix(10).joined(separator: "\n"))

        // Importing twice changes nothing.
        let again = try LegacyImporter(store: store, destination: dest).run(from: Fixture.legacy)
        XCTAssertEqual(again.events, 0); XCTAssertEqual(try store.jobs().count, jobs.count)
    }
}

final class TrackingTests: XCTestCase {
    func testClassifyAndMime() {
        XCTAssertEqual(Tracking.classify("Unfortunately we will not be moving forward"), .rejected)
        XCTAssertEqual(Tracking.classify("Invitation: interview with the team"), .interview)
        XCTAssertEqual(Tracking.classify("Your HackerRank assessment"), .assessment)
        XCTAssertEqual(Tracking.classify("Thank you for applying to Acme"), .acknowledged)
        XCTAssertEqual(Tracking.classify("We are pleased to extend an offer"), .offer)
        XCTAssertNil(Tracking.classify("Weekly newsletter"))
        XCTAssertEqual(Mime.decodeWords("=?UTF-8?B?SW50ZXJ2aWV3IOKAkyBBY21l?="), "Interview – Acme")
        XCTAssertEqual(Mime.decodeWords("=?utf-8?Q?Caf=C3=A9_team?= hello"), "Café team hello")
        XCTAssertEqual(Mime.quotedPrintable("https://x.com/verify?t=3Dabc=\r\ndef"), "https://x.com/verify?t=abcdef")
        let m = MailMessage.parse(seq: 3, header: Data("Subject: =?UTF-8?B?SGVsbG8=?=\r\nFrom: Acme\r\n <jobs@acme.com>\r\nMessage-ID: <1@acme>\r\n\r\n".utf8), body: Data("<p>Hi there</p>".utf8))
        XCTAssertEqual(m.subject, "Hello"); XCTAssertEqual(m.from, "Acme <jobs@acme.com>"); XCTAssertEqual(m.id, "<1@acme>"); XCTAssertEqual(m.snippet, "Hi there")
    }

    func testInboxMovesToInterviewThenRejectedHiddenButCounted() async throws {
        let store = try Store()
        var j = Job(company: "Acme Robotics", title: "Data Scientist"); try store.upsert(j)
        for s in [JobStatus.tailoring, .review, .ready, .applying, .prefilled] { j = try store.transition(j.id, to: s, by: "test") }
        let box = LockedLog()
        let mails = { (list: [MailMessage]) in { @Sendable () async throws -> [MailMessage] in box.add("fetch"); return list } }
        let t1 = Tracking(store: store, ai: AI(client: FakeLLM.prototype, store: store), fetch: mails([
            MailMessage(id: "1", from: "Acme Robotics <jobs@acmerobotics.com>", subject: "Interview invitation", snippet: "We'd like to schedule an interview.", raw: ""),
            MailMessage(id: "2", from: "Newsletter <news@x.com>", subject: "Interview tips", snippet: "", raw: ""),
            MailMessage(id: "3", from: "Acme Robotics", subject: "Quick question", snippet: "Could you send your portfolio?", raw: ""),
        ]))
        let r1 = try await t1.run()
        XCTAssertEqual(try store.job(j.id)?.status, .interview, "inbox reply moves it to Interview")
        XCTAssertEqual(r1.updates, 1); XCTAssertEqual(r1.askedAI, 1, "only the ambiguous company email goes to the AI")
        let r1b = try await t1.run(); XCTAssertEqual(r1b.updates, 0, "emails are processed once")

        let ack = Tracking(store: store, ai: nil, fetch: mails([MailMessage(id: "4", from: "Acme Robotics", subject: "Thank you for applying", snippet: "", raw: "")]))
        _ = try await ack.run(); XCTAssertEqual(try store.job(j.id)?.status, .interview, "statuses never move backwards")

        let rej = Tracking(store: store, ai: nil, fetch: mails([MailMessage(id: "5", from: "Acme Robotics", subject: "Your application", snippet: "Unfortunately we decided to proceed with other candidates.", raw: "")]))
        _ = try await rej.run()
        XCTAssertEqual(try store.job(j.id)?.status, .rejected)
        XCTAssertFalse(try store.jobs(JobStatus.tracked).contains { $0.id == j.id }, "rejection removes it from the dashboard")
        XCTAssertTrue(try store.jobs([.rejected]).contains { $0.id == j.id }, "…but it's still counted")
    }

    func testVerificationLink() {
        let mails = [MailMessage(id: "1", from: "Workday <noreply@myworkday.com>", subject: "Please verify your account", snippet: "",
                                 raw: "Click https://nvidia.wd5.myworkdayjobs.com/verify?token=3Dabc123 to activate. Code: 482913")]
        let v = Tracking.verification(in: mails, hint: "workday")
        XCTAssertEqual(v?.link, "https://nvidia.wd5.myworkdayjobs.com/verify?token=abc123"); XCTAssertEqual(v?.code, "482913")
        XCTAssertNil(Tracking.verification(in: mails, hint: "stripe"))
    }

    func testIMAPFetchEndToEnd() async throws {
        let srv = try IMAPTests.FakeServer(password: "pw"); defer { srv.listener.cancel() }
        let mails = try await Tracking.imapFetch(host: "127.0.0.1", port: srv.port, user: "me", password: "pw", tls: false)
        XCTAssertEqual(mails.count, 2); XCTAssertEqual(mails.last?.subject, "Interview invitation"); XCTAssertTrue(mails.last?.snippet.contains("schedule an interview") ?? false)
    }
}
