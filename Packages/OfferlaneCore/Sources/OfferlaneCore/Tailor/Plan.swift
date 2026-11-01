import Foundation

/// What one tailoring call returns, and what the review screen edits.
public struct TailorPlan: Codable, Hashable, Sendable {
    @LenientArray public var keywords: [String]
    @Lenient public var headline: String
    @Lenient public var summary: String
    public var order: [String: [String]] = [:]
    public var rewrites: [String: String] = [:]
    @LenientArray public var skillsOrder: [String]
    @Lenient public var coverLetter: String
    @Lenient public var whyCompany: String
    @LenientArray public var answers: [QA]
    @Lenient public var changesSummary: String
    public var variant: String?
    public init() {}

    public struct QA: Codable, Hashable, Sendable { @Lenient public var q: String; @Lenient public var a: String
        public init(q: String, a: String) { self.q = q; self.a = a } }

    enum CodingKeys: String, CodingKey { case keywords, headline, summary, order, rewrites, skillsOrder, coverLetter, whyCompany, answers, changesSummary, variant }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _keywords = try c.decode(LenientArray<String>.self, forKey: .keywords)
        _headline = try c.decode(Lenient.self, forKey: .headline); _summary = try c.decode(Lenient.self, forKey: .summary)
        order = (try? c.decodeIfPresent([String: [String]].self, forKey: .order)) ?? [:]
        rewrites = (try? c.decodeIfPresent([String: String].self, forKey: .rewrites)) ?? [:]
        _skillsOrder = try c.decode(LenientArray<String>.self, forKey: .skillsOrder)
        _coverLetter = try c.decode(Lenient.self, forKey: .coverLetter); _whyCompany = try c.decode(Lenient.self, forKey: .whyCompany)
        _answers = try c.decode(LenientArray<QA>.self, forKey: .answers); _changesSummary = try c.decode(Lenient.self, forKey: .changesSummary)
        variant = try? c.decodeIfPresent(String.self, forKey: .variant)
    }
}

/// The no-fabrication guard, enforced in code: a rewrite with a number that isn't in the source is rejected;
/// new capitalised terms or tools are flagged for review. Ported from resume.guard.
public enum Guard {
    static func nums(_ s: String) -> Set<String> { Set(Re.findAll("\\d+(?:[.,]\\d+)?", s).map { $0.replacingOccurrences(of: ",", with: "") }) }

    public static func check(_ new: String, source: String) -> (ok: Bool, warnings: [String]) {
        let bad = nums(new).subtracting(nums(source))
        if !bad.isEmpty { return (false, ["numbers not in your resume: \(bad.sorted())"]) }
        let vocab = Set(Re.findAll("[a-z0-9+#]+", source.lowercased()))
        let caps = Re.findAll("\\b([A-Z][A-Za-z0-9+#.]{1,}|[A-Za-z]+[0-9][A-Za-z0-9]*)\\b", new)
        let fresh = Set(caps.dropFirst().filter { !vocab.contains($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) }).sorted()
        return (true, fresh.isEmpty ? [] : ["new terms, check they are true: \(fresh)"])
    }
}

/// Everything the review screen needs.
public struct ReviewData: Codable, Hashable, Sendable {
    public struct Bullet: Codable, Hashable, Sendable, Identifiable {
        public var id: String; public var text: String; public var original: String
        public init(id: String, text: String, original: String) { self.id = id; self.text = text; self.original = original }
    }
    public struct Group: Codable, Hashable, Sendable, Identifiable {
        public var id: String { g }
        public var g: String; public var title: String; public var moved: [String]; public var bullets: [Bullet]
    }
    public struct Unused: Codable, Hashable, Sendable, Identifiable {
        public var id: String; public var text: String; public var group: String
        public init(id: String, text: String, group: String) { self.id = id; self.text = text; self.group = group }
    }
    public var variant: String
    public var headline: String, summary: String, headlineOriginal: String, summaryOriginal: String
    public var groups: [Group]
    public var unused: [Unused]
    public var warnings: [String]
}

public enum PlanApplier {
    /// The text the guard compares against: the resume's extracted source, or the structured bank.
    public static func source(_ v: ResumeVersion) -> String {
        if !v.sourceText.isEmpty { return v.sourceText }
        return v.content.sections.flatMap { $0.bullets.map(\.text) }.joined(separator: "\n") + "\n" + v.content.headline + "\n" + v.content.summary
    }

