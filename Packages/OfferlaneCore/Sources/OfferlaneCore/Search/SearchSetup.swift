import Foundation

/// The candidate brief shared by search setup, scoring and tailoring (ported from rank.candidate_brief).
public enum Brief {
    /// `private: false` (tailoring) leaves out current pay and personal notes: tailored text goes to employers, and a
    /// job posting could try to talk the AI into repeating them there.
    public static func candidate(resume r: ResumeContent, versions: [ResumeVersion], profile p: Profile, search s: SearchConfig, includePrivate: Bool = true) -> String {
        let w = p.work, a = p.authorization
        let exp = r.experience.prefix(5).map { $0.title + ($0.company.isEmpty ? "" : " @ \($0.company)") }.joined(separator: "; ")
        let vtxt = versions.count > 1 ? "\nResume versions: " + versions.map { "\($0.name) = \($0.label)" }.joined(separator: "; ") : ""
        let years = w.yearsExperience.isEmpty ? r.yearsExperience : w.yearsExperience
        return """
        CANDIDATE: \(r.headline). \(years) yrs. Current: \(w.currentTitle) at \(w.currentCompany).
        Experience: \(exp)
        Skills: \(r.topSkills.joined(separator: ", "))
        Targets: \(s.targetTitles.joined(separator: ", "))\(s.aspirations.isEmpty ? "" : "\nAspirations (stretch): " + s.aspirations.joined(separator: ", "))
        Locations: \(s.locations.prefix(20).joined(separator: ", ")); remote ok: \(s.remoteOk). Authorized to work in: \(a.authorizedCountries.joined(separator: ", ")); needs sponsorship elsewhere: \(a.needsSponsorship).
        \(includePrivate ? "Pay: current \(w.currentSalary.isEmpty ? "?" : w.currentSalary), target \(w.expectedSalary.isEmpty ? "?" : w.expectedSalary).\n" : "")\
        Deal-breakers / must-haves: \(p.prefs.dealbreakers.isEmpty ? "none" : p.prefs.dealbreakers).\(includePrivate ? " Notes: \(p.prefs.notes)" : "")\(vtxt)
        """
    }
}

/// One AI call at onboarding drafts the search: title filters, phrases and a watchlist of companies (a ranking boost, not a filter).
public struct SearchSetup: Sendable {
    public let ai: AI
    public init(ai: AI) { self.ai = ai }

    public static let prompt = """
    Build a job-search configuration for this candidate. Return JSON:
    {"title_include":["8-20 lowercase title phrases that a relevant posting title contains, e.g. 'data scientist','ml engineer'"],
    "title_exclude":["lowercase words that mark irrelevant titles: wrong seniority, unrelated functions"],
    "queries":["6-10 search phrases"],
    "companies":[{"name":"","slug":"best guess of the careers-board slug, lowercase"}]}
    Companies: 40-60 employers that hire this profile in the candidate's locations; include large companies (many use Workday) and
    strong growth-stage ones (often Greenhouse, Lever, Ashby).
    """

    struct Draft: Decodable {
        @LenientArray var titleInclude: [String]
        @LenientArray var titleExclude: [String]
        @LenientArray var queries: [String]
        @LenientArray var companies: [SearchConfig.Company]
    }

    static func brief(_ s: SearchConfig, resume: ResumeContent, versions: [ResumeVersion], profile: Profile) -> String {
        Brief.candidate(resume: resume, versions: versions, profile: profile, search: s)
            + "\nTarget titles: \(s.targetTitles.joined(separator: ", "))\nLocations: \(s.locations.joined(separator: ", ")) (remote ok: \(s.remoteOk))"
    }

    /// Returns `search` with the AI's draft merged in (target titles are always included).
    public func draft(_ search: SearchConfig, resume: ResumeContent, versions: [ResumeVersion], profile: Profile) async throws -> SearchConfig {
        var s = search
        if s.targetTitles.isEmpty { s.targetTitles = Array(resume.suggestedTitles.prefix(6)) }
        let brief = Self.brief(s, resume: resume, versions: versions, profile: profile)
        let d: Draft = try await ai.cachedJSON(LLMRequest(prompt: Self.prompt, cache: brief, smart: true, maxTokens: 3500),
                                               key: ai.cacheKey("setup-v1", [Hash.sha256(brief)], smart: true), kind: "setup")
        s.titleInclude = Array(Set((d.titleInclude + s.targetTitles).map { $0.lowercased() })).sorted()
        s.titleExclude = d.titleExclude.map { $0.lowercased() }
        s.queries = d.queries
        var seen = Set(s.companies.map { $0.name.lowercased() })
        for c in d.companies where !c.name.isEmpty && seen.insert(c.name.lowercased()).inserted { s.companies.append(c) }
        s.companies = Careers.attachWorkday(s.companies)
        return s
    }
}
