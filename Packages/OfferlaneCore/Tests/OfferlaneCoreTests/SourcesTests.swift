import XCTest
@testable import OfferlaneCore

/// A job API stand-in: returns `jobs`, or a rate limit / outage, and counts its calls.
final class FakeSource: JobSource, @unchecked Sendable {
    let id: String, name: String, terms = "test", minInterval: TimeInterval, defaultOn = true
    var result: SourceResult; private(set) var calls = 0
    init(_ id: String, _ result: SourceResult, minInterval: TimeInterval = 0) { self.id = id; name = id.capitalized; self.result = result; self.minInterval = minInterval }
    func fetch(_ queries: [SearchQuery], http: HTTP) async -> SourceResult { calls += 1; return result }
}

final class SourcesTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    func job(_ company: String, _ title: String, _ loc: String = "Remote", _ src: String = "api:fake") -> Job {
        var j = Job(company: company, title: title, location: loc, url: "https://example.com/\(company)/\(title)")
        j.description = "You will build machine learning models in python. Experience with sql required."; j.posted = Dates.today(); j.source = src
        return j
    }

    func store(watch: [SearchConfig.Company] = []) throws -> Store {
        let store = try Store()
        var r = ResumeContent(); r.headline = "Data Scientist"; r.topSkills = ["python", "machine learning"]; r.yearsExperience = "5"
        try store.saveResume(ResumeVersion(name: "main", label: "Main", content: r, sourceText: "", sourceFile: "cv.txt"))
        var s = SearchConfig(); s.targetTitles = ["Data Scientist"]; s.titleInclude = ["data scien", "machine learning"]; s.companies = watch
        try store.set(.search, s); var p = Profile(); p.work.yearsExperience = "5"; try store.set(.profile, p)
        return store
    }

    func testRemotiveParsesAndNamesItsSource() throws {
        let jobs = Remotive.parse(try JSONDecoder().decode(JSONValue.self, from: Fixture.data("ats/remotive.json")))
        XCTAssertEqual(jobs.map(\.title), ["Senior Data Scientist", "Account Executive"], "untitled rows dropped")
        let j = try XCTUnwrap(jobs.first)
        XCTAssertEqual(j.company, "Faraway Labs"); XCTAssertEqual(j.location, "Remote (Europe)"); XCTAssertEqual(j.posted, "2026-11-08")
        XCTAssertEqual(j.source, "api:remotive"); XCTAssertTrue(j.url.hasPrefix("https://remotive.com/"), "terms: link back to Remotive")
        XCTAssertTrue(j.description.hasPrefix("You will build machine learning models in python."))
        XCTAssertEqual(j.applyUrl, "https://boards.greenhouse.io/farawaylabs/jobs/123", "employer's own posting kept for apply + registry")
    }

    func testOverlappingSourcesDedupeAndUnlistedCompaniesAppear() async throws {
        let st = try store(watch: [.init(name: "Watched Co", slug: "watched", ats: "greenhouse")])
        let a = FakeSource("a", .jobs([job("Outside Co", "Data Scientist"), job("Other Co", "ML Engineer, Machine Learning"), job("SellCo", "Account Executive")]))
        let b = FakeSource("b", .jobs([job("Outside Co", "Data Scientist"), job("Third Co", "Senior Data Scientist")]))
        let r = try await Discovery(store: st, http: HTTP(session: StubURLProtocol.session(), minInterval: 0), sources: [a, b]).run { _ in }
        XCTAssertEqual(r.matching, 3, "duplicate across sources counted once; off-target title filtered")
        XCTAssertEqual(r.new, 3); XCTAssertEqual(r.sourcesChecked, ["A", "B"])
        XCTAssertEqual(Set(try st.jobs([.found]).map(\.company)), ["Outside Co", "Other Co", "Third Co"], "companies not on the watchlist appear")
    }

    func testDeclinedNeverResurfacesFromASource() async throws {
        let st = try store(), http = HTTP(session: StubURLProtocol.session(), minInterval: 0)
        let a = FakeSource("a", .jobs([job("Outside Co", "Data Scientist")]))
        _ = try await Discovery(store: st, http: http, sources: [a]).run { _ in }
        let id = try XCTUnwrap(st.jobs([.found]).first).id
        try st.transition(id, to: .declined, by: "you")
        let again = try await Discovery(store: st, http: http, sources: [a]).run { _ in }
        XCTAssertEqual(again.new, 0); XCTAssertEqual(try st.job(id)?.status, .declined)
    }

    func testRateLimitedSourceIsSkippedAndBacksOffWhileOthersContinue() async throws {
        let st = try store(), http = HTTP(session: StubURLProtocol.session(), minInterval: 0)
        let slow = FakeSource("slow", .rateLimited, minInterval: 3600), ok = FakeSource("ok", .jobs([job("Outside Co", "Data Scientist")]))
        let r = try await Discovery(store: st, http: http, sources: [slow, ok]).run { _ in }
        XCTAssertEqual(r.new, 1, "the other source still delivers")
        XCTAssertTrue(r.sourceIssues.contains { $0.hasPrefix("Slow asked us to slow down") })
        _ = try await Discovery(store: st, http: http, sources: [slow, ok]).run { _ in }
        XCTAssertEqual(slow.calls, 1, "backs off for its interval after a 429")
        XCTAssertEqual(ok.calls, 2)
    }

    func testSourceSwitchTurnsASourceOff() async throws {
        let st = try store(); var s = try st.search(); s.sources = ["a": false]; try st.set(.search, s)
        let a = FakeSource("a", .jobs([job("Outside Co", "Data Scientist")]))
        let r = try await Discovery(store: st, http: HTTP(session: StubURLProtocol.session(), minInterval: 0), sources: [a]).run { _ in }
        XCTAssertEqual(a.calls, 0); XCTAssertEqual(r.new, 0)
    }

    func testAICallsStayConstantOn500Jobs() async throws {
        let st = try store()
        let many = (0..<500).map { job("Company \($0)", $0 % 2 == 0 ? "Data Scientist" : "Machine Learning Engineer") }
        let ai = AI(client: FakeLLM.prototype, store: st)
        var d = Discovery(store: st, http: HTTP(session: StubURLProtocol.session(), minInterval: 0), sources: [FakeSource("bulk", .jobs(many))])
        d.concurrency = 1
        _ = try await d.run { _ in }
        XCTAssertEqual(try st.jobs([.found]).count, 500)
        ai.resetRunCounters()
        let r = try await Ranking(store: st, ai: ai).run { _ in }
        XCTAssertEqual(ai.callsThisRun, 1, "one batched scoring call, however many jobs were found")
        XCTAssertEqual(r.scored, try st.search().poolSize)
    }

    func testBoardRegistryLearnsBoardsAndSearchesThemNextRun() async throws {
        StubURLProtocol.route("boards-api.greenhouse.io/v1/boards/farawaylabs/", "greenhouse_scaleai")
        let st = try store(), http = HTTP(session: StubURLProtocol.session(), minInterval: 0)
        var s = try st.search(); s.titleInclude.append("product manager"); s.maxAgeDays = 100_000; try st.set(.search, s)  // matches the fixture board; the fixture's dates age, so freshness is off here
        var ad = job("Faraway Labs", "Data Scientist"); ad.applyUrl = "https://boards.greenhouse.io/farawaylabs/jobs/123"
        let src = FakeSource("a", .jobs([ad]))
        _ = try await Discovery(store: st, http: http, sources: [src]).run { _ in }
        let reg = try XCTUnwrap(st.get(.boardRegistry, as: [SearchConfig.Company].self))
        XCTAssertEqual(reg, [.init(name: "Faraway Labs", slug: "farawaylabs", ats: "greenhouse")])
        XCTAssertFalse(StubURLProtocol.hits.contains { $0.contains("boards/farawaylabs") }, "learned this run, searched next run")

        let r = try await Discovery(store: st, http: http, sources: [src]).run { _ in }
        XCTAssertEqual(r.checked, 1, "the learned board is searched although it's not on the watchlist")
        XCTAssertTrue(try st.jobs([.found]).contains { $0.company == "Faraway Labs" && $0.source == "ats:greenhouse" })

        // A learned board that disappears is dropped quietly (not reported as unreachable) while sources still answer.
        StubURLProtocol.reset()
        let r3 = try await Discovery(store: st, http: http, sources: [FakeSource("b", .jobs([]))]).run { _ in }
        XCTAssertTrue(r3.unreachable.isEmpty)
        XCTAssertEqual(try st.get(.boardRegistry, as: [SearchConfig.Company].self), [])
    }

    func testTiersFromScoringWithAspirationFallback() async throws {
        let st = try store(); var s = try st.search(); s.aspirations = ["Head of Data"]; s.titleInclude.append("head of data"); try st.set(.search, s)
        for t in ["Data Scientist", "Senior Data Scientist", "Head of Data Science"] { try st.upsert(job("Co \(t)", t)) }
        _ = try await Ranking(store: st, ai: AI(client: FakeLLM.prototype, store: st)).run { _ in }
        let tiers = try st.jobs([.found]).filter { $0.llmScore != nil }.map(\.tier)
        XCTAssertEqual(tiers.sorted(), ["fit", "fit", "stretch"], "the AI's t is stored")

        // An answer without t: the aspiration title becomes stretch, the rest fit.
        let st2 = try store(); try st2.set(.search, s)
        for t in ["Data Scientist", "Head of Data Science"] { try st2.upsert(job("Co \(t)", t)) }
        let noTier = FakeLLM(rules: [{ r in
            guard r.prompt.hasPrefix("Score each job") else { return nil }
            return "[" + Re.findAll("^(\\d+) \\|", r.prompt, [.anchorsMatchLines]).map { "{\"i\":\($0),\"s\":80,\"r\":\"ok\"}" }.joined(separator: ",") + "]"
        }])
        _ = try await Ranking(store: st2, ai: AI(client: noTier, store: st2)).run { _ in }
        let byTitle = Dictionary(uniqueKeysWithValues: try st2.jobs([.found]).map { ($0.title, $0.tier) })
        XCTAssertEqual(byTitle, ["Data Scientist": "fit", "Head of Data Science": "stretch"])
    }
}

