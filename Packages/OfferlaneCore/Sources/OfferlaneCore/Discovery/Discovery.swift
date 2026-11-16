import Foundation

public struct FindProgress: Sendable, Equatable {
    public var message: String
    /// 0…1, or nil when indeterminate.
    public var fraction: Double?
    /// AI tokens used so far this run, and the run's limit (nil = none), for the usage meter.
    public var tokens = 0
    public var tokenLimit: Int?
    public init(_ message: String, _ fraction: Double? = nil) { self.message = message; self.fraction = fraction }
}

/// Where each company's job board lives (cached: hits for 30 days, misses re-probed after 10).
public struct ATSHit: Codable, Sendable, Hashable {
    public var ats: String?
    public var slug: String?
    public var checked: String
}

/// Discovery with no LLM tokens: each watchlist company's own public job board, plus the free job APIs (`JobSources`),
/// so results are not limited to companies the user listed. Ported from discover.py.
public struct Discovery: Sendable {
    public let store: Store
    public let http: HTTP
    public var concurrency = 8
    public var budget: TimeInterval = 420
    /// Candidate sources; the user's switches (`SearchConfig.sources`) pick from these.
    public var sources: [any JobSource]

    public init(store: Store, http: HTTP = .shared, sources: [any JobSource] = JobSources.all) { self.store = store; self.http = http; self.sources = sources }

    public struct Result: Sendable, Equatable {
        public var checked = 0, matching = 0, new = 0
        public var unreachable: [String] = []
        public var noBoard: [String] = []
        /// Job APIs that answered this run, and plain-language notes for ones that didn't (rate limit, unreachable).
        public var sourcesChecked: [String] = []
        public var sourceIssues: [String] = []
    }

    // MARK: filters

    public struct Matcher: Sendable {
        var include: [String]
        let exclude: [String], companiesOut: [String], locs: [String], remote: Bool, maxAge: Int
        public init(_ s: SearchConfig) {
            // Aspiration titles pass the title filter too, so stretch roles are found.
            include = s.titleInclude.isEmpty ? [] : s.titleInclude + s.aspirations.map { $0.lowercased() }; exclude = s.titleExclude; companiesOut = s.excludeCompanies
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
        public func keep(_ p: Posting, company: String, now: Date = Date()) -> Bool { keep(title: p.title, location: p.location, posted: p.posted, company: company, now: now) }
        public func keep(_ j: Job, now: Date = Date()) -> Bool { keep(title: j.title, location: j.location, posted: j.posted, company: j.company, now: now) }
        func keep(title: String, location: String, posted: String?, company: String, now: Date) -> Bool {
            !title.isEmpty && titleOK(title, company: company) && locationOK(location) && (posted == nil || Dates.ageDays(posted, now: now) <= maxAge)
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
        // Watchlist first, then boards learned from earlier runs (never ones the user excluded).
        let watch = Set(search.companies.map { $0.name.lowercased() })
        var registry = (try? store.get(.boardRegistry, as: [SearchConfig.Company].self)) ?? []
        let learned = registry.filter { c in !watch.contains(c.name.lowercased()) && !matcher.companiesOut.contains { Text.patternHit($0, c.name) } }
        let learnedNames = Set(learned.map(\.name))
        let companies = search.companies + learned
        let queries = search.targetTitles.isEmpty ? [""] : Array(search.targetTitles.prefix(3))
        let start = Date()
        var result = Result(); var found: [Job] = []; var deadLearned = Set<String>()
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
                case .unreachable: if learnedNames.contains(name) { deadLearned.insert(name) } else { result.unreachable.append(name) }
                case .skipped: break
                }
                progress(FindProgress("Checking \(companies.count) career sites… \(done) done, \(matching) matching", Double(done) / Double(max(1, companies.count))))
                launch()
            }
        }
        try? store.set(.atsCache, cache)
        result.checked = companies.count
        try Task.checkCancellation()
        found += await fromSources(search: search, matcher: matcher, result: &result, progress: progress)
        // The same role from two sources counts once (the store also de-duplicates against earlier runs and hidden roles).
        var seen = Set<String>(); found = found.filter { seen.insert($0.id).inserted }
        // A learned board that stopped answering is dropped, unless everything failed (then we're probably offline).
        if result.unreachable.count < search.companies.count || !result.sourcesChecked.isEmpty { registry.removeAll { deadLearned.contains($0.name) } }
        registry = Self.learn(from: found, into: registry)
        try? store.set(.boardRegistry, registry)
        result.matching = found.count
        for j in found where (try? store.upsert(j)) == true { result.new += 1 }
        progress(FindProgress("Checked \(companies.count) career sites: \(result.matching) matching, \(result.new) new", 1))
        return result
    }

    static let registryLimit = 300

    /// Adds the ATS boards that found jobs link to (newest last, at most `registryLimit`), so later runs search them directly.
    static func learn(from jobs: [Job], into registry: [SearchConfig.Company]) -> [SearchConfig.Company] {
        var reg = registry, known = Set(registry.map { $0.name.lowercased() })
        for j in jobs where j.ats.isEmpty {
            guard let link = [j.url, j.applyUrl].first(where: { Careers.boardLink(in: $0) != nil }),
                  var c = Careers.detect(link, name: j.company), known.insert(c.name.lowercased()).inserted else { continue }
            if c.ats == "workday", c.workday == nil { continue }
            c.name = j.company; reg.append(c)
        }
        return Array(reg.suffix(registryLimit))
    }

    /// Each enabled job API once, respecting its minimum interval; a rate-limited source backs off for a full interval.
    func fromSources(search: SearchConfig, matcher: Matcher, result: inout Result, progress: @Sendable (FindProgress) -> Void) async -> [Job] {
        var runs = (try? store.get(.sourceRuns, as: [String: Date].self)) ?? [:]
        let queries = QueryExpansion.queries(search: search, resume: (try? store.resume())?.content)
        // A whole feed with no title filter would flood the store: fall back to the expanded phrases.
        var m = matcher; if m.include.isEmpty { m.include = QueryExpansion.phrases(search: search, resume: (try? store.resume())?.content) }
        var out: [Job] = []
        for src in JobSources.enabled(search, from: sources) {
            if Task.isCancelled { break }
            if let last = runs[src.id], Date().timeIntervalSince(last) < src.minInterval { continue }
            progress(FindProgress("Checking \(src.name)…"))
            switch await src.fetch(queries, http: http) {
            case .jobs(let jobs):
                runs[src.id] = Date(); result.sourcesChecked.append(src.name)
                out += jobs.filter { m.keep($0) }
            case .rateLimited:
                runs[src.id] = Date()
                result.sourceIssues.append("\(src.name) asked us to slow down, so it was skipped. It's checked again on a later run.")
            case .refused(let why):
                result.sourceIssues.append(why)
            case .unreachable:
                result.sourceIssues.append("\(src.name) couldn't be reached. Check your connection; the next Find Jobs tries again.")
            }
        }
        try? store.set(.sourceRuns, runs)
        return out
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
