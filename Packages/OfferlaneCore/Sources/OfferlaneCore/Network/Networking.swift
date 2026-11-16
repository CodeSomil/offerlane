import Foundation

public enum OutreachKind: String, CaseIterable, Sendable, Identifiable {
    case referral, recruiter, manager, followUp
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .referral: "Referral ask"
        case .recruiter: "Recruiter note"
        case .manager: "Hiring manager note"
        case .followUp: "Follow-up"
        }
    }
}

/// A kind of person worth asking. Offerlane never looks people up; the user does.
public struct ReferralIdea: Hashable, Sendable, Identifiable {
    public var text: String
    public var kind: OutreachKind
    public var id: String { text }
}

public struct OutreachDraft: Hashable, Sendable {
    public var subject: String
    public var body: String
    /// Terms not found in the resume or posting: shown so the user checks they are true.
    public var warnings: [String] = []
    /// Plain-language note when the AI wasn't used (cause + what was done instead).
    public var note: String?
}

/// Referral ideas and outreach drafts. Drafts only: nothing here sends a message.
public enum Networking {
    public static let placeholder = "[Name]"

    public static func ideas(job: Job, resume: ResumeContent?) -> [ReferralIdea] {
        let target = Text.norm(job.company)
        let employers = unique((resume?.experience ?? []).map(\.company))
        var out: [ReferralIdea] = []
        if employers.contains(where: { Text.norm($0) == target }) {
            out.append(.init(text: "You worked at \(job.company) before: ask a former teammate there directly.", kind: .referral))
        }
        out += employers.filter { Text.norm($0) != target }.map { .init(text: "Former colleagues from \($0) who now work at \(job.company)", kind: .referral) }
        out += unique((resume?.education ?? []).map(\.school)).map { .init(text: "\($0) alumni who work at \(job.company)", kind: .referral) }
        out.append(.init(text: "The recruiter hiring for \(job.title) at \(job.company)", kind: .recruiter))
        out.append(.init(text: "The hiring manager or a future teammate on the \(job.title) team", kind: .manager))
        return out
    }

    /// Everything a draft may draw facts from.
    static func facts(job: Job, resume: ResumeContent?) -> String {
        var lines = ["ROLE: \(job.title) at \(job.company) \(job.location)"]
        if let r = resume {
            lines += [r.name, r.headline, r.summary].filter { !$0.isEmpty }
            lines += r.sections.prefix(6).flatMap { s in [s.heading] + s.bullets.prefix(5).map { "- \($0.text)" } }
            lines += r.education.map { "\($0.degree) \($0.school)" }
        }
        lines.append("POSTING: " + String(job.description.prefix(1500)))
        return lines.joined(separator: "\n")
    }

    /// One cached AI call per kind and role; anything with a number or link the sources lack, or a guessed name, falls back to a template.
    public static func draft(_ kind: OutreachKind, job: Job, resume: ResumeContent?, ai: AI?) async -> OutreachDraft {
        let fallback = template(kind, job: job, resume: resume)
        guard let ai else { return with(fallback, note: "No AI is connected, so this is a plain template. Edit it, or connect an AI.") }
        let source = facts(job: job, resume: resume)
        let prompt = """
        Draft an outreach message (\(kind.title.lowercased())) for a job seeker about the role below. Short, warm, specific; under 140 words.
        Use ONLY facts in the SOURCE; never add numbers, employers, tools, links or outcomes. Greet the person as "\(placeholder)" and sign with the candidate's name.
        Return JSON {"subject":"...","body":"..."}.
        SOURCE:
        \(source)
        """
        struct D: Decodable { var subject: String?; var body: String? }
        do {
            let d = try await ai.cachedJSON(LLMRequest(prompt: prompt, maxTokens: 500), key: ai.cacheKey("outreach-v1", [kind.rawValue, source]), kind: "outreach", as: D.self)
            let subject = Text.collapse(d.subject ?? ""), body = (d.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return with(fallback, note: "The AI returned an empty draft, so this is a plain template.") }
            let gs = Guard.check(subject, source: source), gb = Guard.check(body, source: source)
            guard gs.ok, gb.ok, SkillPlanner.noLinks(subject + " " + body), !guessesName(body) else {
                return with(fallback, note: "The AI's draft added facts your resume and the posting don't have, so this is a plain template.")
            }
            return OutreachDraft(subject: subject.isEmpty ? fallback.subject : subject, body: body, warnings: gs.warnings + gb.warnings)
        } catch {
            return with(fallback, note: "The AI couldn't draft this (\(error.localizedDescription)). Here is a plain template instead.")
        }
    }

    /// A greeting that names someone instead of the placeholder: the model can't know who the user is writing to.
    static func guessesName(_ body: String) -> Bool {
        Re.search("(?i)^\\s*(hi|hello|hey|dear)\\b(?!\\s*(\\[name\\]|there\\b|team\\b|all\\b))\\s*[a-z]", body)
    }

    public static func template(_ kind: OutreachKind, job: Job, resume: ResumeContent?) -> OutreachDraft {
        let role = "the \(job.title) role at \(job.company)"
        let hook = resume?.sections.first.map { "Most recently I worked as \($0.heading)." } ?? ""
        let sign = "Thanks,\n" + ((resume?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "[Your name]")
        let (subject, ask): (String, String) = switch kind {
        case .referral: ("Referral for \(job.title) at \(job.company)?", "I'm applying for \(role). \(hook)\n\nWould you be open to referring me, or pointing me to the right person on the team? I'm happy to send my resume.")
        case .recruiter: ("\(job.title) application", "I've applied for \(role) and wanted to introduce myself. \(hook)\n\nIs there anything else I can share to help with your review?")
        case .manager: ("Interested in \(job.title) on your team", "I'm interested in \(role) and would love to learn what the team is working on. \(hook)\n\nWould you have time for a short chat?")
        case .followUp: ("Following up: \(job.title)", "I applied for \(role) and wanted to follow up. I'm still very interested and happy to share anything that helps.")
        }
        return OutreachDraft(subject: subject, body: "Hi \(placeholder),\n\n\(ask)\n\n\(sign)")
    }

    static func with(_ d: OutreachDraft, note: String) -> OutreachDraft { var d = d; d.note = note; return d }
    static func unique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert(Text.norm($0)).inserted }
    }
}
