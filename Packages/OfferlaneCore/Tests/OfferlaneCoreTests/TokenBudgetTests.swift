import XCTest
@testable import OfferlaneCore

/// Records every request so tests can measure what each AI call really sends (system + cached block + prompt).
final class RecordingLLM: LLMClient, @unchecked Sendable {
    struct Call { var kind: String; var input: Int; var maxTokens: Int; var output: Int; var smart: Bool }
    let inner: FakeLLM
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    init(_ inner: FakeLLM = .prototype) { self.inner = inner }
    var displayName: String { "Recording" }
    var billed: Bool { false }
    func complete(_ r: LLMRequest) async throws -> LLMResponse {
        let res = try await inner.complete(r)
        let kind = r.prompt.hasPrefix("Score each") ? "rank" : r.prompt.hasPrefix("JOB:") ? "tailor" : r.prompt.hasPrefix("Convert") ? "parse"
                 : r.prompt.hasPrefix("Classify") ? "classify" : r.prompt.hasPrefix("Build") ? "setup" : "other"
        let input = (r.prompt.count + r.system.count + r.cache.count) / 4
        lock.withLock { _calls.append(Call(kind: kind, input: input, maxTokens: r.maxTokens, output: res.text.count / 4, smart: r.smart)) }
        return res
    }
    func total(_ kind: String) -> (calls: Int, input: Int, maxOut: Int, out: Int) {
        let c = calls.filter { $0.kind == kind }
        return (c.count, c.map(\.input).reduce(0, +), c.map(\.maxTokens).reduce(0, +), c.map(\.output).reduce(0, +))
    }
}

/// A realistic posting: ~5,000 characters, most of it boilerplate (about us, benefits, legal) around the requirements.
enum Postings {
    static let boilerplate = String(repeating: "About us: we are a fast-growing company on a mission to change how the world works, backed by leading investors and loved by customers. ", count: 12)
        + String(repeating: "Benefits include private health insurance, a generous pension, 30 days of holiday, a learning budget and flexible hours. ", count: 8)
        + "We are an equal opportunity employer and welcome applicants from every background. Reasonable adjustments are available on request."
    static func description(_ focus: String) -> String {
        boilerplate.prefix(1800) + " What you'll do: you will build \(focus) models that ship to millions of users and partner with product teams on experiments. "
            + "Requirements: 4+ years of experience with Python, SQL and machine learning in production. Experience with forecasting, causal inference or LLM evaluation is a plus. "
            + "You should have strong communication skills and the ability to explain results to non-technical partners. " + boilerplate.suffix(2600)
    }
    static func job(_ i: Int, location: String = "London, UK", url: String? = nil) -> Job {
        let titles = ["Senior Data Scientist", "Machine Learning Engineer", "Data Scientist, Forecasting", "Applied Scientist", "Senior Machine Learning Engineer"]
        var j = Job(company: "Company\(i)", title: titles[i % titles.count], location: location, url: url ?? "https://jobs.example.com/\(i)")
        j.description = description(["forecasting", "ranking", "pricing", "LLM", "causal"][i % 5]); j.posted = Dates.daysAgo(i % 10)
        return j
    }
}

final class TokenBudgetTests: XCTestCase {
    func makeStore(_ llm: RecordingLLM) async throws -> (Store, AI) {
        let store = try Store(), ai = AI(client: llm, store: store)
        try store.saveResume(try await ResumeParser(ai: ai).parse(filename: "cv.pdf", data: Fixture.pdf(lines: Fixture.resumeLines), name: "main", label: "Main"))
        var prof = Profile(); prof.personal.firstName = "Test"; prof.personal.lastName = "Person"; prof.personal.email = "test@example.com"
        prof.work.yearsExperience = "6"; prof.authorization.authorizedCountries = ["United Kingdom"]
        try store.set(.profile, prof)
        var s = SearchConfig(); s.targetTitles = ["Data Scientist", "Machine Learning Engineer"]; s.titleInclude = ["data scien", "machine learning", "applied scien"]
        s.boostKeywords = ["python", "sql", "forecasting", "machine learning"]; s.locations = ["London"]
        try store.set(.search, s)
        return (store, ai)
    }

