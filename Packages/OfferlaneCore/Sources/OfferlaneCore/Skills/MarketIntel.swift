import Foundation

/// Demand by role and city, and rising/falling skills, from the postings the user has collected. Local, no AI call, not a market survey.
public enum MarketIntel {
    public struct Slice: Codable, Hashable, Sendable, Identifiable {
        public var name: String
        public var jobIds: [String]
        /// Most-asked skills in this slice, each citing the postings that ask.
        public var top: [SkillDemand]
        public var postings: Int { jobIds.count }
        public var id: String { name }
    }

    public struct Trend: Codable, Hashable, Sendable, Identifiable {
        public var demand: SkillDemand
        /// Postings asking in each window (cited in `demand.jobIds`: recent first, then prior).
        public var recent: Int
        public var prior: Int
        /// Share of postings in each window, 0...1.
        public var recentShare: Double
        public var priorShare: Double
        public var change: Double { recentShare - priorShare }
        public var id: String { demand.id }
    }

    public struct Trends: Codable, Hashable, Sendable {
        public var recentPostings: Int
        public var priorPostings: Int
        public var rising: [Trend]
        public var falling: [Trend]
        /// False when either window has fewer than `minPostings`: no trend is claimed.
        public var enough: Bool
    }

    // shortcut: fixed 30-day windows and a 5-posting minimum per window; make them settings if users ask.
    public static let windowDays = 30, minPostings = 5

    /// One slice per role (in the given order), from MarketScan's role matching.
    public static func byRole(_ jobs: [Job], roles: [String], top: Int = 5, lexicon: SkillLexicon = .bundled) -> [Slice] {
        roles.map { r in
            let s = MarketScan.scan(jobs, role: r, lexicon: lexicon)
            return Slice(name: r, jobIds: s.jobIds, top: Array(s.demand.prefix(top)))
        }
    }

    /// "London, UK" → "London"; anything mentioning remote → "Remote"; empty → "Unknown".
    // shortcut: first comma part only, so "NYC" and "New York, NY" stay separate; add an alias table if that matters.
    public static func city(_ location: String) -> String {
        if Text.norm(location).split(separator: " ").contains("remote") { return "Remote" }
        let c = location.split(whereSeparator: { ",;|/(".contains($0) }).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return c.isEmpty ? "Unknown" : c
    }

    /// Postings grouped by city, most postings first (ties by name).
    public static func byCity(_ pool: [Job], top: Int = 3, lexicon: SkillLexicon = .bundled) -> [Slice] {
        Dictionary(grouping: pool, by: { city($0.location) }).map { name, jobs in
            Slice(name: name, jobIds: jobs.map(\.id).sorted(), top: Array(demand(jobs, lexicon).prefix(top)))
        }.sorted { ($0.postings, $1.name) > ($1.postings, $0.name) }
    }

    /// Skill share in the last `windowDays` vs the window before, dated by `posted`, else `firstSeen`.
    public static func trending(_ pool: [Job], now: Date = Date(), limit: Int = 5, lexicon: SkillLexicon = .bundled) -> Trends {
        let day = 86_400.0, cut = now.addingTimeInterval(-Double(windowDays) * day), start = now.addingTimeInterval(-2 * Double(windowDays) * day)
        func date(_ j: Job) -> Date? { Dates.day(j.posted) ?? Dates.day(j.firstSeen) }
        let recent = pool.filter { date($0).map { $0 >= cut && $0 <= now } ?? false }
        let prior = pool.filter { date($0).map { $0 >= start && $0 < cut } ?? false }
        let enough = recent.count >= minPostings && prior.count >= minPostings
        guard enough else { return Trends(recentPostings: recent.count, priorPostings: prior.count, rising: [], falling: [], enough: false) }
        let r = Dictionary(uniqueKeysWithValues: demand(recent, lexicon).map { ($0.id, $0) })
        let p = Dictionary(uniqueKeysWithValues: demand(prior, lexicon).map { ($0.id, $0) })
        let all = Set(r.keys).union(p.keys).compactMap { id -> Trend? in
            guard let base = r[id] ?? p[id] else { return nil }
            let rc = r[id]?.count ?? 0, pc = p[id]?.count ?? 0
            var d = base; d.count = rc + pc; d.jobIds = (r[id]?.jobIds ?? []) + (p[id]?.jobIds ?? [])
            return Trend(demand: d, recent: rc, prior: pc, recentShare: Double(rc) / Double(recent.count), priorShare: Double(pc) / Double(prior.count))
        }
        let rising = all.filter { $0.change > 0 }.sorted { ($0.change, $1.demand.name) > ($1.change, $0.demand.name) }
        let falling = all.filter { $0.change < 0 }.sorted { ($0.change, $0.demand.name) < ($1.change, $1.demand.name) }
        return Trends(recentPostings: recent.count, priorPostings: prior.count, rising: Array(rising.prefix(limit)), falling: Array(falling.prefix(limit)), enough: true)
    }

    /// MarketScan's skill counting over an already-chosen set of postings.
    static func demand(_ jobs: [Job], _ lexicon: SkillLexicon) -> [SkillDemand] {
        var hits: [String: [String]] = [:]
        for j in jobs.sorted(by: { $0.id < $1.id }) { for id in lexicon.matches("\(j.title)\n\(j.description)") { hits[id, default: []].append(j.id) } }
        return hits.compactMap { id, ids -> SkillDemand? in
            guard let e = lexicon.entry(id) else { return nil }
            return SkillDemand(id: id, name: e.name, kind: e.kind, weight: e.weight, count: ids.count, jobIds: ids)
        }.sorted { ($0.count, $0.weight, $1.name) > ($1.count, $1.weight, $0.name) }
    }
}
