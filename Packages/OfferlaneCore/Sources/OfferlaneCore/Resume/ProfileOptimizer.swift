import Foundation

/// A check on the user's profile links or pasted LinkedIn text. `cites` are resume ids (section, bullet, "links", "skills").
public struct ProfileFinding: Hashable, Sendable, Identifiable {
    public var text: String
    public var cites: [String]
    public var id: String { text }
}

public struct ProfileSuggestion: Hashable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Sendable { case headline, about, skills, portfolio }
    public var kind: Kind
    public var title: String
    public var text: String
    /// Resume ids this suggestion is built from; never empty.
    public var cites: [String]
    public var id: String { kind.rawValue + title }
}

public struct ProfileAdvice: Hashable, Sendable {
    public var suggestions: [ProfileSuggestion]
    /// New capitalised terms the AI used: shown so the user checks they are true.
    public var warnings: [String] = []
    /// Plain-language note when the AI wasn't used or some of its suggestions were dropped.
    public var note: String?
}

/// LinkedIn and portfolio suggestions built only from the resume. Nothing is fetched from LinkedIn and nothing is written anywhere: Copy is the output.
public enum ProfileOptimizer {
    // shortcut: LinkedIn's field limits as of 2026-11, update if LinkedIn changes them.
    public static let headlineMax = 220, aboutMax = 2600

    // MARK: Checks (no AI)

    public static func checks(resume r: ResumeContent, links: [String: String], pasted: String = "") -> [ProfileFinding] {
        var out: [ProfileFinding] = []
        func link(_ key: String, _ name: String, host: String?, path: String?) {
            let raw = (links[key] ?? "").trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return out.append(.init(text: "No \(name) link on your resume or profile. Add one so recruiters can find it.", cites: ["links"])) }
            guard let u = URLComponents(string: raw.contains("://") ? raw : "https://" + raw), let h = u.host?.lowercased(), h.contains(".") else {
                return out.append(.init(text: "Your \(name) link doesn't look like a web address: \(raw)", cites: ["links"]))
            }
            if u.scheme?.lowercased() == "http" { out.append(.init(text: "Your \(name) link uses http. Use https.", cites: ["links"])) }
            if let host, h != host, !h.hasSuffix("." + host) { out.append(.init(text: "Your \(name) link isn't on \(host): \(raw)", cites: ["links"])) }
            if let path, !u.path.lowercased().hasPrefix(path) || u.path.count <= path.count {
                out.append(.init(text: "Your \(name) link should point to your own profile (\(host ?? "")\(path)your-name).", cites: ["links"]))
            }
            if !(u.query ?? "").isEmpty { out.append(.init(text: "Remove the tracking part after \"?\" from your \(name) link.", cites: ["links"])) }
        }
        link("linkedin", "LinkedIn", host: "linkedin.com", path: "/in/")
        link("github", "GitHub", host: "github.com", path: "/")
        link("portfolio", "portfolio", host: nil, path: nil)

