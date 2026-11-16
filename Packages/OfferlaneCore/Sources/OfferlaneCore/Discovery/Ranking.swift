import Foundation

/// Free local pre-score for every new posting, then ONE batched AI call scores the best ~25 and picks the resume
/// version. Roles stay `found` until the user approves or declines them. Ported from rank.py.
public struct Ranking: Sendable {
    public let store: Store
    public let ai: AI
    public init(store: Store, ai: AI) { self.store = store; self.ai = ai }

    static let years = "(\\d{1,2})\\s*\\+?\\s*(?:-\\s*\\d+\\s*)?(?:years|yrs)"

    /// The requirement-bearing sentences of a JD, up to `n` characters.
    public static func condense(_ d: String?, _ n: Int = 700) -> String {
        let d = d ?? ""
        let s = Re.split("(?<=[.!?•;])\\s+", d).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 25 && $0.count < 350 }
        let cue = "you (will|'ll)|responsib|require|qualif|experience (with|in)|must|should have|looking for|what you|skills"
        let keep = s.filter { Re.search(cue, $0) }
        var out = ""
        for x in (keep.isEmpty ? s : keep) { if out.count + x.count > n { break }; out += x + " " }
        let r = out.trimmingCharacters(in: .whitespaces)
        return r.isEmpty ? String(d.prefix(n)) : r
    }

    public struct Context: Sendable {
        public var titles: [String], skills: [String], penalty: [String], locs: [String], years: Double
        /// The user's watchlist companies: a ranking boost, never a filter.
        public var watch: [String]
        public init(resume r: ResumeContent, profile p: Profile, search s: SearchConfig) {
            titles = s.targetTitles.isEmpty ? r.suggestedTitles : s.targetTitles
            skills = Array((s.boostKeywords.isEmpty ? r.topSkills : s.boostKeywords).map { $0.lowercased() }.prefix(40))
            penalty = s.penaltyKeywords.map { $0.lowercased() }
            locs = s.locations.map { $0.lowercased() }
            years = Double(p.work.yearsExperience) ?? r.yearsValue
            watch = s.companies.map(\.name)
        }
    }

    /// Title overlap (40) + skills (30) − penalties + location (10) + recency (10) + years fit + watchlist (10) − no-sponsorship.
    public static func localScore(_ j: inout Job, ctx: Context, visa: Visa, now: Date = Date()) -> Double {
        let t = Set(Text.norm(j.title).split(separator: " ")), d = j.description.lowercased(), l = j.location.lowercased()
        let title = (ctx.titles.map { x -> Double in
            let w = Set(Text.norm(x).split(separator: " ")); return Double(t.intersection(w).count) / Double(max(1, w.count))
        }.max() ?? 0) * 40
        let kw = Double(min(30, 3 * ctx.skills.filter { !$0.isEmpty && d.contains($0) }.count)) - Double(min(20, 8 * ctx.penalty.filter { d.contains($0) }.count))
        let loc: Double = (ctx.locs.first.map { l.contains($0) } ?? false) ? 10 : (l.contains("remote") ? 6 : 3)
        let age = Dates.ageDays(j.posted, now: now)
        let rec: Double = age <= 7 ? 10 : (age <= 14 ? 5 : 0)
        let yrs = Re.findAll(years, String(d.prefix(6000)), [.caseInsensitive]).compactMap(Int.init).filter { $0 > 0 && $0 < 25 }
        j.minYears = yrs.min()
        let exp: Double = j.minYears.map { Double($0) <= ctx.years + 1 ? 5 : (Double($0) > ctx.years + 3 ? -20 : -5) } ?? 0
        j.visa = visa.tag(company: j.company, location: j.location, description: j.description)
        let spons: Double = j.visa == "no-sponsorship" ? -30 : 0
        let watched: Double = ctx.watch.contains { Text.norm($0) == Text.norm(j.company) } ? 10 : 0
        return (max(0, title + kw + loc + rec + exp + watched + spons) * 10).rounded() / 10
    }

    /// Version of the scoring prompt; part of every cache key, so changing the prompt never reuses old answers.
    static let promptVersion = "rank-v3"
    public static let prompt = """
    Score each job for this candidate, 0-100 (how worth applying: 85+ excellent, 70-84 good, <55 poor).
    Weigh: role fit, skills overlap, seniority/years match, logistics (location, visa tag, work authorization), pay/company.
    Penalise hard: deal-breakers, 'no-sponsorship' when sponsorship is needed, seniority gap > 3 years.
    Tier each job: "fit" = matches the candidate's experience now; "stretch" = a step up or aside (an aspiration, more seniority, a new field).
    Reply with a JSON list, one item per job, keys: i=job number, s=score, t=fit or stretch, r=reason (max 12 words)%@.
    [{"i":1,"s":0,"t":"fit","r":""%@}]
    JOBS (number | company | title | location | visa | years asked | key requirements):

    """

    struct Scored: Codable { var i: Int; @Lenient var s: String; @Lenient var r: String; var v: String?; var t: String? }

    public struct Result: Sendable, Equatable { public var scored = 0, good = 0, cached = 0, skipped = 0 }

    /// Splits `items` into runs whose request `size` stays within `limit` (nil = one run). An item too big alone still gets its own run.
    static func chunks<T>(_ items: [T], limit: Int?, size: (ArraySlice<T>) -> Int) -> [ArraySlice<T>] {
        guard let limit else { return items.isEmpty ? [] : [items[...]] }
        var out: [ArraySlice<T>] = [], start = 0
        for end in items.indices where end > start && size(items[start...end]) > limit {
            out.append(items[start..<end]); start = end
        }
        if start < items.count { out.append(items[start...]) }
        return out
    }

    /// The scoring instructions; with several resume versions the AI also picks the best one.
    static func head(versions names: [String]) -> String {
        let variantKey = names.count > 1 ? ", v=best resume version (" + names.joined(separator: "|") + ")" : ""
        return String(format: prompt, variantKey, names.count > 1 ? ",\"v\":\"\"" : "")
    }

    /// What one job contributes to the prompt, without its number (also the content part of its cache key).
    static func line(_ j: Job) -> String {
        "\(j.company) | \(j.title) | \(j.location) | \(j.visa) | \(j.minYears.map(String.init) ?? "?") | \(condense(j.description))"
    }

    public func run(progress: @escaping @Sendable (FindProgress) -> Void) async throws -> Result {
        let search = try store.search(), profile = try store.profile(), versions = try store.resumeVersions()
        guard let resume = try store.resume() else { return Result() }
        let ctx = Context(resume: resume.content, profile: profile, search: search), visa = Visa(profile: profile)
        let brief = Brief.candidate(resume: resume.content, versions: versions, profile: profile, search: search)
        let briefHash = Hash.sha256(brief)

        // Re-score only when the resume, profile or search changed: roles still waiting for a decision are scored again.
        let lastBrief: String? = try? store.get(.rankBrief)
        if let lastBrief, lastBrief != briefHash {
            for j in try store.jobs([.found]) where j.llmScore != nil { try store.update(j.id) { $0.llmScore = nil; $0.llmReason = "" } }
        }
        try? store.set(.rankBrief, briefHash)

        var res = Result()
        var fresh = try store.jobs([.found]).filter { $0.llmScore == nil }
        for i in fresh.indices {
            var j = fresh[i]
            j.localScore = Self.localScore(&j, ctx: ctx, visa: visa)
            if search.excludeCompanies.contains(where: { Text.patternHit($0, j.company) }) { j.localScore = 0 }
            fresh[i] = j; try store.save(j)
        }
        // Free pre-filters: a weak local score, a title outside the current search (e.g. found under an older one),
        // or a seniority gap no AI score would rescue never reaches the AI.
        let matcher = Discovery.Matcher(search)
        let tooSenior = { (j: Job) in (j.minYears ?? 0) > Int(ctx.years) + 5 }
        let candidates = fresh.filter { ($0.localScore ?? 0) >= 25 && matcher.titleOK($0.title, company: $0.company) && !tooSenior($0) }
        res.skipped = fresh.count - candidates.count
        let pool = Array(candidates.sorted { ($0.localScore ?? 0) > ($1.localScore ?? 0) }.prefix(search.poolSize))
        guard !pool.isEmpty else { progress(FindProgress("No new postings to score")); return res }

        let names = versions.map(\.name)
        let keyFor = { (j: Job) in ai.cacheKey(Self.promptVersion, [briefHash, names.joined(separator: ","), Self.line(j)]) }

        // Answers already given for identical content (same posting text, same candidate) cost nothing.
        var answers: [String: Scored] = [:]
        var ask: [Job] = []
        for j in pool {
            if let data = try? store.cached(keyFor(j)), let x = try? JSONCoding.decoder.decode(Scored.self, from: data) { answers[j.id] = x; res.cached += 1 }
            else { ask.append(j) }
        }
        if res.cached > 0 { ai.noteCacheHit(res.cached) }

        if !ask.isEmpty {
            progress(FindProgress("AI is scoring the \(ask.count) best new postings…"))
            let head = Self.head(versions: names)
            let request = { (part: ArraySlice<Job>) in
                LLMRequest(prompt: head + part.enumerated().map { "\($0.offset + 1) | " + Self.line($0.element) }.joined(separator: "\n"),
                           cache: brief, maxTokens: 40 * part.count + 150)
            }
            // One call normally; more only when the AI's request limit is small (an 8 GB Mac, a low tokens-per-minute plan).
            for part in Self.chunks(ask, limit: ai.client.maxRequestTokens, size: { AI.estimate(request($0)) }) {
                let scored: [Scored] = try await ai.json(request(part))
                for x in scored where x.i >= 1 && x.i <= part.count {
                    let j = part[part.startIndex + x.i - 1]; answers[j.id] = x
                    if let data = try? JSONEncoder().encode(x) { try? store.cache(keyFor(j), kind: "rank", value: data) }
                }
            }
        }

        for j in pool {
            guard let x = answers[j.id] else { continue }
            let score = Int(Double(x.s) ?? 0)
            try store.update(j.id) { job in
                job.llmScore = score; job.llmReason = x.r
                // An answer without a tier falls back to the title: an aspiration title is a stretch.
                let asp = search.aspirations.contains { Text.patternHit($0.lowercased(), job.title) }
                job.tier = x.t?.lowercased() == "stretch" || (x.t == nil && asp) ? "stretch" : "fit"
                job.variant = x.v.flatMap { names.contains($0) ? $0 : nil } ?? resume.name
            }
            res.scored += 1; if score >= search.minScore { res.good += 1 }
        }
        progress(FindProgress("Scored \(res.scored) postings: \(res.good) good matches waiting for your approval"))
        return res
    }
}

