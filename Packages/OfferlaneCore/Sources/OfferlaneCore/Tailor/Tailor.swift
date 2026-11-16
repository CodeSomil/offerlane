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

    /// The cached block (rules + brief + bullet bank), the condensed JD and the per-role prompt of one tailoring call.
    static func request(_ j: Job, version v: ResumeVersion, brief: String) -> (bank: String, jd: String, prompt: String) {
        let jd = Ranking.condense(j.description, 2600)
        return (rules + "\n" + brief + "\n\nBULLET BANK:\n" + PlanApplier.compact(v), jd,
                "JOB: \(j.title) at \(j.company) (\(j.location))\nJD: \(jd)\n"
                + (j.tailorNote.isEmpty ? "" : "CANDIDATE'S NOTE: \(j.tailorNote)\n") + "Return the JSON now.")
    }

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
            let brief = Brief.candidate(resume: v.content, versions: versions, profile: profile, search: search, includePrivate: false)
            let (bank, jd, prompt) = Self.request(j, version: v, brief: brief)
            // The same role posted for several cities gets one tailoring: the key leaves out the location.
            // A redo with a note, a changed resume or a changed profile all change the key.
            let key = ai.cacheKey("tailor-v1", [Hash.sha256(bank), j.company.lowercased(), j.title.lowercased(), jd, j.tailorNote], smart: true)
            plan = try await ai.cachedJSON(LLMRequest(prompt: prompt, cache: bank, smart: true, maxTokens: 3500), key: key, kind: "tailor")
        }
        try await finish(j, plan: plan, version: v, profile: profile, by: "tailor")
    }

    /// Writes the plan's files and moves the role to review. Shared by Tailor.run and outside drafts (Claude).
    /// Files are built in a temp folder first and moved in only after the status change commits, so a failed render or a
    /// role changed meanwhile (another tailoring finished first) leaves the old draft and status untouched.
    /// `expect` is the status the role must still have: `.tailoring` (normal) or `.review` (a new Claude draft, kept in review).
    func finish(_ j: Job, plan: TailorPlan, version v: ResumeVersion, profile: Profile, by source: String,
                expect: JobStatus = .tailoring, asIs: Bool? = nil) async throws {
        var plan = plan
        plan.variant = v.name
        let asIs = asIs ?? j.quick
        let folder = j.folder.isEmpty ? Self.folderName(j) : j.folder
        let dir = Paths.applications.appendingPathComponent(folder, isDirectory: true)
        let fm = FileManager.default
        let tmp = Paths.applications.appendingPathComponent(".draft-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        // Keep files the plan doesn't rewrite (answers.md for a quick role) by starting from a copy of the current folder.
        if fm.fileExists(atPath: dir.path) {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { try? fm.copyItem(at: f, to: tmp.appendingPathComponent(f.lastPathComponent)) }
        }
        let changes = try await build(dir: tmp, plan: plan, version: v, profile: profile)
        if !asIs || !fm.fileExists(atPath: tmp.appendingPathComponent("answers.md").path) {
            try Self.answersMarkdown(plan, company: j.company).write(to: tmp.appendingPathComponent("answers.md"), atomically: true, encoding: .utf8)
        }
        try "# \(j.company) - \(j.title)\n\(j.location) | \(j.url)\n\n\(j.description)".write(to: tmp.appendingPathComponent("job.md"), atomically: true, encoding: .utf8)
        let set = { (x: inout Job) in
            x.folder = folder; x.keywords = plan.keywords; x.variant = v.name; x.changesSummary = asIs ? "Your resume as-is." : plan.changesSummary; x.error = ""
            if !asIs { x.quick = false }
        }
        if expect == .review {
            try store.update(j.id) { x in guard x.status == .review else { throw StoreError.changed }; set(&x) }
            try store.addEvent(j.id, status: JobStatus.review.rawValue, source: source, detail: "new draft: " + changes.ats)
        } else {
            do { try store.transition(j.id, to: .review, by: source, detail: changes.ats) { set(&$0) } }
            catch is IllegalTransition { throw StoreError.changed }
        }
        // Committed: swap the new files in (same volume, so these are renames).
        try? fm.removeItem(at: dir)
        try fm.moveItem(at: tmp, to: dir)
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
    var tokenLimit: Int?
    private var running = false
    private var onChange: (@Sendable (String?) -> Void)?

    public init(store: Store) { self.store = store }

    /// `tokenLimit`: most AI tokens one tailored resume may use (nil or 0 = no limit).
    public func configure(ai: AI?, tokenLimit: Int? = nil, onChange: @escaping @Sendable (String?) -> Void) {
        self.ai = ai; self.tokenLimit = (tokenLimit ?? 0) > 0 ? tokenLimit : nil; self.onChange = onChange
    }

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
            do { try await Tailor(store: store, ai: ai.scoped(budget: tokenLimit)).run(j.id); made += 1 }
            catch {
                Log.error("tailor \(j.id): \(error.localizedDescription)")
                // Only a role still waiting gets the error: if a Claude draft reached review meanwhile, it stays clean.
                _ = try? store.update(j.id) { if $0.status == .tailoring { $0.error = String(error.localizedDescription.prefix(300)) } }
            }
            onChange?(nil)
        }
        return made
    }
}
