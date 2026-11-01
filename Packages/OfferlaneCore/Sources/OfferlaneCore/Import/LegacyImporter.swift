import Foundation
import GRDB

/// Settings → Import → "previous-version (v2) folder": brings over everything the Python prototype stored.
public struct LegacyImporter: Sendable {
    public let store: Store
    public let destination: URL
    public init(store: Store, destination: URL = Paths.root) { self.store = store; self.destination = destination }

    /// Where the v2 prototype kept its data by default (override with OFFERLANE_LEGACY_DIR).
    public static var defaultFolder: URL {
        if let d = ProcessInfo.processInfo.environment["OFFERLANE_LEGACY_DIR"] { return URL(fileURLWithPath: d) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Claude/Job Search/Job Agent/app")
    }
    public static func looksValid(_ dir: URL) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("profile.json").path) }

    public struct Report: Sendable, Equatable, CustomStringConvertible {
        public var profile = false, search = false, companies = 0, resumes: [String] = [], jobs = 0, skippedJobs = 0, events = 0
        public var applications = 0, atsCache = 0, accounts = 0, sponsorLists = 0, emailsSeen = 0
        public var description: String {
            "Imported \(resumes.count) resume version\(resumes.count == 1 ? "" : "s") (\(resumes.joined(separator: ", "))), \(jobs) roles, "
                + "\(applications) application folders and \(companies) companies."
        }
    }

    struct LegacySettings: Decodable {
        struct Run: Decodable { var poolSize: Int?; var maxAgeDays: Int?; var minScore: Int? }
        struct Notify: Decodable { var desktop: Bool?; var ntfy: Bool?; var ntfyTopic: String? }
        struct Email: Decodable { var enabled: Bool?; var imapHost: String?; var user: String? }
        struct LLM: Decodable { var provider: String?; var modelSmart: String?; var modelFast: String? }
        var run: Run?; var notify: Notify?; var email: Email?; var llm: LLM?
    }

    public func run(from dir: URL) throws -> Report {
        guard Self.looksValid(dir) else { throw ResumeImportError("That folder doesn't look like a Offerlane data folder (no profile.json).") }
        var rep = Report()
        let dec = JSONCoding.decoder
        func load(_ name: String) -> Data? { try? Data(contentsOf: dir.appendingPathComponent(name)) }

        if let d = load("profile.json") { try store.set(.profile, try dec.decode(Profile.self, from: d)); rep.profile = true }

        let legacy = load("settings.json").flatMap { try? dec.decode(LegacySettings.self, from: $0) }
        if let d = load("search.json") {
            var s = try dec.decode(SearchConfig.self, from: d)
            if let r = legacy?.run { s.minScore = r.minScore ?? s.minScore; s.maxAgeDays = r.maxAgeDays ?? s.maxAgeDays; s.poolSize = r.poolSize ?? s.poolSize }
            s.companies = Careers.attachWorkday(s.companies)
            try store.set(.search, s); rep.search = true; rep.companies = s.companies.count
        }

        var settings = try store.settings()
        if let l = legacy {
            if settings.provider == .none, l.llm?.provider == "claude_code" {
                settings.provider = .claudeCLI; settings.modelFast = l.llm?.modelFast ?? "haiku"; settings.modelSmart = l.llm?.modelSmart ?? "sonnet"
            }
            if let n = l.notify { settings.notify.desktop = n.desktop ?? true; settings.notify.ntfy = n.ntfy ?? false
                if let t = n.ntfyTopic, !t.isEmpty { settings.notify.ntfyTopic = t } }
            if let e = l.email {
                settings.email.host = e.imapHost ?? settings.email.host; settings.email.user = e.user ?? ""
                settings.email.preset = MailPreset.all.first { $0.host == settings.email.host }?.key ?? "custom"
                // The app password isn't in the old file (and is never stored in files here), so tracking stays off until it's entered.
                settings.email.enabled = false
            }
            try store.set(.settings, settings)
        }

        // Resume versions
        let resumesDir = dir.appendingPathComponent("resumes")
        let defaultName = load("resumes/default.json").flatMap { try? JSONDecoder().decode([String: String].self, from: $0)["name"] }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: resumesDir.path)) ?? []).sorted()
        for v in names {
            let vd = resumesDir.appendingPathComponent(v)
            guard let d = try? Data(contentsOf: vd.appendingPathComponent("resume.json")) else { continue }
            var c = try dec.decode(ResumeContent.self, from: d)
            c.variant = v; if c.label.isEmpty { c.label = v }
            let tex = try? String(contentsOf: vd.appendingPathComponent("template.tex"), encoding: .utf8)
            let tpl = (try? Data(contentsOf: vd.appendingPathComponent("template.json"))).flatMap { try? dec.decode(TexTemplate.self, from: $0) }
            let src = (try? String(contentsOf: vd.appendingPathComponent("source.txt"), encoding: .utf8)) ?? ""
            let name = ResumeVersion.validName(v) ? v : ResumeVersion.makeName(from: v)
            try store.saveResume(ResumeVersion(name: name, label: c.label, isDefault: v == defaultName, content: c, sourceText: src,
                                               sourceFile: tex != nil ? "template.tex" : "source.txt", templateTex: tex, template: tpl))
            rep.resumes.append(name)
        }
        if let dn = defaultName, rep.resumes.contains(dn) { try store.setDefaultResume(dn) }

        // Jobs + events
        if let d = load("jobs.json"), let root = try? JSONDecoder().decode(JSONValue.self, from: d) {
            let jobs = root["jobs"]?.object ?? [:]
            var known = Set<String>()
            try store.db.write { db in
                for (id, v) in jobs {
                    guard let job = Self.job(id: id, v) else { rep.skippedJobs += 1; continue }
                    try job.save(db); known.insert(id); rep.jobs += 1
                }
                for e in root["events"]?.array ?? [] {
                    guard let jid = e["job_id"]?.string, known.contains(jid), let ts = e["ts"]?.string, let st = e["status"]?.string else { continue }
                    let dup = try Int.fetchOne(db, sql: "SELECT 1 FROM event WHERE job_id = ? AND ts = ? AND status = ?", arguments: [jid, ts, st]) != nil
                    if dup { continue }
                    var ev = JobEvent(jobId: jid, status: st, source: e["source"]?.string ?? "", detail: e["detail"]?.string ?? "", ts: ts)
                    try ev.insert(db); rep.events += 1
                }
            }
            if let seen = root["emails"]?.object { rep.emailsSeen = try store.markEmailsSeen(Array(seen.keys)).count }
        }

        // Application folders (tailored PDFs, plans, answers)
        let apps = dir.appendingPathComponent("applications"), dest = destination.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? [] where !name.hasPrefix(".") {
            let to = dest.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: to.path) { try FileManager.default.copyItem(at: apps.appendingPathComponent(name), to: to) }
            rep.applications += 1
        }

        if let d = load("ats_resolved.json"), let cache = try? JSONDecoder().decode([String: JSONValue].self, from: d) {
            try store.set(.atsCache, cache); rep.atsCache = cache.count
        }
        if let d = load("accounts.json"), let acc = try? JSONDecoder().decode([String: JSONValue].self, from: d) {
            for (host, a) in acc {
                var bool = false; if case .bool(let b) = a["approved"] ?? .null { bool = b }
                try store.saveAccount(SiteAccount(host: host, company: a["company"]?.string ?? "", email: a["email"]?.string ?? "",
                                                  approved: bool, approvedAt: a["approved_at"]?.string, created: a["created"]?.string))
                rep.accounts += 1
            }
        }
        let sponsors = dir.appendingPathComponent("sponsors"), sDest = destination.appendingPathComponent("sponsors")
        try FileManager.default.createDirectory(at: sDest, withIntermediateDirectories: true)
        for f in ["uk.txt", "nl.txt"] where FileManager.default.fileExists(atPath: sponsors.appendingPathComponent(f).path) {
            try? FileManager.default.removeItem(at: sDest.appendingPathComponent(f))
            try FileManager.default.copyItem(at: sponsors.appendingPathComponent(f), to: sDest.appendingPathComponent(f)); rep.sponsorLists += 1
        }
        if let d = try? Data(contentsOf: sponsors.appendingPathComponent("state.json")), let st = try? JSONDecoder().decode([String: JSONValue].self, from: d) {
            try store.set(.sponsorState, st)
        }
        Log.info("import: \(rep.description)")
        return rep
    }

    /// One prototype job (jobs.json value) → Job. Statuses map 1:1, `dismissed` → declined.
    static func job(id: String, _ v: JSONValue) -> Job? {
        guard let company = v["company"]?.string, let title = v["title"]?.string, let st = JobStatus(legacy: v["status"]?.string ?? "") else { return nil }
        var j = Job(company: company, title: title, location: v["location"]?.string ?? "", url: v["url"]?.string ?? "", id: id)
        j.status = st
        func s(_ k: String) -> String { v[k]?.string ?? "" }
        j.applyUrl = s("apply_url"); j.ats = s("ats"); j.atsSlug = s("ats_slug"); j.source = s("source"); j.posted = v["posted"]?.string
        j.description = s("description"); j.firstSeen = s("first_seen"); j.updated = s("updated"); j.lastSeen = s("last_seen")
        j.localScore = v["local_score"]?.double; j.llmScore = v["llm_score"]?.double.map { Int($0) }; j.llmReason = s("llm_reason")
        j.variant = s("variant"); j.visa = s("visa"); j.minYears = v["min_years"]?.double.map { Int($0) }
        j.folder = s("folder").replacingOccurrences(of: "applications/", with: "")
        j.keywords = v["keywords"]?.array?.compactMap(\.string) ?? []
        j.changesSummary = s("changes_summary"); j.tailorNote = s("tailor_note"); j.error = s("error"); j.autofill = s("autofill")
        j.site = s("site"); j.notes = s("notes")
        if case .bool(true) = v["quick"] ?? .null { j.quick = true }
        if j.firstSeen.isEmpty { j.firstSeen = Dates.now() }; if j.updated.isEmpty { j.updated = j.firstSeen }; if j.lastSeen.isEmpty { j.lastSeen = j.updated }
        if st.isHidden { j.stripForHiding() }
        return j
    }
}
