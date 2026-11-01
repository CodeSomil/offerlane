import XCTest
@testable import OfferlaneCore

/// Serves recorded ATS responses by URL; anything unrecognised is a 404, and "down" hosts fail to connect.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [(String, Int, Data)] = []
    nonisolated(unsafe) static var down: Set<String> = []
    nonisolated(unsafe) static var hits: [String] = []
    static let lock = NSLock()

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [StubURLProtocol.self]; return URLSession(configuration: c)
    }
    static func reset() { lock.lock(); routes = []; down = []; hits = []; lock.unlock() }
    static func route(_ contains: String, _ fixture: String, status: Int = 200) { routes.append((contains, status, Fixture.data("ats/\(fixture).json"))) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!.absoluteString
        Self.lock.lock(); Self.hits.append(url); let routes = Self.routes, down = Self.down; Self.lock.unlock()
        if down.contains(request.url!.host ?? "") { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let match = routes.first { url.contains($0.0) }
        let resp = HTTPURLResponse(url: request.url!, statusCode: match?.1 ?? 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: match?.2 ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AdapterTests: XCTestCase {
    func j(_ name: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Fixture.data("ats/\(name).json")) }

    func testEveryAdapterParsesRecordedResponses() {
        let gh = ATS.greenhouse(j("greenhouse_scaleai"))
        XCTAssertEqual(gh.count, 3); XCTAssertEqual(gh[2].title, "AI Product Manager (Coding/Multimodal)")
        XCTAssertTrue(gh[0].url.hasPrefix("https://")); XCTAssertGreaterThan(gh[0].description.count, 200); XCTAssertFalse(gh[0].description.contains("<"))
        let lv = ATS.lever(j("lever_spotify"))
        XCTAssertEqual(lv.count, 3); XCTAssertTrue(lv[0].applyUrl.hasSuffix("/apply")); XCTAssertNotNil(lv[0].posted); XCTAssertGreaterThan(lv[0].description.count, 200)
        let ab = ATS.ashby(j("ashby_perplexity"))
        XCTAssertEqual(ab.count, 3); XCTAssertFalse(ab[0].url.isEmpty); XCTAssertGreaterThan(ab[0].description.count, 100)
        let wk = ATS.workable(j("workable_huggingface"))
        XCTAssertEqual(wk.count, 3); XCTAssertTrue(wk[0].location.contains("Remote"), wk[0].location)
        let sr = ATS.smartrecruiters(j("smartrecruiters_bosch"), slug: "BoschGroup")
        XCTAssertEqual(sr.count, 3); XCTAssertNotNil(sr[0].detail); XCTAssertTrue(sr[0].url.contains("jobs.smartrecruiters.com/BoschGroup/"))
        XCTAssertGreaterThan(ATS.detailText(j("smartrecruiters_bosch_detail")).count, 100)
    }

    func testWorkday() throws {
        let site = "https://nvidia.wd5.myworkdayjobs.com/en-US/NVIDIAExternalCareerSite"
        let api = try XCTUnwrap(ATS.workdayAPI(site))
        XCTAssertEqual(api.absoluteString, "https://nvidia.wd5.myworkdayjobs.com/wday/cxs/nvidia/NVIDIAExternalCareerSite")
        let now = Dates.day("2026-10-31")!
        let wd = ATS.workday(j("workday_nvidia"), siteURL: site, api: api, now: now)
        XCTAssertEqual(wd.count, 3); XCTAssertEqual(wd[0].title, "Senior Data Scientist – Finance")
        XCTAssertEqual(wd[0].posted, "2026-10-30", "“Posted Yesterday”")
        XCTAssertTrue(wd[0].url.hasPrefix("https://nvidia.wd5.myworkdayjobs.com/NVIDIAExternalCareerSite/job/"))
        XCTAssertTrue(wd[0].detail!.absoluteString.hasPrefix(api.absoluteString + "/job/"))
        XCTAssertGreaterThan(ATS.detailText(j("workday_nvidia_detail")).count, 200)
    }

    func testMatcherAndCandidates() {
        var s = SearchConfig(); s.titleInclude = ["data scien", "re:\\bml\\b"]; s.titleExclude = ["intern"]; s.excludeCompanies = ["Initech"]
        s.locations = ["london"]; s.remoteOk = true; s.maxAgeDays = 21
        let m = Discovery.Matcher(s), now = Dates.day("2026-10-31")!
        func p(_ t: String, _ l: String, _ d: String? = nil) -> Posting { Posting(title: t, location: l, url: "", applyUrl: "", posted: d, description: "") }
        XCTAssertTrue(m.keep(p("Senior Data Scientist", "London, UK"), company: "Acme", now: now))
        XCTAssertTrue(m.keep(p("ML Engineer", "Remote - EMEA"), company: "Acme", now: now), "regex include + remote")
        XCTAssertFalse(m.keep(p("Data Science Intern", "London"), company: "Acme", now: now))
        XCTAssertFalse(m.keep(p("Data Scientist", "Paris"), company: "Acme", now: now))
        XCTAssertFalse(m.keep(p("Data Scientist", "London"), company: "Initech", now: now))
        XCTAssertFalse(m.keep(p("Data Scientist", "London", "2026-09-01"), company: "Acme", now: now), "too old")
        XCTAssertEqual(Discovery.candidates("Scale AI", slug: nil), ["scaleai", "scale-ai", "scale"])
        XCTAssertEqual(Discovery.candidates("Cursor (Anysphere)", slug: "anysphere"), ["anysphere", "cursoranysphere", "cursor-anysphere", "cursor"])
    }
}

final class RankingTests: XCTestCase {
    /// Same inputs as the prototype's rank.local_score / rank.condense; expected values printed by the Python code.
    func testLocalScoreAndCondenseMatchPrototype() throws {
        let expected = try JSONDecoder().decode([String: JSONValue].self, from: Fixture.data("rank_expected.json"))
        let postings = ATS.greenhouse(try JSONDecoder().decode(JSONValue.self, from: Fixture.data("ats/greenhouse_scaleai.json")))
        var r = ResumeContent(); r.topSkills = ["python", "sql", "llm", "machine learning"]
        var s = SearchConfig(); s.targetTitles = ["Data Scientist", "AI Product Manager"]; s.penaltyKeywords = ["computer vision"]; s.locations = ["san francisco"]
        var p = Profile(); p.work.yearsExperience = "5"; p.authorization.authorizedCountries = ["India"]; p.authorization.needsSponsorship = true
        let ctx = Ranking.Context(resume: r, profile: p, search: s), visa = Visa(profile: p, sponsorsDir: URL(fileURLWithPath: "/nonexistent"))
        for post in postings {
            let e = try XCTUnwrap(expected[post.title])
            var j = Job(company: "Scale AI", title: post.title, location: post.location); j.description = post.description; j.posted = post.posted
            XCTAssertEqual(j.posted, e["posted"]?.string)
            XCTAssertEqual(Ranking.localScore(&j, ctx: ctx, visa: visa, now: Dates.day("2026-10-31")!), e["score"]?.double, post.title)
            XCTAssertEqual(j.minYears, e["min_years"]?.double.map { Int($0) }); XCTAssertEqual(j.visa, e["visa"]?.string)
            XCTAssertEqual(Ranking.condense(post.description), e["condense"]?.string, post.title)
        }
    }
}

final class FindJobsTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    func setUpStore() throws -> Store {
        let store = try Store()
        var r = ResumeContent(); r.headline = "Data Scientist"; r.topSkills = ["python", "machine learning"]; r.yearsExperience = "5"
        try store.saveResume(ResumeVersion(name: "main", label: "Main", content: r, sourceText: "", sourceFile: "cv.txt"))
        var s = SearchConfig()
        s.targetTitles = ["Data Scientist"]; s.titleInclude = ["data scien", "product manager", "machine learning", "mes) engineer"]
        s.companies = [.init(name: "Scale AI"), .init(name: "NVIDIA", workday: "https://nvidia.wd5.myworkdayjobs.com/NVIDIAExternalCareerSite"),
                       .init(name: "Hugging Face", slug: "huggingface", ats: "workable"), .init(name: "Nowhere Inc"), .init(name: "Bosch", slug: "BoschGroup", ats: "smartrecruiters")]
        s.maxAgeDays = 3650
        try store.set(.search, s)
        var p = Profile(); p.work.yearsExperience = "5"; try store.set(.profile, p)
        return store
    }

    func testFindJobsEndToEndWithStubbedSites() async throws {
        StubURLProtocol.route("boards-api.greenhouse.io/v1/boards/scaleai/", "greenhouse_scaleai")
        StubURLProtocol.route("/wday/cxs/nvidia/NVIDIAExternalCareerSite/jobs", "workday_nvidia")
        StubURLProtocol.route("/wday/cxs/nvidia/NVIDIAExternalCareerSite/job/", "workday_nvidia_detail")
        StubURLProtocol.route("smartrecruiters.com/v1/companies/BoschGroup/postings?", "smartrecruiters_bosch")
        StubURLProtocol.route("smartrecruiters.com/v1/companies/BoschGroup/postings/", "smartrecruiters_bosch_detail")
        StubURLProtocol.down = ["apply.workable.com"]
        let store = try setUpStore(), http = HTTP(session: StubURLProtocol.session(), minInterval: 0)
        let ai = AI(client: FakeLLM.prototype, store: store)
        let log = LockedLog()
        let summary = try await FindJobs(store: store, ai: ai, http: http).run { log.add($0.message) }

        XCTAssertEqual(summary.discovery.checked, 5)
        XCTAssertEqual(Set(summary.discovery.unreachable), ["Hugging Face"], "a site that's down is reported, not fatal")
        XCTAssertTrue(summary.discovery.noBoard.contains("Nowhere Inc"))
        let found = try store.jobs([.found])
        XCTAssertEqual(Set(found.map(\.company)), ["Scale AI", "NVIDIA", "Bosch"])
        XCTAssertGreaterThan(try XCTUnwrap(found.first { $0.company == "Bosch" }).description.count, 100, "SmartRecruiters description fetched")
        XCTAssertTrue(found.contains { $0.title == "AI Product Manager (Coding/Multimodal)" })
        XCTAssertFalse(found.contains { $0.title == "Account Based Marketing Lead" }, "title filter")
        XCTAssertGreaterThan(try XCTUnwrap(found.first { $0.company == "NVIDIA" }).description.count, 200, "Workday description fetched for matches")
        XCTAssertGreaterThan(summary.ranking.scored, 0); XCTAssertEqual(summary.aiCalls, 1, "one batched scoring call per run")
        XCTAssertTrue(found.filter { $0.llmScore != nil }.allSatisfy { !$0.llmReason.isEmpty && $0.variant == "main" })
        XCTAssertTrue(log.lines.contains { $0.hasPrefix("Checking 5 career sites") })
        XCTAssertTrue(log.lines.contains { $0.hasPrefix("AI is scoring") })
        let cache = try XCTUnwrap(store.get(.atsCache, as: [String: ATSHit].self))
        XCTAssertEqual(cache["Scale AI"]?.ats, "greenhouse"); XCTAssertEqual(cache["Scale AI"]?.slug, "scaleai")
        XCTAssertNil(cache["Nowhere Inc"]?.ats)

        // Decline one; the next run must not bring it back. The cached slug skips probing.
        let declined = try XCTUnwrap(found.first)
        try store.transition(declined.id, to: .declined, by: "you")
        StubURLProtocol.hits = []
        let again = try await FindJobs(store: store, ai: ai, http: http).run { _ in }
        XCTAssertEqual(again.discovery.new, 0)
        XCTAssertEqual(try store.job(declined.id)?.status, .declined, "declined role never comes back")
        XCTAssertFalse(StubURLProtocol.hits.contains { $0.contains("api.lever.co/v0/postings/scaleai") }, "resolved slug cached")
        XCTAssertEqual(again.aiCalls, 0, "nothing new to score")
    }

    func testCancellation() async throws {
        StubURLProtocol.route("greenhouse", "greenhouse_scaleai")
        let store = try setUpStore(), http = HTTP(session: StubURLProtocol.session(), minInterval: 0.5)
        let task = Task { try await FindJobs(store: store, ai: AI(client: FakeLLM.prototype, store: store), http: http).run { _ in } }
        try await Task.sleep(nanoseconds: 200_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
    }
}

final class LockedLog: @unchecked Sendable {
    private var _lines: [String] = []; private let lock = NSLock()
    func add(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
}

final class HardeningTests: XCTestCase {
    func testOfflineIsReportedPlainly() async throws {
        StubURLProtocol.reset(); StubURLProtocol.down = ["boards-api.greenhouse.io"]
        let store = try Store()
        var s = SearchConfig(); s.titleInclude = ["data"]; s.companies = [.init(name: "A", slug: "a", ats: "greenhouse"), .init(name: "B", slug: "b", ats: "greenhouse")]
        try store.set(.search, s)
        let r = try await FindJobs(store: store, ai: AI(client: FakeLLM.prototype, store: store), http: HTTP(session: StubURLProtocol.session(), minInterval: 0)).run { _ in }
        XCTAssertTrue(r.errors.contains { $0.contains("offline") }); XCTAssertEqual(r.aiCalls, 0)
    }

    func testExportAndDeleteAll() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID())")
        setenv("OFFERLANE_HOME", home.path, 1); defer { unsetenv("OFFERLANE_HOME"); try? FileManager.default.removeItem(at: home) }
        try Paths.ensure()
        let store = try Store(), kc = Keychain(service: "com.somilmanke.Offerlane.tests.export")
        var p = Profile(); p.personal.firstName = "Exporty"; try store.set(.profile, p)
        try store.saveResume(ResumeVersion(name: "main", label: "Main", content: ResumeContent(), sourceText: "src", sourceFile: "x.tex", templateTex: "\\documentclass{article}"))
        try store.upsert(Job(company: "A", title: "B"))
        let app = Paths.applications.appendingPathComponent("2026-11-01_A_B"); try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("%PDF".utf8).write(to: app.appendingPathComponent("r.pdf"))
        try kc.set("secret", account: "x")
        let out = try DataTools.export(store: store, to: home)
        for f in ["profile.json", "search.json", "jobs.json", "resumes/main/resume.json", "resumes/main/template.tex", "Applications/2026-11-01_A_B/r.pdf", "README.txt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent(f).path), f)
        }
        XCTAssertFalse(try String(contentsOf: out.appendingPathComponent("jobs.json"), encoding: .utf8).contains("secret"))
        try DataTools.deleteAll(store: store, keychain: kc)
        XCTAssertTrue(try store.jobs().isEmpty); XCTAssertNil(try store.resume()); XCTAssertEqual(try store.profile().personal.firstName, "")
        XCTAssertNil(kc.get(account: "x")); XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
    }
}
