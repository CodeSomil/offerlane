import Foundation

/// One AI call per approved role returns the resume plan, cover letter, "why us" and screening answers.
/// The bullet bank and rules go in the cached block. Ported from tailor.py.
public struct Tailor: Sendable {
    public let store: Store
    public let ai: AI
    public init(store: Store, ai: AI) { self.store = store; self.ai = ai }

    public static let rules = """
    You tailor a resume using ONLY the candidate's bullet bank below. Then act as a skeptical hiring manager for the JD,
    check your plan and fix it before answering (reviewer pass).
    Rules: reorder and select bullets per section (keep the strongest 3-6 for recent roles, fewer for old ones; drop weak ones);
    rephrase toward the JD's wording; NEVER add tools, numbers, employers, titles, scope or claims that are not in the bank;
    keep every number exactly as written. The top 3 bullets overall must map to the JD's top 3 asks. No keyword stuffing.
    Headline and summary: rewrite for this role using only facts from the bank (summary <= 60 words).
    Cover letter <= 170 words, specific to the company and role, facts from the bank only, no cliches, signed with the candidate's name.
    Answers: 2-4 likely screening questions for this role (e.g. "Why are you interested in this role?") with <= 80-word answers from the bank.
    Return JSON: {"keywords":["8-12 key JD terms"],"headline":"","summary":"","order":{"<section id>":["bullet ids in order"]},
    "rewrites":{"<bullet id>":"new text"},"skills_order":["skill labels, most relevant first"],"cover_letter":"","why_company":"<= 70 words",
    "answers":[{"q":"","a":""}],"changes_summary":"<= 40 words: what you emphasised and why"}

    """

    public static func folderName(_ j: Job, date: Date = Date()) -> String { "\(Dates.today(date))_\(Text.slug(j.company))_\(Text.slug(j.title))" }

    public struct Changes: Codable, Hashable, Sendable {
        public var pages: Int; public var ats: String; @LenientArray public var missingKeywords: [String]; @LenientArray public var warnings: [String]
        public var note: String?
        public init(pages: Int, ats: String, missingKeywords: [String], warnings: [String], note: String?) {
            self.pages = pages; self.ats = ats; self.missingKeywords = missingKeywords; self.warnings = warnings; self.note = note
        }
    }

    func version(_ j: Job) throws -> ResumeVersion {
        guard let v = try store.resume(j.variant) else { throw RenderError.failed("Add a resume first.") }
        return v
    }

    /// Tailor an approved role (or, with `quick`, use the resume as-is) and move it to review.
    public func run(_ id: String) async throws {
        guard let j = try store.job(id) else { throw StoreError.missingJob(id) }
        let v = try version(j), profile = try store.profile(), search = try store.search(), versions = try store.resumeVersions()
        var plan = TailorPlan()
        if !j.quick {
            let brief = Brief.candidate(resume: v.content, versions: versions, profile: profile, search: search)
            let bank = Self.rules + "\n" + brief + "\n\nBULLET BANK:\n" + PlanApplier.compact(v)
            let prompt = "JOB: \(j.title) at \(j.company) (\(j.location))\nJD: \(Ranking.condense(j.description, 2600))\n"
                + (j.tailorNote.isEmpty ? "" : "CANDIDATE'S NOTE: \(j.tailorNote)\n") + "Return the JSON now."
            plan = try await ai.json(LLMRequest(prompt: prompt, cache: bank, smart: true, maxTokens: 3500))
        }
        plan.variant = v.name
        let folder = j.folder.isEmpty ? Self.folderName(j) : j.folder
        let dir = Paths.applications.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let changes = try await build(dir: dir, plan: plan, version: v, profile: profile)
        if !j.quick || !FileManager.default.fileExists(atPath: dir.appendingPathComponent("answers.md").path) {
            try Self.answersMarkdown(plan, company: j.company).write(to: dir.appendingPathComponent("answers.md"), atomically: true, encoding: .utf8)
        }
        try "# \(j.company) - \(j.title)\n\(j.location) | \(j.url)\n\n\(j.description)".write(to: dir.appendingPathComponent("job.md"), atomically: true, encoding: .utf8)
        try store.transition(id, to: .review, by: "tailor", detail: changes.ats) {
            $0.folder = folder; $0.keywords = plan.keywords; $0.variant = v.name; $0.changesSummary = j.quick ? "Your resume as-is." : plan.changesSummary; $0.error = ""
        }
    }

