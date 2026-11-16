import XCTest
@testable import OfferlaneCore

final class SkillGapTests: XCTestCase {
    static func job(_ company: String, _ title: String, _ loc: String, _ desc: String) -> Job {
        var j = Job(company: company, title: title, location: loc, url: "https://example.com/\(company)")
        j.description = desc; return j
    }
    /// Three "Head of AI Startups, EMEA"-style postings plus two off-target ones.
    static let postings = [
        job("Cloudco", "Head of AI Startups", "London, EMEA", "Lead our startup ecosystem in EMEA. Build partnerships with VC firms and founders. Go-to-market for generative AI. Python a plus."),
        job("Modelworks", "Head of Startups, AI", "Paris", "Own partnerships and business development with early stage startups. Deep knowledge of LLMs and AWS. People management."),
        job("Gridlabs", "Head of AI Partnerships, EMEA", "Remote - EMEA", "Strategic partnerships across EMEA. Experience with large language models, fundraising and investors. Stakeholder management."),
        job("Shopco", "Account Executive", "London", "Enterprise sales, quota, partnerships."),
        job("Datafirm", "Data Scientist", "Berlin", "Python, SQL, statistics."),
    ]
    let role = "Head of AI Startups, EMEA"

    func testScanCountsSkillsOnlyFromRelevantPostings() {
        let s = MarketScan.scan(Self.postings, role: role)
        XCTAssertEqual(s.postings, 3, "off-target titles excluded")
        let count = Dictionary(uniqueKeysWithValues: s.demand.map { ($0.id, $0.count) })
        XCTAssertEqual(count["partnerships"], 3)
        XCTAssertEqual(count["llm"], 3, "generative ai / LLMs / large language models are one skill")
        XCTAssertEqual(count["startups"], 2)
        XCTAssertEqual(count["emea"], 2, "location picks the posting but only title + description are scanned")
        XCTAssertEqual(count["python"], 1); XCTAssertEqual(count["aws"], 1)
        XCTAssertNil(count["sql"], "SQL only in an off-target posting")
        let p = s.demand.first { $0.id == "python" }!
        XCTAssertEqual(p.jobIds, [Self.postings[0].id], "each count cites its postings")
    }

    func testWholeWordMatchingOnly() {
        let lex = SkillLexicon([.init(id: "r", name: "R lang", aliases: ["r programming"]), .init(id: "go", name: "Golang", aliases: ["golang"])])
        XCTAssertEqual(lex.matches("Strong R-programming; we're going places"), ["r"])
    }

    func testGapRankingAndReadinessAreDeterministicAndExplained() {
        var r = ResumeContent(); r.skills = [.init(label: "Core", items: "Python, partnerships, LLMs")]
        let a = GapReport.analyse(MarketScan.scan(Self.postings, role: role), resume: r)
        let b = GapReport.analyse(MarketScan.scan(Self.postings.reversed(), role: role), resume: r)
        XCTAssertEqual(a, b, "input order does not change the report")
        XCTAssertTrue(a.items.first { $0.id == "partnerships" }!.have)
        XCTAssertFalse(a.gaps.contains { $0.id == "llm" })
        XCTAssertEqual(a.gaps.first?.id, "startups", "2/3 postings × weight 3 ranks first")
        let total = a.items.reduce(0) { $0 + $1.score }, covered = a.items.filter(\.have).reduce(0) { $0 + $1.score }
        XCTAssertEqual(a.readiness, Int((covered / total * 100).rounded()), "readiness is exactly the sum of its listed parts")
        let more = GapReport.analyse(MarketScan.scan(Self.postings, role: role), resume: r, alsoHave: ["emea"])
        XCTAssertGreaterThan(more.readiness, a.readiness)
    }

    func testNoPostingsGivesZeroNotACrash() {
        let g = GapReport.analyse(MarketScan.scan([], role: role), resume: nil)
        XCTAssertEqual(g.readiness, 0); XCTAssertTrue(g.items.isEmpty)
    }

    func testBundledLexiconLoadsWithUniqueIds() {
        let ids = SkillLexicon.bundled.entries.map(\.id)
        XCTAssertGreaterThan(ids.count, 50); XCTAssertEqual(ids.count, Set(ids).count)
    }
}

