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
        public init(resume r: ResumeContent, profile p: Profile, search s: SearchConfig) {
            titles = s.targetTitles.isEmpty ? r.suggestedTitles : s.targetTitles
            skills = Array((s.boostKeywords.isEmpty ? r.topSkills : s.boostKeywords).map { $0.lowercased() }.prefix(40))
            penalty = s.penaltyKeywords.map { $0.lowercased() }
            locs = s.locations.map { $0.lowercased() }
            years = Double(p.work.yearsExperience) ?? r.yearsValue
        }
    }

    /// Title overlap (40) + skills (30) − penalties + location (10) + recency (10) + years fit − no-sponsorship.
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
        return (max(0, title + kw + loc + rec + exp + spons) * 10).rounded() / 10
    }

    public static let prompt = """
    Score each job for this candidate, 0-100 (how worth applying: 85+ excellent, 70-84 good, <55 poor).
    Weigh 5 dimensions: role fit, skills overlap, seniority/years match, logistics (location, visa tag, work authorization), pay/company.
    Penalise hard: deal-breakers, 'no-sponsorship' when sponsorship is needed, seniority gap > 3 years.
    Return JSON list: [{"id":"","score":0,"reason":"<=14 words"%@}]
    JOBS (id | company | title | location | visa | years asked | key requirements):

    """

    struct Scored: Decodable { var id: String; @Lenient var score: String; @Lenient var reason: String; var variant: String? }

    public struct Result: Sendable, Equatable { public var scored = 0, good = 0 }

    public func run(progress: @escaping @Sendable (FindProgress) -> Void) async throws -> Result {
        let search = try store.search(), profile = try store.profile(), versions = try store.resumeVersions()
        guard let resume = try store.resume() else { return Result() }
        let ctx = Context(resume: resume.content, profile: profile, search: search), visa = Visa(profile: profile)
        var fresh = try store.jobs([.found]).filter { $0.llmScore == nil }
        for i in fresh.indices {
            var j = fresh[i]
            j.localScore = Self.localScore(&j, ctx: ctx, visa: visa)
            if search.excludeCompanies.contains(where: { Text.patternHit($0, j.company) }) { j.localScore = 0 }
            fresh[i] = j; try store.save(j)
        }
        let pool = Array(fresh.filter { ($0.localScore ?? 0) >= 25 }.sorted { ($0.localScore ?? 0) > ($1.localScore ?? 0) }.prefix(search.poolSize))
        guard !pool.isEmpty else { progress(FindProgress("No new postings to score")); return Result() }
        progress(FindProgress("AI is scoring the \(pool.count) best new postings…"))
        let names = versions.map(\.name)
        let vfield = names.count > 1 ? ",\"variant\":\"" + names.joined(separator: "|") + "\"" : ""
        let lines = pool.map { j in
            "\(j.id) | \(j.company) | \(j.title) | \(j.location) | \(j.visa) | \(j.minYears.map(String.init) ?? "?") | \(Self.condense(j.description))"
        }
        let brief = Brief.candidate(resume: resume.content, versions: versions, profile: profile, search: search)
        let scored: [Scored] = try await ai.json(LLMRequest(prompt: String(format: Self.prompt, vfield) + lines.joined(separator: "\n"),
                                                            cache: brief, maxTokens: 70 * pool.count + 200))
        var res = Result()
        let byID = Dictionary(scored.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for j in pool {
            guard let x = byID[j.id] else { continue }
            let score = Int(Double(x.score) ?? 0)
            try store.update(j.id) { job in
                job.llmScore = score; job.llmReason = x.reason
                job.variant = x.variant.flatMap { names.contains($0) ? $0 : nil } ?? resume.name
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
    public init(store: Store, ai: AI, http: HTTP = .shared, tracking: Tracking? = nil) { self.store = store; self.ai = ai; self.http = http; self.tracking = tracking }

    public struct Summary: Sendable, Equatable {
        public var discovery = Discovery.Result()
        public var ranking = Ranking.Result()
        public var inbox: Tracking.Result?
        public var aiCalls = 0
        public var usd = 0.0
        public var errors: [String] = []
    }

    public func run(progress: @escaping @Sendable (FindProgress) -> Void) async throws -> Summary {
        var s = Summary(); ai.resetRunCounters()
        do { s.discovery = try await Discovery(store: store, http: http).run(progress: progress) }
        catch is CancellationError { throw CancellationError() }
        catch { s.errors.append("Discovery: \(error.localizedDescription)") }
        if s.discovery.checked > 0 && s.discovery.unreachable.count == s.discovery.checked {
            s.errors.append("No career site could be reached. You seem to be offline; check your connection and try again.")
            return s
        }
        try Task.checkCancellation()
        do { s.ranking = try await Ranking(store: store, ai: ai).run(progress: progress) }
        catch is CancellationError { throw CancellationError() }
        catch { s.errors.append("Scoring: \(error.localizedDescription)"); progress(FindProgress("Scoring failed: \(error.localizedDescription)")) }
        if let tracking {
            progress(FindProgress("Checking your inbox for replies…"))
            do { s.inbox = try await tracking.run() } catch { s.errors.append("Email check: \(error.localizedDescription)") }
        }
        s.aiCalls = ai.callsThisRun; s.usd = ai.usdThisRun
        try? store.addEvent("run", status: "find", source: "app",
                            detail: "\(s.discovery.matching) matching, \(s.discovery.new) new, \(s.ranking.good) good matches, \(s.aiCalls) AI calls")
        return s
    }
}