    /// Token-lean bullet bank for prompts (ids + text).
    public static func compact(_ v: ResumeVersion) -> String {
        let r = v.content
        var out = ["HEADLINE: \(r.headline)", "SUMMARY: \(r.summary)"]
        for sec in r.sections {
            let who = sec.company.isEmpty ? sec.name : sec.company
            out.append("[\(sec.id)] \(sec.title)" + (who.isEmpty ? "" : " @ \(who)") + (sec.dates.isEmpty ? "" : " (\(sec.dates))"))
            out += sec.bullets.map { "  \($0.id): \($0.text)" }
        }
        if !r.skills.isEmpty { out.append("SKILLS: " + r.skills.map { "\($0.label): \($0.items)" }.joined(separator: "; ")) }
        return out.joined(separator: "\n")
    }

    public static func apply(_ plan: TailorPlan, to v: ResumeVersion) -> (ResumeContent, [String]) {
        var r = v.content; var warns: [String] = []
        let src = source(v)
        for (key, value) in [("headline", plan.headline), ("summary", plan.summary)] {
            let val = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let cur = key == "headline" ? r.headline : r.summary
            guard !val.isEmpty, val != cur else { continue }
            let (ok, w) = Guard.check(val, source: src)
            if ok { if key == "headline" { r.headline = val } else { r.summary = val }; warns += w.map { "\(key): \($0)" } }
            else { warns.append("\(key) REJECTED, kept original: \(w[0])") }
        }
        func fix(_ secs: [ResumeContent.Section]) -> [ResumeContent.Section] {
            secs.map { sec in
                var sec = sec
                let byID = Dictionary(sec.bullets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let ids = (plan.order[sec.id] ?? sec.bullets.map(\.id)).filter { byID[$0] != nil }
                sec.bullets = ids.map { id in
                    var b = byID[id]!; b.original = b.text
                    if let new = plan.rewrites[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !new.isEmpty, new != b.text {
                        let (ok, w) = Guard.check(new, source: b.text + " " + src)
                        if ok { b.text = new; warns += w.map { "\(id): \($0)" } } else { warns.append("\(id) REJECTED, kept original: \(w[0])") }
                    }
                    return b
                }
                return sec
            }
        }
        r.experience = fix(r.experience); r.projects = fix(r.projects)
        if !plan.skillsOrder.isEmpty {
            let pos = Dictionary(plan.skillsOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
            r.skills = r.skills.enumerated().sorted { (pos[$0.element.label] ?? 99, $0.offset) < (pos[$1.element.label] ?? 99, $1.offset) }.map(\.element)
        }
        return (r, warns)
    }

    public static func review(_ plan: TailorPlan, _ v: ResumeVersion) -> ReviewData {
        let (c, warns) = apply(plan, to: v), base = v.content
        var groups: [ReviewData.Group] = [], unused: [ReviewData.Unused] = []
        for (sec, orig) in zip(c.sections, base.sections) {
            let used = sec.bullets.map(\.id), origIDs = orig.bullets.map(\.id)
            let moved = used.enumerated().filter { n, u in n < origIDs.count && origIDs.firstIndex(of: u) != n }.map(\.element)
            groups.append(.init(g: sec.id, title: sec.heading, moved: Array(moved.prefix(20)),
                                bullets: sec.bullets.map { .init(id: $0.id, text: $0.text, original: $0.original ?? $0.text) }))
            unused += orig.bullets.filter { !used.contains($0.id) }.map { .init(id: $0.id, text: $0.text, group: sec.id) }
        }
        return ReviewData(variant: v.name, headline: c.headline, summary: c.summary, headlineOriginal: base.headline, summaryOriginal: base.summary,
                          groups: groups, unused: unused, warnings: warns)
    }

    /// The review screen's edits become a plan again (no AI call; the guard still applies on rebuild).
    public static func plan(from e: ReviewData, old: TailorPlan, _ v: ResumeVersion) -> TailorPlan {
        var p = old
        let orig = Dictionary(v.content.sections.flatMap { $0.bullets.map { ($0.id, $0.text) } }, uniquingKeysWith: { a, _ in a })
        p.headline = e.headline; p.summary = e.summary
        p.order = Dictionary(e.groups.map { ($0.g, $0.bullets.map(\.id)) }, uniquingKeysWith: { a, _ in a })
        p.rewrites = Dictionary(e.groups.flatMap { g in g.bullets.filter { $0.text.trimmingCharacters(in: .whitespaces) != orig[$0.id] }.map { ($0.id, $0.text) } },
                                uniquingKeysWith: { a, _ in a })
        return p
    }
}
