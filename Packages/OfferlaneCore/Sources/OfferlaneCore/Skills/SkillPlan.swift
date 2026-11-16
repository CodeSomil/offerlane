import Foundation

/// What the user chose and finished on the Skill gaps screen (Store key .skillPlan).
public struct SkillPlanState: Codable, Hashable, Sendable {
    /// Roles to plan for; empty means "use my aspirations, else my target titles".
    public var roles: [String] = []
    public var hoursPerWeek: Int = 5
    /// Lexicon ids the user says they already have.
    public var known: [String] = []
    /// Catalog id → day marked done.
    public var done: [String: String] = [:]
    /// Catalog id → certification line this app added to the resume (removed again on undo).
    public var addedCerts: [String: String] = [:]
    /// Role chosen on the Goals screen (also first in `roles`) and how many years out.
    public var goal: String?
    public var goalYears: Int?
    public init() {}
}

public struct LearningPlan: Codable, Hashable, Sendable {
    public struct Step: Codable, Hashable, Sendable, Identifiable {
        public var item: CatalogItem
        public var why: String
        public var week: Int
        /// Most postings asking for any skill this resource teaches.
        public var askedBy: Int
        public var id: String { item.id }
    }
    public var role: String
    public var postings: Int
    public var steps: [Step]
    public var projects: [String]
    /// Candidates hidden because their link did not verify.
    public var hidden: Int
    /// No link answered at all: most likely offline.
    public var offline: Bool
}

public enum SkillPlanner {
    public static func roles(_ state: SkillPlanState, _ search: SearchConfig) -> [String] {
        [state.roles, search.aspirations, search.targetTitles].first { !$0.isEmpty } ?? []
    }

    /// Gap report from every stored posting and the default resume; known skills and finished resources count as covered.
    public static func report(store: Store, role: String, lexicon: SkillLexicon = .bundled, catalog: [CatalogItem] = LearningCatalog.bundled) throws -> GapReport {
        try report(jobs: store.jobs(), resume: store.resume()?.content, state: store.get(.skillPlan) ?? SkillPlanState(), role: role, lexicon: lexicon, catalog: catalog)
    }

    /// Same report from already-loaded data, for callers that score many roles at once.
    static func report(jobs: [Job], resume: ResumeContent?, state: SkillPlanState, role: String, lexicon: SkillLexicon = .bundled, catalog: [CatalogItem] = LearningCatalog.bundled) -> GapReport {
        let learned = catalog.filter { state.done[$0.id] != nil }.flatMap(\.skills)
        return GapReport.analyse(MarketScan.scan(jobs, role: role, lexicon: lexicon), resume: resume, alsoHave: Set(state.known + learned), lexicon: lexicon)
    }

    struct Picks: Decodable {
        struct Pick: Decodable { var id: String; var why: String? }
        var picks: [Pick]
        var projects: [String]?
    }

    static func noLinks(_ s: String) -> Bool { !Re.search("https?://|www\\.|\\.(com|org|io|net|ai|edu)\\b", s) }

    /// Keeps only picks that name a verified candidate; the model's text never carries a link.
    static func guarded(_ p: Picks, candidates: [CatalogItem]) -> [(CatalogItem, String)] {
        let byId = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        return p.picks.compactMap { pick in
            guard let c = byId[pick.id], seen.insert(pick.id).inserted else { return nil }
            let why = Text.collapse(pick.why ?? "")
            return (c, noLinks(why) && !why.isEmpty ? String(why.prefix(200)) : "")
        }
    }

    static let maxCandidates = 15, maxSteps = 8

    /// One AI call at most. Links are verified first and only verified resources reach the model; with no AI
    /// (or a bad answer) the deterministic free-first order is used.
    public static func plan(_ report: GapReport, state: SkillPlanState, ai: AI?, checker: LinkChecker, store: Store,
                            catalog: [CatalogItem] = LearningCatalog.bundled) async -> LearningPlan {
        let all = LearningCatalog.candidates(for: report.gaps, in: catalog).filter { state.done[$0.id] == nil }.prefix(maxCandidates)
        let checks = await checker.check(all.map(\.url), cache: (try? store.get(.linkChecks)) ?? [:])
        try? store.set(.linkChecks, checks)
        let live = all.filter { checks[$0.url]?.ok == true }
        let offline = !all.isEmpty && all.allSatisfy { checks[$0.url]?.status == 0 }

        var chosen: [(CatalogItem, String)] = [], projects: [String] = []
        if let ai, !live.isEmpty {
            let gaps = report.gaps.prefix(12).map { "- \($0.demand.name): \($0.demand.count) of \(report.postings) postings" }.joined(separator: "\n")
            let list = live.map { "[id=\($0.id)] \($0.title) (\($0.provider), \($0.access)) teaches: \($0.skills.joined(separator: ", "))" }.joined(separator: "\n")
            let prompt = """
            Choose learning resources for someone aiming at "\(report.role)". Use ONLY ids from the list. Free first unless a paid certificate is clearly worth it.
            Return JSON {"picks":[{"id":"...","why":"one short sentence"}],"projects":["2-3 portfolio project ideas, one sentence each"]}. No links, no new resources, no numbers you were not given.
            GAPS:
            \(gaps)
            RESOURCES:
            \(list)
            """
            let key = ai.cacheKey("skillplan-v1", [report.role, gaps, list])
            if let p = try? await ai.cachedJSON(LLMRequest(prompt: prompt, maxTokens: 900), key: key, kind: "skillplan", as: Picks.self) {
                chosen = guarded(p, candidates: Array(live))
                projects = (p.projects ?? []).map(Text.collapse).filter { !$0.isEmpty && noLinks($0) }.prefix(3).map { String($0.prefix(240)) }
            }
        }
        if chosen.isEmpty { chosen = live.map { ($0, "") } }
        if projects.isEmpty {
            projects = report.gaps.filter { $0.demand.kind != "cert" }.prefix(3).map { "Build and publish a small project that shows \($0.demand.name) (asked for in \($0.demand.count) of \(report.postings) postings)." }
        }

        let asked = Dictionary(report.items.map { ($0.id, $0.demand.count) }, uniquingKeysWith: max)
        let perWeek = Double(max(state.hoursPerWeek, 1))
        var hours = 0.0
        let steps = chosen.prefix(maxSteps).map { c, why -> LearningPlan.Step in
            let week = Int(hours / perWeek) + 1
            hours += c.hours ?? perWeek   // unlisted length: plan a week for it
            return .init(item: c, why: why, week: week, askedBy: c.skills.compactMap { asked[$0] }.max() ?? 0)
        }
        return LearningPlan(role: report.role, postings: report.postings, steps: steps, projects: projects, hidden: all.count - live.count, offline: offline)
    }

    /// Mark a resource done (or undo). Only a finished certificate is written to the default resume, and undo takes it out again.
    public static func setDone(_ item: CatalogItem, _ done: Bool, store: Store) throws {
        var state: SkillPlanState = try store.get(.skillPlan) ?? SkillPlanState()
        if done { state.done[item.id] = Dates.today() } else { state.done[item.id] = nil }
        if item.kind == "cert", var r = try store.resume() {
            if done, !r.content.certifications.contains(item.title) {
                r.content.certifications.append(item.title); state.addedCerts[item.id] = item.title; try store.saveResume(r)
            } else if !done, let line = state.addedCerts.removeValue(forKey: item.id) {
                r.content.certifications.removeAll { $0 == line }; try store.saveResume(r)
            }
        }
        try store.set(.skillPlan, state)
    }
}