    /// Fixture workload: 30 new postings, then 5 of them posted again for a second city, then 2 tailored resumes
    /// and one more for the second-city copy of the first. Prints the numbers used in docs/TOKEN_REPORT.md.
    func testFixtureWorkloadStaysWithinBudget() async throws {
        let llm = RecordingLLM()
        let (store, ai) = try await makeStore(llm)
        for i in 0..<30 { try store.upsert(Postings.job(i)) }
        ai.resetRunCounters()
        let first = try await Ranking(store: store, ai: ai).run { _ in }
        XCTAssertEqual(first.scored, 25, "pool of 25 scored in one call")
        let run1Tokens = ai.tokensThisRun

        // The same five roles also posted for a second location (common on Workday and Greenhouse).
        for i in 0..<5 { try store.upsert(Postings.job(i, location: "Manchester, UK", url: "https://jobs.example.com/manchester/\(i)")) }
        ai.resetRunCounters()
        let second = try await Ranking(store: store, ai: ai).run { _ in }

        // Tailor two approved roles, then a repost of the first.
        var tailored: [String] = []
        for url in ["https://jobs.example.com/0", "https://jobs.example.com/1", "https://jobs.example.com/manchester/0"] {
            let j = try XCTUnwrap(try store.jobs().first { $0.url == url })
            try store.update(j.id) { $0.variant = "main" }
            _ = try store.transition(j.id, to: .tailoring, by: "you")
            try await Tailor(store: store, ai: ai.scoped(budget: 40_000)).run(j.id)
            tailored.append(j.id)
        }

        let rank = llm.total("rank"), tailor = llm.total("tailor"), parse = llm.total("parse")
        print("TOKENS rank calls=\(rank.calls) in=\(rank.input) maxOut=\(rank.maxOut) out=\(rank.out) run1=\(run1Tokens) second.scored=\(second.scored)")
        print("TOKENS tailor calls=\(tailor.calls) in=\(tailor.input) maxOut=\(tailor.maxOut) out=\(tailor.out)")
        print("TOKENS parse calls=\(parse.calls) in=\(parse.input) maxOut=\(parse.maxOut)")
        print("TOKENS cache entries=\((try? store.cacheCount()) ?? -1)")

        // Budgets for this workload (measured 2026-11-01; see docs/TOKEN_REPORT.md).
        XCTAssertEqual(rank.calls, 2, "one scoring call per Find Jobs run")
        XCTAssertLessThanOrEqual(run1Tokens, 4_000, "first run: 25 postings scored within 4k tokens")
        XCTAssertLessThanOrEqual(rank.maxOut, 40 * 35 + 2 * 150, "reply allowance is 40 tokens per posting")
        XCTAssertTrue(llm.calls.filter { $0.kind == "rank" || $0.kind == "classify" }.allSatisfy { !$0.smart }, "scoring and email use the fast model")
        XCTAssertTrue(llm.calls.filter { $0.kind == "tailor" }.allSatisfy(\.smart), "tailoring uses the strong model")
        XCTAssertEqual(tailor.calls, 2, "the second-city copy of a role reuses its tailoring")
        XCTAssertLessThanOrEqual(tailor.input, 2 * 1_000)
        XCTAssertEqual(try store.job(tailored[2])?.status, .review, "the cached tailoring still produced a resume to review")
        XCTAssertFalse(llm.calls.contains { $0.kind == "rank" && $0.input > 6_000 }, "no scoring prompt over 6k tokens")
    }