/// Find Jobs: discover, score, then check the inbox (when email tracking is on).
public struct FindJobs: Sendable {
    public let store: Store, ai: AI, http: HTTP
    public let tracking: Tracking?
    public let sources: [any JobSource]
    /// Most AI tokens this run may use; nil or 0 = no limit.
    public init(store: Store, ai: AI, http: HTTP = .shared, tracking: Tracking? = nil, tokenLimit: Int? = nil, sources: [any JobSource] = JobSources.all) {
        self.store = store; self.ai = ai.scoped(budget: (tokenLimit ?? 0) > 0 ? tokenLimit : nil); self.http = http; self.tracking = tracking
        self.sources = sources
    }

    public struct Summary: Sendable, Equatable {
        public var discovery = Discovery.Result()
        public var ranking = Ranking.Result()
        public var inbox: Tracking.Result?
        public var aiCalls = 0
        public var usd = 0.0
        public var tokens = 0
        public var tokenLimit: Int?
        public var cacheHits = 0
        /// The fallback AI that answered when the primary was rate-limited or down; empty otherwise.
        public var fallback = ""
        /// The run stopped at its AI limit; what was scored is kept and the rest is scored next time.
        public var budgetStop: String?
        public var errors: [String] = []
    }

    public func run(progress: @escaping @Sendable (FindProgress) -> Void) async throws -> Summary {
        var s = Summary(); ai.resetRunCounters()
        let ai = self.ai
        let progress: @Sendable (FindProgress) -> Void = { p in var p = p; p.tokens = ai.tokensThisRun; p.tokenLimit = ai.budget; progress(p) }
        do { s.discovery = try await Discovery(store: store, http: http, sources: sources).run(progress: progress) }
        catch is CancellationError { throw CancellationError() }
        catch { s.errors.append("Discovery: \(error.localizedDescription)") }
        s.errors += s.discovery.sourceIssues
        if s.discovery.checked > 0 && s.discovery.unreachable.count == s.discovery.checked && s.discovery.sourcesChecked.isEmpty {
            s.errors.append("No career site could be reached. You seem to be offline; check your connection and try again.")
            return s
        }
        try Task.checkCancellation()
        do { s.ranking = try await Ranking(store: store, ai: ai).run(progress: progress) }
        catch is CancellationError { throw CancellationError() }
        catch let e as LLMError where { if case .budget = e { return true }; return false }() { s.budgetStop = e.localizedDescription }
        catch { s.errors.append("Scoring: \(error.localizedDescription)"); progress(FindProgress("Scoring failed: \(error.localizedDescription)")) }
        if let tracking {
            progress(FindProgress("Checking your inbox for replies…"))
            do { s.inbox = try await tracking.run() }
            catch let e as LLMError where { if case .budget = e { return true }; return false }() { s.budgetStop = e.localizedDescription }
            catch { s.errors.append("Email check: \(error.localizedDescription)") }
        }
        s.aiCalls = ai.callsThisRun; s.usd = ai.usdThisRun; s.tokens = ai.tokensThisRun; s.tokenLimit = ai.budget; s.cacheHits = ai.cacheHitsThisRun; s.fallback = ai.fallbackThisRun
        try? store.addEvent("run", status: "find", source: "app",
                            detail: "\(s.discovery.matching) matching, \(s.discovery.new) new, \(s.ranking.good) good matches, \(s.aiCalls) AI calls, \(s.tokens) tokens")
        return s
    }
}
