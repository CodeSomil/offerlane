import Foundation

/// Turns an uploaded file into a resume version with one LLM call. For LaTeX, the bullet bank comes from the
/// file's own \item lines (exact), and the model only supplies contact details, skills and suggested titles.
public struct ResumeParser: Sendable {
    public let ai: AI
    public init(ai: AI) { self.ai = ai }

    public static let prompt = """
    Convert this resume into JSON. Copy every bullet VERBATIM (do not rephrase, merge or invent anything).
    Schema: {"name":"","email":"","phone":"","location":"","links":{"linkedin":"","github":"","portfolio":""},
    "headline":"one-line professional headline from the resume or its top line","summary":"verbatim summary or ''",
    "experience":[{"company":"","title":"","location":"","dates":"","bullets":["..."]}],
    "projects":[{"name":"","dates":"","bullets":["..."]}],
    "education":[{"school":"","degree":"","dates":"","details":""}],
    "skills":[{"label":"","items":"comma separated"}],"certifications":[""],"extras":["awards, languages, publications"],
    "years_experience":0,"seniority":"entry|mid|senior|lead|manager|director|executive","field":"e.g. data science, nursing, sales",
    "suggested_titles":["5-8 job titles this person should search for, most specific first"],
    "top_skills":["10-15 skills/keywords for job matching"]}
    RESUME:

    """

    /// What the model returns: bullets as plain strings.
    struct Parsed: Decodable {
        struct Sec: Codable, Hashable, Sendable {
            @Lenient var company: String
            @Lenient var title: String
            @Lenient var name: String
            @Lenient var location: String
            @Lenient var dates: String
            @LenientArray var bullets: [String]
        }
        @Lenient var name: String
        @Lenient var email: String
        @Lenient var phone: String
        @Lenient var location: String
        var links: [String: String]?
        @Lenient var headline: String
        @Lenient var summary: String
        @LenientArray var experience: [Sec]
        @LenientArray var projects: [Sec]
        @LenientArray var education: [ResumeContent.EducationItem]
        @LenientArray var skills: [ResumeContent.Skill]
        @LenientArray var certifications: [String]
        @LenientArray var extras: [String]
        @Lenient var yearsExperience: String
        @Lenient var seniority: String
        @Lenient var field: String
        @LenientArray var suggestedTitles: [String]
        @LenientArray var topSkills: [String]
    }

    public func parse(filename: String, data: Data, name: String, label: String) async throws -> ResumeVersion {
        guard ResumeVersion.validName(name) else {
            throw ResumeImportError("Resume version names use lowercase letters, digits and dashes (max 30).")
        }
        let text = try Extract.text(filename: filename, data: data)
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 200 else {
            throw ResumeImportError("Couldn't read text from that file (it may be a scanned image). Try a PDF exported from Word or Google Docs, or a .docx.")
        }
        // Adding the same file again (or retrying after a remove) reuses the earlier reading.
        let body = String(text.prefix(14000))
        let p: Parsed = try await ai.cachedJSON(LLMRequest(prompt: Self.prompt + body, smart: true, maxTokens: 6000),
                                                key: ai.cacheKey("parse-v1", [Hash.sha256(body)], smart: true), kind: "parse")
        guard !p.experience.isEmpty || !p.projects.isEmpty else {
            throw ResumeImportError("The AI couldn't find work experience in that resume. Check the file and try again.")
        }
        var c = Self.content(p, name: name, label: label)

        var templateTex: String?, template: TexTemplate?
        if (filename as NSString).pathExtension.lowercased() == "tex" {
            let tex = String(decoding: data, as: UTF8.self); let tpl = LaTeX.parse(tex)
            if !tpl.sections.isEmpty {
                templateTex = tex; template = tpl; c.format = "tex"
                c.experience = tpl.sections.map { s in
                    ResumeContent.Section(id: s.id, title: s.title, bullets: s.bullets.map { .init(id: $0.id, text: $0.text) })
                }
                c.projects = []
            }
        }
        return ResumeVersion(name: name, label: c.label, content: c, sourceText: text, sourceFile: filename, templateTex: templateTex, template: template)
    }

    /// The model's reply as resume content (bullet ids e1.1, p2.3, ...). Pure; libs/core resume.ts ports it (core golden).
    static func content(_ p: Parsed, name: String, label: String) -> ResumeContent {
        var c = ResumeContent()
        c.variant = name; c.label = label.isEmpty ? name : label
        c.name = p.name; c.email = p.email; c.phone = p.phone; c.location = p.location
        c.links = (p.links ?? [:]).filter { !$0.value.isEmpty }
        c.headline = p.headline; c.summary = p.summary
        c.education = p.education; c.skills = p.skills.filter { !$0.label.isEmpty }
        c.certifications = p.certifications.filter { !$0.isEmpty }; c.extras = p.extras.filter { !$0.isEmpty }
        c.yearsExperience = p.yearsExperience; c.seniority = p.seniority; c.field = p.field
        c.suggestedTitles = p.suggestedTitles; c.topSkills = p.topSkills
        func sections(_ xs: [Parsed.Sec], prefix: String) -> [ResumeContent.Section] {
            xs.enumerated().map { i, s in
                let id = "\(prefix)\(i + 1)"
                let bullets = s.bullets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                return .init(id: id, title: s.title, company: s.company, name: s.name, location: s.location, dates: s.dates,
                             bullets: bullets.enumerated().map { .init(id: "\(id).\($0.offset + 1)", text: $0.element) })
            }
        }
        c.experience = sections(p.experience, prefix: "e"); c.projects = sections(p.projects, prefix: "p")
        return c
    }
}