/// Answers by exact URL: (status, redirect target). Unknown URLs fail like a dead host.
final class LinkStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, String?)] = [:]
    static func session() -> URLSession { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [LinkStub.self]; return URLSession(configuration: c) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        guard let (status, to) = Self.routes[url.absoluteString] else { client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return }
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: to.map { ["Location": $0] })!
        if let to { client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: to)!), redirectResponse: resp); return }
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LearningCatalogTests: XCTestCase {
    func testLinkCheckerAcceptsOnlyLiveSameSiteLinks() async {
        LinkStub.routes = [
            "https://learn.example.org/ok": (200, nil),
            "https://learn.example.org/gone": (404, nil),
            "https://learn.example.org/moved": (301, "https://www.example.org/new"),
            "https://www.example.org/new": (200, nil),
            "https://learn.example.org/hijacked": (302, "https://parked-domains.example.net/"),
            "https://parked-domains.example.net/": (200, nil),
        ]
        let lc = LinkChecker(session: LinkStub.session())
        let ok = await lc.check("https://learn.example.org/ok"), gone = await lc.check("https://learn.example.org/gone")
        let moved = await lc.check("https://learn.example.org/moved"), away = await lc.check("https://learn.example.org/hijacked")
        let dead = await lc.check("https://nowhere.example.org/"), http = await lc.check("http://learn.example.org/ok")
        XCTAssertTrue(ok.ok); XCTAssertFalse(gone.ok); XCTAssertEqual(gone.status, 404)
        XCTAssertTrue(moved.ok, "redirect within the same site is fine")
        XCTAssertFalse(away.ok, "redirect to another site is not shown")
        XCTAssertFalse(dead.ok); XCTAssertEqual(dead.status, 0, "no answer is reported as status 0 (offline)")
        XCTAssertFalse(http.ok, "https only")
    }

    func testLinkCheckerCachesGoodResultsAndRechecksFailures() async {
        LinkStub.routes = ["https://a.example.org/x": (200, nil)]
        let lc = LinkChecker(session: LinkStub.session())
        let fresh = LinkChecker.Result(ok: true, status: 200, checked: Dates.now()), old = LinkChecker.Result(ok: true, status: 200, checked: Dates.daysAgo(30))
        let bad = LinkChecker.Result(ok: false, status: 0, checked: Dates.now())
        let out = await lc.check(["https://cached.example.org/", "https://a.example.org/x", "https://stale.example.org/"],
                                 cache: ["https://cached.example.org/": fresh, "https://a.example.org/x": bad, "https://stale.example.org/": old])
        XCTAssertEqual(out["https://cached.example.org/"], fresh, "fresh good result reused, no request")
        XCTAssertEqual(out["https://a.example.org/x"]?.ok, true, "failure rechecked")
        XCTAssertEqual(out["https://stale.example.org/"]?.ok, false, "stale result rechecked (and now unreachable)")
    }

    func testBundledCatalogIsWellFormed() {
        let items = LearningCatalog.bundled, lex = Set(SkillLexicon.bundled.entries.map(\.id))
        XCTAssertGreaterThan(items.count, 30); XCTAssertEqual(items.count, Set(items.map(\.id)).count)
        for c in items {
            XCTAssertTrue(c.url.hasPrefix("https://"), c.id)
            XCTAssertTrue(["free", "audit", "paid"].contains(c.access), c.id)
            XCTAssertTrue(Set(c.skills).isSubset(of: lex), "\(c.id) names an unknown skill")
            if c.kind == "cert" { XCTAssertNotNil(c.cost, "\(c.id): certs state their cost") }
        }
    }

    func testCandidatesAreFreeFirstThenMostUseful() {
        let gap = { (id: String, score: Double) in GapItem(demand: SkillDemand(id: id, name: id, kind: "skill", weight: 2, count: 1, jobIds: []), have: false, share: 1, score: score) }
        let items = [CatalogItem(id: "paid", title: "", provider: "", url: "https://x.org", kind: "cert", access: "paid", cost: "1", skills: ["aws", "llm"]),
                     CatalogItem(id: "free-small", title: "", provider: "", url: "https://x.org", skills: ["aws"]),
                     CatalogItem(id: "free-big", title: "", provider: "", url: "https://x.org", skills: ["aws", "llm"]),
                     CatalogItem(id: "audit", title: "", provider: "", url: "https://x.org", access: "audit", skills: ["llm"]),
                     CatalogItem(id: "unrelated", title: "", provider: "", url: "https://x.org", skills: ["sql"])]
        XCTAssertEqual(LearningCatalog.candidates(for: [gap("aws", 1), gap("llm", 2)], in: items).map(\.id), ["free-big", "free-small", "audit", "paid"])
    }
}

final class SkillPlanTests: XCTestCase {
    let role = "Head of AI Startups, EMEA"
    let catalog = [
        CatalogItem(id: "free-startups", title: "New Enterprises", provider: "MIT OpenCourseWare", url: "https://ocw.example.org/ne", skills: ["startups", "venture-capital"]),
        CatalogItem(id: "free-bd", title: "Negotiation", provider: "Coursera", url: "https://learn.example.org/neg", access: "audit", skills: ["business-development"]),
        CatalogItem(id: "dead", title: "Gone course", provider: "X", url: "https://gone.example.org/", skills: ["startups"]),
        CatalogItem(id: "cert-aws", title: "AWS Certified AI Practitioner", provider: "AWS", url: "https://aws.example.org/aip", kind: "cert", access: "paid", cost: "100 USD exam", skills: ["aws-ml", "aws"]),
    ]

    func store() throws -> Store {
        let st = try Store()
        for j in SkillGapTests.postings { _ = try st.upsert(j) }
        var r = ResumeContent(); r.skills = [.init(label: "Core", items: "Python, partnerships, LLMs")]; r.certifications = ["MSc thesis prize"]
        try st.saveResume(ResumeVersion(name: "main", label: "Main", content: r, sourceText: "", sourceFile: "cv.txt"))
        LinkStub.routes = ["https://ocw.example.org/ne": (200, nil), "https://learn.example.org/neg": (200, nil), "https://aws.example.org/aip": (200, nil), "https://gone.example.org/": (404, nil)]
        return st
    }