        let text = Text.norm(pasted)
        guard !text.isEmpty else { return out }
        let has = { (s: String) in let n = Text.norm(s); return n.isEmpty || " \(text) ".contains(" \(n) ") }
        for s in r.experience {
            if !has(s.company) { out.append(.init(text: "Your LinkedIn text doesn't mention \(s.company).", cites: [s.id])) }
            if !has(s.title) { out.append(.init(text: "Your LinkedIn text doesn't mention your title \"\(s.title)\".", cites: [s.id])) }
        }
        let missing = skills(r).filter { !has($0) }
        if !missing.isEmpty { out.append(.init(text: "Skills on your resume your LinkedIn text doesn't mention: " + missing.joined(separator: ", "), cites: ["skills"])) }
        return out
    }

    static func skills(_ r: ResumeContent) -> [String] {
        let all = r.topSkills + r.skills.flatMap { $0.items.split(whereSeparator: { ",;|".contains($0) }).map(String.init) }
        return Array(Networking.unique(all).prefix(10))
    }

    // MARK: Suggestions

    /// Ids a suggestion may cite.
    static func ids(_ r: ResumeContent) -> Set<String> {
        Set(r.sections.flatMap { [$0.id] + $0.bullets.map(\.id) } + ["headline", "summary", "skills", "links"])
    }

    /// The resume text a cited id stands for, for the UI.
    public static func citeText(_ id: String, resume r: ResumeContent) -> String {
        switch id {
        case "headline": return r.headline
        case "summary": return r.summary
        case "skills": return skills(r).joined(separator: ", ")
        case "links": return "Links on your resume"
        default:
            for s in r.sections {
                if s.id == id { return s.heading }
                if let b = s.bullets.first(where: { $0.id == id }) { return b.text }
            }
            return id
        }
    }

    static func source(_ r: ResumeContent) -> String {
        PlanApplier.compact(r) + "\n" + r.education.map { "\($0.degree) \($0.school)" }.joined(separator: "\n") + "\n" + r.certifications.joined(separator: "\n")
    }

    /// One cached AI call per resume and role. Each item must cite real resume ids and pass the number guard; anything else is replaced by the template's item.
    public static func suggest(resume r: ResumeContent, role: String, ai: AI?) async -> ProfileAdvice {
        let fallback = template(r)
        guard let ai else { return ProfileAdvice(suggestions: fallback, note: "No AI is connected, so these come straight from your resume. Connect an AI for rewritten suggestions.") }
        let source = source(r)
        let prompt = """
        Suggest LinkedIn profile text for a job seeker\(role.isEmpty ? "" : " targeting \(role) roles"). Use ONLY facts in the RESUME; never add numbers, employers, tools, links or outcomes.
        Every item cites the resume ids (section or bullet ids in [brackets] or before ":") it uses.
        Return JSON {"headline":{"text":"...","cites":["id"]},"about":{"text":"...","cites":["id"]},"skills":{"items":["..."],"cites":["id"]},"portfolio":[{"title":"...","text":"...","cites":["id"]}]}.
        Headline under \(headlineMax) characters. About under \(aboutMax) characters, first person. Up to 10 skills, each named in the resume. Up to 3 portfolio items worth showcasing.
        RESUME:
        \(source)
        """
        struct Item: Decodable { var title: String?; var text: String?; var items: [String]?; var cites: [String]? }
        struct D: Decodable { var headline: Item?; var about: Item?; var skills: Item?; var portfolio: [Item]? }
        do {
            let d = try await ai.cachedJSON(LLMRequest(prompt: prompt, maxTokens: 1200), key: ai.cacheKey("profile-v1", [role, source]), kind: "profile", as: D.self)
            let valid = ids(r), vocab = Text.norm(source)
            var warnings: [String] = []
            func accept(_ kind: ProfileSuggestion.Kind, _ i: Item?, title: String, max: Int = .max) -> ProfileSuggestion? {
                guard let i else { return nil }
                var text = (i.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if kind == .skills {
                    let items = Networking.unique(i.items ?? []).prefix(10)
                    guard items.allSatisfy({ " \(vocab) ".contains(" \(Text.norm($0)) ") }) else { return nil }
                    text = items.joined(separator: ", ")
                }
                let cites = Networking.unique(i.cites ?? []), g = Guard.check(text, source: source)
                guard !text.isEmpty, !cites.isEmpty, cites.allSatisfy(valid.contains), g.ok, text.count <= max, SkillPlanner.noLinks(text) else { return nil }
                warnings += g.warnings
                return ProfileSuggestion(kind: kind, title: Text.collapse(i.title ?? "").isEmpty ? title : Text.collapse(i.title!), text: text, cites: cites)
            }
            let given: [(ProfileSuggestion.Kind, Item?, String, Int)] = [(.headline, d.headline, "Headline", headlineMax), (.about, d.about, "About", aboutMax),
                (.skills, d.skills, "Featured skills", .max)] + (d.portfolio ?? []).prefix(3).map { (.portfolio, $0, "Project", .max) }
            let tried = given.filter { $0.1 != nil }
            let got = tried.compactMap { accept($0.0, $0.1, title: $0.2, max: $0.3) }, dropped = tried.count - got.count
            let merged = ProfileSuggestion.Kind.allCases.flatMap { k in
                let mine = got.filter { $0.kind == k }
                return mine.isEmpty ? fallback.filter { $0.kind == k } : mine
            }
            let note = dropped == 0 ? nil : "\(dropped) AI suggestion\(dropped == 1 ? "" : "s") added facts your resume doesn't have or cited nothing, so \(dropped == 1 ? "it was" : "they were") replaced with text from your resume."
            return ProfileAdvice(suggestions: merged, warnings: Networking.unique(warnings), note: note)
        } catch {
            return ProfileAdvice(suggestions: fallback, note: "The AI couldn't make suggestions (\(error.localizedDescription)). These come straight from your resume.")
        }
    }

    /// Verbatim resume text, so it can't add a fact.
    public static func template(_ r: ResumeContent) -> [ProfileSuggestion] {
        var out: [ProfileSuggestion] = []
        let first = r.experience.first, top = skills(r)
        if !r.headline.isEmpty {
            out.append(.init(kind: .headline, title: "Headline", text: String(r.headline.prefix(headlineMax)), cites: ["headline"]))
        } else if let first, !first.title.isEmpty {
            let text = ([first.title] + top.prefix(3)).joined(separator: " | ")
            out.append(.init(kind: .headline, title: "Headline", text: String(text.prefix(headlineMax)), cites: [first.id] + (top.isEmpty ? [] : ["skills"])))
        }
        if !r.summary.isEmpty {
            out.append(.init(kind: .about, title: "About", text: String(r.summary.prefix(aboutMax)), cites: ["summary"]))
        } else {
            let bullets = r.experience.flatMap(\.bullets).prefix(3)
            if !bullets.isEmpty { out.append(.init(kind: .about, title: "About", text: bullets.map(\.text).joined(separator: " "), cites: bullets.map(\.id))) }
        }
        if !top.isEmpty { out.append(.init(kind: .skills, title: "Featured skills", text: top.joined(separator: ", "), cites: ["skills"])) }
        let showcase = r.projects.filter { !$0.bullets.isEmpty }.map { ($0.heading, $0.bullets[0], $0.id) }
            + r.experience.flatMap { s in s.bullets.filter { Re.search("\\d", $0.text) }.map { (s.heading, $0, s.id) } }
        for (title, b, sid) in showcase.prefix(3) { out.append(.init(kind: .portfolio, title: title, text: b.text, cites: [sid, b.id])) }
        return out
    }
}
