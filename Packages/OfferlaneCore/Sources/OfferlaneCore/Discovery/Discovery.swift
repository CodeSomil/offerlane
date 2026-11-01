import Foundation

public struct FindProgress: Sendable, Equatable {
    public var message: String
    /// 0…1, or nil when indeterminate.
    public var fraction: Double?
    public init(_ message: String, _ fraction: Double? = nil) { self.message = message; self.fraction = fraction }
}

/// Where each company's job board lives (cached: hits for 30 days, misses re-probed after 10).
public struct ATSHit: Codable, Sendable, Hashable {
    public var ats: String?
    public var slug: String?
    public var checked: String
}

/// Discovery with no LLM tokens: each target company's own public job board. Ported from discover.py.
public struct Discovery: Sendable {
    public let store: Store
    public let http: HTTP
    public var concurrency = 8
    public var budget: TimeInterval = 420

    public init(store: Store, http: HTTP = .shared) { self.store = store; self.http = http }

    public struct Result: Sendable, Equatable {
        public var checked = 0, matching = 0, new = 0
        public var unreachable: [String] = []
        public var noBoard: [String] = []
    }

    // MARK: filters

    public struct Matcher: Sendable {
        let include: [String], exclude: [String], companiesOut: [String], locs: [String], remote: Bool, maxAge: Int
        public init(_ s: SearchConfig) {
            include = s.titleInclude; exclude = s.titleExclude; companiesOut = s.excludeCompanies
            locs = s.locations.map { $0.lowercased() }; remote = s.remoteOk; maxAge = s.maxAgeDays
        }
        public func titleOK(_ t: String, company: String = "") -> Bool {
            (include.isEmpty || include.contains { Text.patternHit($0, t) }) && !exclude.contains { Text.patternHit($0, t) }
                && !companiesOut.contains { Text.patternHit($0, company) }
        }
        public func locationOK(_ l: String) -> Bool {
            let l = l.lowercased()
            return locs.isEmpty || locs.contains { l.contains($0) } || (remote && (l.contains("remote") || l.contains("anywhere")))
        }
        public func keep(_ p: Posting, company: String, now: Date = Date()) -> Bool {
            !p.title.isEmpty && titleOK(p.title, company: company) && locationOK(p.location) && (p.posted == nil || Dates.ageDays(p.posted, now: now) <= maxAge)
        }
    }

    // MARK: slug resolution

    static func candidates(_ name: String, slug: String?) -> [String] {
        let b = Re.sub("[^a-z0-9 ]", "", name.lowercased())
        var out: [String] = []
        for c in [slug, b.replacingOccurrences(of: " ", with: ""), b.replacingOccurrences(of: " ", with: "-"), b.split(separator: " ").first.map(String.init)] {
            if let c, !c.isEmpty, !out.contains(c) { out.append(c) }
        }
        return out
    }

    func resolve(_ c: SearchConfig.Company, cache: [String: ATSHit]) async -> ATSHit {
        if let ats = c.ats, ats != "workday", let slug = c.slug { return ATSHit(ats: ats, slug: slug, checked: Dates.today()) }
        if let hit = cache[c.name], Dates.ageDays(hit.checked) < (hit.ats != nil ? 30 : 10) { return hit }
        for s in Self.candidates(c.name, slug: c.slug) {
            for ats in ATS.probeOrder {
                if Task.isCancelled { return ATSHit(ats: nil, slug: nil, checked: "2000-01-01") }
                if let jobs = await ats.list(s, http: http), !jobs.isEmpty { return ATSHit(ats: ats.rawValue, slug: s, checked: Dates.today()) }
            }
        }
        return ATSHit(ats: nil, slug: nil, checked: Dates.today())
    }

    // MARK: run

    enum Outcome: Sendable { case jobs([Job], hit: ATSHit?), noBoard(ATSHit), unreachable, skipped }

    public func run(progress: @escaping @Sendable (FindProgress) -> Void) async throws -> Result {
        let search = try store.search()
        let matcher = Matcher(search)
        var cache = (try? store.get(.atsCache, as: [String: ATSHit].self)) ?? [:]
        let companies = search.companies
        let queries = search.targetTitles.isEmpty ? [""] : Array(search.targetTitles.prefix(3))
        let start = Date()
        var result = Result(); var found: [Job] = []
        progress(FindProgress("Checking \(companies.count) career sites…", 0))

        try await withThrowingTaskGroup(of: (String, Outcome).self) { group in
            var next = 0, done = 0, matching = 0
            let snapshot = cache
            func launch() {
                guard next < companies.count else { return }
                let c = companies[next]; next += 1
                group.addTask {
                    if Date().timeIntervalSince(start) > budget || Task.isCancelled { return (c.name, .skipped) }
                    return (c.name, await one(c, cache: snapshot, matcher: matcher, queries: queries))
                }
            }
            for _ in 0..<min(concurrency, companies.count) { launch() }
            while let (name, outcome) = try await group.next() {
                try Task.checkCancellation()
                done += 1
                switch outcome {
                case .jobs(let jobs, let hit): found += jobs; matching += jobs.count; if let hit { cache[name] = hit }
                case .noBoard(let hit): cache[name] = hit; result.noBoard.append(name)
                case .unreachable: result.unreachable.append(name)
                case .skipped: break
                }
                progress(FindProgress("Checking \(companies.count) career sites… \(done) done, \(matching) matching", Double(done) / Double(max(1, companies.count))))
                launch()
            }
        }
        try? store.set(.atsCache, cache)
        result.checked = companies.count; result.matching = found.count
        for j in found where (try? store.upsert(j)) == true { result.new += 1 }
        progress(FindProgress("Checked \(companies.count) career sites: \(result.matching) matching, \(result.new) new", 1))
        return result
    }

    func one(_ c: SearchConfig.Company, cache: [String: ATSHit], matcher: Matcher, queries: [String]) async -> Outcome {
        let ats: ATS, slug: String, hit: ATSHit?
        if let wd = c.workday {
            ats = .workday; slug = wd; hit = nil
        } else {
            let h = await resolve(c, cache: cache)
            guard let a = h.ats.flatMap(ATS.init(rawValue:)), let s = h.slug else { return .noBoard(h) }
            ats = a; slug = s; hit = h
        }
        guard let postings = await ats.list(slug, http: http, queries: queries) else { return .unreachable }
        var out: [Job] = []
        for var p in postings where matcher.keep(p, company: c.name) {
            if p.description.isEmpty, let d = p.detail, let r = await http.get(d), r.status == 200, let j = r.json { p.description = ATS.detailText(j) }
            var job = Job(company: c.name, title: p.title, location: p.location, url: p.url)
            job.applyUrl = p.applyUrl; job.posted = p.posted; job.description = p.description
            job.source = "ats:\(ats.rawValue)"; job.ats = ats.rawValue; job.atsSlug = ats == .workday ? "" : slug
            out.append(job)
        }
        return .jobs(out, hit: hit)
    }
}