final class AdzunaTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }
    let http = HTTP(session: StubURLProtocol.session(), minInterval: 0)
    let keys = Adzuna.Keys(appId: "id123", appKey: "SECRETKEY987")

    func testParsesAndLinksBackToAdzuna() throws {
        let jobs = Adzuna.parse(try JSONDecoder().decode(JSONValue.self, from: Fixture.data("ats/adzuna.json")))
        XCTAssertEqual(jobs.map(\.title), ["Senior Data Scientist", "Account Executive"], "HTML stripped; rows with no company dropped")
        let j = try XCTUnwrap(jobs.first)
        XCTAssertEqual(j.company, "Faraway Labs"); XCTAssertEqual(j.location, "Austin, Texas"); XCTAssertEqual(j.posted, "2026-11-08")
        XCTAssertEqual(j.source, "api:adzuna"); XCTAssertTrue(j.url.hasPrefix("https://www.adzuna.com/details/4711"), "terms: each advert links to Adzuna")
        XCTAssertTrue(j.description.hasPrefix("You will build machine learning models in python."))
    }

    func testOneRequestPerQueryCappedAndKeysOnlyInTheURL() async throws {
        StubURLProtocol.route("api.adzuna.com", "adzuna")
        let qs = (1...9).map { SearchQuery("data scientist \($0)", where: $0 == 1 ? "Austin" : nil) }
        guard case .jobs(let jobs) = await Adzuna(keys: keys, country: "us").fetch(qs, http: http) else { return XCTFail("expected jobs") }
        XCTAssertEqual(StubURLProtocol.hits.count, Adzuna.maxRequests, "free plan: a few requests per run, not one per query")
        let first = try XCTUnwrap(StubURLProtocol.hits.first)
        XCTAssertTrue(first.hasPrefix("https://api.adzuna.com/v1/api/jobs/us/search/1?"))
        XCTAssertTrue(first.contains("app_id=id123") && first.contains("app_key=SECRETKEY987") && first.contains("what=data%20scientist%201") && first.contains("where=Austin"))
        XCTAssertFalse(StubURLProtocol.hits[1].contains("where="), "remote query has no place")
        XCTAssertEqual(Set(jobs.map(\.url)).count, 2, "the same advert from several queries is kept once")
        let dump = jobs.map { "\($0)" }.joined()
        XCTAssertFalse(dump.contains("SECRETKEY987"), "the key never lands in a stored job")
    }

    func testNoKeysMeansNotReadyAndNeverCalled() async {
        XCTAssertFalse(Adzuna(keys: nil, country: "us").ready)
        XCTAssertFalse(Adzuna(keys: keys, country: "xx").ready, "unsupported country")
        var s = SearchConfig(); s.sources["adzuna"] = true
        XCTAssertEqual(JobSources.enabled(s, from: [Adzuna(keys: nil, country: "us")]).count, 0, "switched on but no key: skipped, not 'unreachable'")
        XCTAssertEqual(JobSources.enabled(SearchConfig(), from: [Adzuna(keys: keys, country: "us")]).count, 0, "off by default")
        XCTAssertEqual(JobSources.enabled(s, from: [Adzuna(keys: keys, country: "us")]).count, 1)
    }

    func testAttributionLinksToTheAdvertsCountrySite() throws {
        let c = try JSONDecoder().decode(AdzunaCases.self, from: Fixture.data("core/adzuna_cases.json")) // shared with libs/core
        XCTAssertEqual(Adzuna.attribution.absoluteString, c.fallback)
        for a in c.attribution { XCTAssertEqual(Adzuna.attribution(for: a.url).absoluteString, a.expect, a.url) }
        for r in c.defaultCountry { XCTAssertEqual(Adzuna.defaultCountry(region: r.region), r.expect, r.region ?? "nil") }
        XCTAssertEqual(Adzuna.countries.count, 19, "the bundled table loads")
        XCTAssertEqual(Adzuna.sites.count, Adzuna.countries.count, "one site per supported country")
    }
    struct AdzunaCases: Decodable {
        struct A: Decodable { var url, expect: String }; struct D: Decodable { var region: String?; var expect: String }
        var fallback: String; var attribution: [A]; var defaultCountry: [D]
    }

    func testRateLimitAndBadKey() async {
        StubURLProtocol.route("api.adzuna.com", "adzuna", status: 429)
        let noRetry = HTTP(session: StubURLProtocol.session(), minInterval: 0, retryRateLimit: false)
        guard case .rateLimited = await Adzuna(keys: keys, country: "gb").fetch([SearchQuery("x"), SearchQuery("y")], http: noRetry) else { return XCTFail("429") }
        XCTAssertEqual(StubURLProtocol.hits.count, 1, "a 429 is reported at once, not after 15–60 s of retries")
        let retries = await Adzuna.noCache.retryRateLimit; XCTAssertFalse(retries, "the real Adzuna client doesn't back off")
        StubURLProtocol.reset(); StubURLProtocol.route("api.adzuna.com", "adzuna", status: 401)
        guard case .refused(let why) = await Adzuna(keys: keys, country: "gb").fetch([SearchQuery("x")], http: http) else { return XCTFail("401") }
        XCTAssertTrue(why.contains("didn't accept your key"), "a wrong key isn't reported as a connection problem")
        XCTAssertFalse(why.contains("SECRETKEY987"))
    }

    func testKeysRoundTripThroughTheProfileKeychain() async throws {
        let kc = Keychain(service: "com.somilmanke.Offerlane.test-adzuna-\(UUID().uuidString)"); defer { kc.deleteAll() }
        XCTAssertNil(Adzuna.keys(in: kc))
        try Adzuna.save(Adzuna.Keys(appId: " id123 ", appKey: "SECRETKEY987\n"), in: kc)
        XCTAssertEqual(Adzuna.keys(in: kc), keys, "trimmed")
        XCTAssertThrowsError(try Adzuna.save(Adzuna.Keys(appId: "id:typo", appKey: "other"), in: kc))
        XCTAssertEqual(Adzuna.keys(in: kc), keys, "a bad app ID keeps the saved key")
        try Adzuna.save(Adzuna.Keys(appId: "id123", appKey: "with:colon"), in: kc)
        XCTAssertEqual(Adzuna.keys(in: kc)?.appKey, "with:colon")
        var s = SearchConfig(); s.sources["adzuna"] = true; s.adzunaCountry = "gb"
        XCTAssertEqual(JobSources.enabled(s, from: JobSources.configured(keychain: kc, search: s)).map(\.id), ["remotive", "adzuna"], "a run uses the profile's keys")
        try Adzuna.save(nil, in: kc)
        XCTAssertNil(Adzuna.keys(in: kc))
        XCTAssertEqual(JobSources.enabled(s, from: JobSources.configured(keychain: kc, search: s)).map(\.id), ["remotive"])
        let cache = await Adzuna.noCache.session.configuration.urlCache; XCTAssertNil(cache, "the key-bearing URL is never cached on disk")
    }

    func testSearchConfigKeepsCountryAndOldConfigsDecode() throws {
        var s = SearchConfig(); s.adzunaCountry = "gb"
        XCTAssertEqual(try JSONDecoder().decode(SearchConfig.self, from: JSONEncoder().encode(s)).adzunaCountry, "gb")
        let old = #"{"targetTitles":[],"titleInclude":[],"titleExclude":[],"boostKeywords":[],"penaltyKeywords":[],"excludeCompanies":[],"locations":[],"remoteOk":true,"companies":[],"queries":[],"aspirations":[]}"#
        XCTAssertEqual(try JSONDecoder().decode(SearchConfig.self, from: Data(old.utf8)).adzunaCountry, "")
        XCTAssertEqual(Adzuna.country(""), Adzuna.defaultCountry(region: Locale.current.region?.identifier)); XCTAssertEqual(Adzuna.country("de"), "de")
    }
}