    /// Apply the plan, render within the page budget, check the PDF, and write plan.json / changes.json / the PDF.
    @discardableResult
    public func build(dir: URL, plan: TailorPlan, version v: ResumeVersion, profile: Profile) async throws -> Changes {
        let (content, warns0) = PlanApplier.apply(plan, to: v)
        let out = try await Builder.render(content, version: v, paper: profile.prefs.paper.isEmpty ? "A4" : profile.prefs.paper)
        let name = v.content.name.isEmpty ? profile.displayName : v.content.name
        let (ats, missing) = Builder.atsCheck(out.pdf, keywords: plan.keywords, name: name)
        var warns = warns0
        if !out.trimmed.isEmpty { warns.append("trimmed to fit \(out.pages) page(s): \(out.trimmed.joined(separator: ", "))") }
        let stem = profile.fileStem == "_Resume" || profile.fileStem.isEmpty ? "Resume" : profile.fileStem
        for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where old.pathExtension == "pdf" { try? FileManager.default.removeItem(at: old) }
        try out.pdf.write(to: dir.appendingPathComponent("\(stem).pdf"))
        var p = plan; p.variant = v.name
        try JSONCoding.encoder.encode(p).write(to: dir.appendingPathComponent("plan.json"))
        let changes = Changes(pages: out.pages, ats: ats, missingKeywords: missing, warnings: warns, note: out.note)
        try JSONCoding.encoder.encode(changes).write(to: dir.appendingPathComponent("changes.json"))
        return changes
    }

    public static func answersMarkdown(_ p: TailorPlan, company: String) -> String {
        var s = "### Cover letter\n\(p.coverLetter.trimmingCharacters(in: .whitespacesAndNewlines))\n\n### Why \(company)?\n\(p.whyCompany.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        for qa in p.answers where !qa.q.isEmpty { s += "\n### \(qa.q.trimmingCharacters(in: .whitespaces))\n\(qa.a.trimmingCharacters(in: .whitespacesAndNewlines))\n" }
        return s
    }

    // MARK: review-screen helpers

    public static func dir(_ j: Job) -> URL { Paths.applications.appendingPathComponent(j.folder, isDirectory: true) }

    public func plan(_ j: Job) -> TailorPlan {
        (try? Data(contentsOf: Self.dir(j).appendingPathComponent("plan.json"))).flatMap { try? JSONCoding.decoder.decode(TailorPlan.self, from: $0) } ?? TailorPlan()
    }
    public func changes(_ j: Job) -> Changes? {
        (try? Data(contentsOf: Self.dir(j).appendingPathComponent("changes.json"))).flatMap { try? JSONCoding.decoder.decode(Changes.self, from: $0) }
    }
    public func pdfURL(_ j: Job) -> URL? {
        ((try? FileManager.default.contentsOfDirectory(at: Self.dir(j), includingPropertiesForKeys: nil)) ?? []).first { $0.pathExtension == "pdf" }
    }
    public func review(_ j: Job) throws -> ReviewData { PlanApplier.review(plan(j), try version(j)) }

    /// The user's edits: no AI call, the guard still applies.
    @discardableResult
    public func rebuild(_ id: String, edit: ReviewData) async throws -> Changes {
        guard let j = try store.job(id) else { throw StoreError.missingJob(id) }
        let v = try version(j), p = PlanApplier.plan(from: edit, old: plan(j), v)
        let c = try await build(dir: Self.dir(j), plan: p, version: v, profile: try store.profile())
        try store.addEvent(id, status: j.status.rawValue, source: "you", detail: "resume edited")
        return c
    }

    /// Redo with a note, or use the resume as-is: back to the tailoring queue.
    public func requeue(_ id: String, note: String? = nil, quick: Bool = false) throws {
        try store.transition(id, to: .tailoring, by: "you", detail: quick ? "use my resume as-is" : "redo") {
            $0.error = ""; $0.quick = quick; if let note { $0.tailorNote = note }
        }
    }
}

/// Tailors approved roles one at a time in the background. Survives relaunch: the queue is the database.
public actor TailorQueue {
    let store: Store
    var ai: AI?
    private var running = false
    private var onChange: (@Sendable (String?) -> Void)?

    public init(store: Store) { self.store = store }

    public func configure(ai: AI?, onChange: @escaping @Sendable (String?) -> Void) { self.ai = ai; self.onChange = onChange }

    /// Process everything waiting. Returns how many roles reached review.
    @discardableResult
    public func kick() async -> Int {
        guard !running, let ai else { return 0 }
        running = true; defer { running = false }
        var made = 0
        while !Task.isCancelled {
            let todo = ((try? store.jobs([.tailoring])) ?? []).filter { $0.error.isEmpty }.sorted { $0.updated < $1.updated }
            guard let j = todo.first else { break }
            onChange?("Tailoring your resume for \(j.company) – \(j.title)…")
            do { try await Tailor(store: store, ai: ai).run(j.id); made += 1 }
            catch {
                Log.error("tailor \(j.id): \(error.localizedDescription)")
                _ = try? store.update(j.id) { $0.error = String(error.localizedDescription.prefix(300)) }
            }
            onChange?(nil)
        }
        return made
    }
}