    /// The same question twice costs one call: the second answer comes from the local cache.
    func testIdenticalQuestionsAreCached() async throws {
        let llm = RecordingLLM()
        let (store, ai) = try await makeStore(llm)
        _ = try await ResumeParser(ai: ai).parse(filename: "cv.pdf", data: Fixture.pdf(lines: Fixture.resumeLines), name: "again", label: "Again")
        XCTAssertEqual(llm.total("parse").calls, 1, "re-adding the same resume file is free")
        let r = try XCTUnwrap(try store.resume()), versions = try store.resumeVersions(), p = try store.profile()
        _ = try await SearchSetup(ai: ai).draft(SearchConfig(), resume: r.content, versions: versions, profile: p)
        _ = try await SearchSetup(ai: ai).draft(SearchConfig(), resume: r.content, versions: versions, profile: p)
        XCTAssertEqual(llm.total("setup").calls, 1)
        XCTAssertGreaterThanOrEqual(ai.cacheHitsThisRun, 2)
    }

    /// A run that would go over its limit stops before sending anything, with a plain-English message.
    func testBudgetStopsARunBeforeSpending() async throws {
        let llm = RecordingLLM()
        let (store, _) = try await makeStore(llm)
        for i in 0..<30 { try store.upsert(Postings.job(i)) }
        let small = AI(client: llm, store: store, budget: 1_000)
        do { _ = try await Ranking(store: store, ai: small).run { _ in }; XCTFail("over budget") }
        catch let e as LLMError {
            guard case .budget(_, let limit) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(limit, 1_000)
            XCTAssertTrue(e.localizedDescription.hasPrefix("Offerlane stopped here to stay within your AI limit"), e.localizedDescription)
        }
        XCTAssertEqual(llm.total("rank").calls, 0, "nothing was sent")
        XCTAssertNil(try store.jobs([.found]).first { $0.llmScore != nil }, "no scores were invented")
    }

    /// Golden set: cheaper prompts must not change which roles reach the AI, or which answer goes to which role.
    func testGoldenSetMatchQuality() async throws {
        let llm = RecordingLLM()
        let (store, ai) = try await makeStore(llm)
        let good = [("Monzo", "Senior Data Scientist", "forecasting"), ("Spotify", "Machine Learning Engineer", "ranking"),
                    ("Wise", "Data Scientist, Pricing", "pricing"), ("Deliveroo", "Applied Scientist", "causal")]
        let bad: [(String, String, String)] = [("Acme", "Account Executive", "Sell enterprise software. Requirements: 3 years of quota-carrying sales experience and a strong network."),
                   ("Initech", "Principal Data Scientist", "Requirements: 15+ years of experience leading data science organisations with machine learning and Python."),
                   ("Hooli", "Registered Nurse", "Provide patient care on a busy ward. Requirements: NMC registration and 2 years of nursing experience.")]
        for (c, t, f) in good { var j = Job(company: c, title: t, location: "London, UK", url: "https://g/\(c)"); j.description = Postings.description(f); j.posted = Dates.daysAgo(1); try store.upsert(j) }
        for (c, t, d) in bad { var j = Job(company: c, title: t, location: "London, UK", url: "https://b/\(c)"); j.description = d; j.posted = Dates.daysAgo(1); try store.upsert(j) }
        let res = try await Ranking(store: store, ai: ai).run { _ in }
        let prompt = try XCTUnwrap(llm.calls.first { $0.kind == "rank" })
        _ = prompt
        let jobs = try store.jobs([.found])
        for (c, _, _) in good { XCTAssertNotNil(jobs.first { $0.company == c }?.llmScore, "\(c) reached the AI and got its score") }
        for (c, _, _) in bad { XCTAssertNil(jobs.first { $0.company == c }?.llmScore, "\(c) was filtered out before the AI") }
        XCTAssertEqual(res.scored, 4); XCTAssertEqual(res.skipped, 3)
        // Answers map back to the right roles: the fake AI scores in prompt order (92, 89, …), and the prompt is ordered by local score.
        let byLocal = jobs.filter { $0.llmScore != nil }.sorted { ($0.localScore ?? 0) > ($1.localScore ?? 0) }
        XCTAssertEqual(byLocal.map { $0.llmScore! }, [92, 89, 86, 83])
        XCTAssertTrue(byLocal.allSatisfy { $0.llmReason == "fake reason" && $0.variant == "main" })
    }
}
