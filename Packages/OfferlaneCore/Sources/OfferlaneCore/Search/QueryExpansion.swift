import Foundation

/// One keyword search against a job source: what to look for, and where (nil = remote / anywhere).
public struct SearchQuery: Sendable, Hashable {
    public var what: String
    public var `where`: String?
    public init(_ what: String, where w: String? = nil) { self.what = what; self.where = w }
}

/// Turns the profile into a bounded set of searches, with no AI call: target and aspiration titles, the drafted phrases,
/// suggested (adjacent) titles, seniority variants and skill keywords, each per location plus remote.
public enum QueryExpansion {
    static let seniority = ["senior", "staff", "lead", "principal", "junior", "associate", "head of", "sr"]

    /// The title phrases, most important first, de-duplicated, at most `limit`.
    public static func phrases(search s: SearchConfig, resume r: ResumeContent?, limit: Int = 10) -> [String] {
        let titles = s.targetTitles + s.aspirations + s.queries + (r?.suggestedTitles ?? [])
        // A seniority variant of the first target widens the net one step up and down.
        let base = s.targetTitles.first.map(stripSeniority)
        let variants = base.map { ["senior \($0)", "lead \($0)", $0] } ?? []
        // The top skill alone as a keyword finds roles whose titles we didn't guess.
        let skills = (r?.topSkills ?? s.boostKeywords).prefix(2).map { $0.lowercased() }
        var seen = Set<String>(), out: [String] = []
        for p in titles + variants + skills {
            let p = p.trimmingCharacters(in: .whitespaces).lowercased()
            if !p.isEmpty, seen.insert(Text.norm(p)).inserted { out.append(p) }
        }
        return Array(out.prefix(limit))
    }

    /// `phrases` × (each location, plus remote when allowed). Capped so a run's request count stays small and constant.
    public static func queries(search s: SearchConfig, resume r: ResumeContent?, maxQueries: Int = 24) -> [SearchQuery] {
        let places: [String?] = Array(s.locations.prefix(3)).map { Optional($0) } + (s.remoteOk || s.locations.isEmpty ? [nil] : [])
        var out: [SearchQuery] = []
        for p in phrases(search: s, resume: r) { for w in places { out.append(SearchQuery(p, where: w)) } }
        return Array(out.prefix(maxQueries))
    }

    static func stripSeniority(_ t: String) -> String {
        var t = t.lowercased().trimmingCharacters(in: .whitespaces)
        for s in seniority where t.hasPrefix(s + " ") { t = String(t.dropFirst(s.count + 1)) }
        return t
    }
}