    func testInventedResourcesFromTheAIAreRejected() async throws {
        let st = try store()
        let liar = FakeLLM(rules: [{ r in
            guard r.prompt.hasPrefix("Choose learning resources") else { return nil }
            return """
            {"picks":[{"id":"made-up-course","why":"Great"},{"id":"free-bd","why":"See https://evil.example.com/course","url":"https://evil.example.com"},
                      {"id":"dead","why":"x"},{"id":"free-startups","why":"Core startup skills."}],
             "projects":["Read https://fake.example.com/guide","Run a founder office-hours pilot."]}
            """ }])
        let report = try SkillPlanner.report(store: st, role: role, catalog: catalog)
        let plan = await SkillPlanner.plan(report, state: SkillPlanState(), ai: AI(client: liar, store: st), checker: LinkChecker(session: LinkStub.session()), store: st, catalog: catalog)
        XCTAssertEqual(plan.steps.map(\.id), ["free-bd", "free-startups"], "invented id and the unverified link are dropped")
        XCTAssertEqual(plan.steps.first?.why, "", "explanation carrying a link is blanked")
        XCTAssertEqual(plan.steps.last?.why, "Core startup skills.")
        XCTAssertEqual(plan.projects, ["Run a founder office-hours pilot."])
        XCTAssertEqual(plan.hidden, 1)
        XCTAssertTrue(plan.steps.allSatisfy { s in self.catalog.contains(s.item) }, "every shown resource is a catalog entry, url included")
    }

    func testWithoutAIThePlanIsDeterministicFreeFirstAndSaysWhenOffline() async throws {
        let st = try store()
        let report = try SkillPlanner.report(store: st, role: role, catalog: catalog)
        var state = SkillPlanState(); state.hoursPerWeek = 3
        let plan = await SkillPlanner.plan(report, state: state, ai: nil, checker: LinkChecker(session: LinkStub.session()), store: st, catalog: catalog)
        XCTAssertEqual(plan.steps.map(\.id), ["free-startups", "free-bd", "cert-aws"])
        XCTAssertEqual(plan.steps.map(\.week), [1, 2, 3], "unlisted length plans a week each")
        XCTAssertEqual(plan.steps.first?.askedBy, 2, "startups asked for in 2 of 3 postings")
        XCTAssertFalse(plan.offline); XCTAssertFalse(plan.projects.isEmpty)

        LinkStub.routes = [:]; try st.set(.linkChecks, [String: LinkChecker.Result]())
        let off = await SkillPlanner.plan(report, state: state, ai: nil, checker: LinkChecker(session: LinkStub.session()), store: st, catalog: catalog)
        XCTAssertTrue(off.offline); XCTAssertTrue(off.steps.isEmpty, "nothing unverified is shown")
    }

    func testOnlyMarkingACertDoneWritesItToTheResumeAndUndoRemovesIt() throws {
        let st = try store(), cert = catalog[3], course = catalog[0]
        let before = try SkillPlanner.report(store: st, role: role, catalog: catalog)
        XCTAssertEqual(try st.resume()?.content.certifications, ["MSc thesis prize"], "planning alone never touches the resume")
        try SkillPlanner.setDone(course, true, store: st)
        XCTAssertEqual(try st.resume()?.content.certifications, ["MSc thesis prize"], "a course is not a certificate")
        XCTAssertGreaterThan(try SkillPlanner.report(store: st, role: role, catalog: catalog).readiness, before.readiness, "re-scored on completion")
        try SkillPlanner.setDone(cert, true, store: st)
        XCTAssertEqual(try st.resume()?.content.certifications, ["MSc thesis prize", "AWS Certified AI Practitioner"])
        try SkillPlanner.setDone(cert, false, store: st)
        XCTAssertEqual(try st.resume()?.content.certifications, ["MSc thesis prize"], "undo takes out only what we added")
    }

    func testMalformedAIAnswerFallsBackToTheStandardOrder() async throws {
        let st = try store(), junk = FakeLLM(rules: [{ _ in "not json at all" }])
        let report = try SkillPlanner.report(store: st, role: role, catalog: catalog)
        let plan = await SkillPlanner.plan(report, state: SkillPlanState(), ai: AI(client: junk, store: st), checker: LinkChecker(session: LinkStub.session()), store: st, catalog: catalog)
        XCTAssertEqual(plan.steps.map(\.id), ["free-startups", "free-bd", "cert-aws"])
    }

    func testRolesFallBackToAspirationsThenTargets() {
        var s = SearchConfig(); s.targetTitles = ["Data Scientist"]; var st = SkillPlanState()
        XCTAssertEqual(SkillPlanner.roles(st, s), ["Data Scientist"])
        s.aspirations = ["Head of AI"]; XCTAssertEqual(SkillPlanner.roles(st, s), ["Head of AI"])
        st.roles = ["CTO"]; XCTAssertEqual(SkillPlanner.roles(st, s), ["CTO"])
    }
}
