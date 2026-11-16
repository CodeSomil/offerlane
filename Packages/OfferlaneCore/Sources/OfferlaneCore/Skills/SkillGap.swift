import Foundation

/// Skills, tools and certifications the market scan looks for (Resources/skills.json). Matching is local and free: no AI call.
public struct SkillLexicon: Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        /// skill, tool or cert
        public var kind: String
        /// 3 core, 2 strong signal, 1 supporting.
        public var weight: Int
        public var aliases: [String]
        public init(id: String, name: String, kind: String = "skill", weight: Int = 2, aliases: [String]) {
            self.id = id; self.name = name; self.kind = kind; self.weight = weight; self.aliases = aliases
        }
    }
    public let entries: [Entry]
    private let needles: [(String, [String])]

    public init(_ entries: [Entry]) {
        self.entries = entries
        needles = entries.map { e in (e.id, (e.aliases + [e.name]).map { " \(Text.norm($0)) " }.filter { $0.count > 2 }) }
    }

    public static let bundled: SkillLexicon = {
        struct File: Decodable { var skills: [Entry] }
        guard let url = Bundle.module.url(forResource: "Resources/skills", withExtension: "json"),
              let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) else { return SkillLexicon([]) }
        return SkillLexicon(f.skills)
    }()

    /// Ids of every entry named in `text` (whole words, case and punctuation ignored).
    public func matches(_ text: String) -> Set<String> {
        let t = " \(Text.norm(text)) "
        return Set(needles.filter { $0.1.contains { t.contains($0) } }.map(\.0))
    }
    public func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }
}

/// How often employers hiring for a role ask for one skill, with the postings that ask.
public struct SkillDemand: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String
    public var weight: Int
    public var count: Int
    public var jobIds: [String]
}

public struct MarketScan: Codable, Hashable, Sendable {
    public var role: String
    public var jobIds: [String]
    public var demand: [SkillDemand]
    public var postings: Int { jobIds.count }

    static let stop: Set<String> = ["of", "and", "the", "for", "a", "an", "in", "at", "to", "senior", "sr", "jr", "junior", "i", "ii", "iii"]
    static func tokens(_ s: String) -> Set<String> {
        Set(Text.norm(s).split(separator: " ").map(String.init).filter { !stop.contains($0) }.map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
    }

    /// Postings for `role`: at least half of the role's words appear in the job's title or location.
    public static func relevant(_ jobs: [Job], role: String) -> [Job] {
        let want = tokens(role)
        guard !want.isEmpty else { return [] }
        let need = (want.count + 1) / 2
        return jobs.filter { want.intersection(tokens("\($0.title) \($0.location)")).count >= need }.sorted { $0.id < $1.id }
    }

    public static func scan(_ jobs: [Job], role: String, lexicon: SkillLexicon = .bundled) -> MarketScan {
        let pool = relevant(jobs, role: role)
        let demand = MarketIntel.demand(pool, lexicon)
        return MarketScan(role: role, jobIds: pool.map(\.id), demand: demand)
    }
}

/// One skill in the gap report: whether the resume shows it and how much it weighs in readiness.
public struct GapItem: Codable, Hashable, Sendable, Identifiable {
    public var demand: SkillDemand
    public var have: Bool
    /// Share of the role's postings that ask for it (0...1).
    public var share: Double
    /// share × weight: the ranking key and this item's slice of readiness.
    public var score: Double
    public var id: String { demand.id }
}

public struct GapReport: Codable, Hashable, Sendable {
    public var role: String
    public var postings: Int
    /// Covered score ÷ total score, 0...100. Every term is in `items`, so the number can be explained line by line.
    public var readiness: Int
    /// Ranked, most important first.
    public var items: [GapItem]
    public var gaps: [GapItem] { items.filter { !$0.have } }

    /// Everything the resume says, for skill matching.
    public static func resumeText(_ r: ResumeContent) -> String {
        ([r.headline, r.summary] + r.skills.map { "\($0.label): \($0.items)" } + r.topSkills + r.certifications + r.extras
         + r.sections.flatMap { [$0.heading] + $0.bullets.map(\.text) } + r.education.map { "\($0.degree) \($0.details)" }).joined(separator: "\n")
    }

    /// `alsoHave`: lexicon ids the user marked as known (or finished learning) that the resume does not show yet.
    public static func analyse(_ scan: MarketScan, resume: ResumeContent?, alsoHave: Set<String> = [], lexicon: SkillLexicon = .bundled) -> GapReport {
        let have = alsoHave.union(resume.map { lexicon.matches(resumeText($0)) } ?? [])
        let n = Double(max(scan.postings, 1))
        let items = scan.demand.map { d -> GapItem in
            let share = Double(d.count) / n
            return GapItem(demand: d, have: have.contains(d.id), share: share, score: share * Double(d.weight))
        }.sorted { ($0.score, $1.demand.name) > ($1.score, $0.demand.name) }
        let total = items.reduce(0) { $0 + $1.score }, covered = items.filter(\.have).reduce(0) { $0 + $1.score }
        return GapReport(role: scan.role, postings: scan.postings, readiness: total > 0 ? Int((covered / total * 100).rounded()) : 0, items: items)
    }
}
