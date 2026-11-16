import Foundation
import GRDB

/// The app's single SQLite database (GRDB, WAL). All mutations of a job's status go through `transition`,
/// which enforces the state machine and records an event.
public final class Store: @unchecked Sendable {
    public let db: any DatabaseWriter

    /// Opens (and migrates) the database at `url`. Pass nil for an in-memory database (tests).
    /// With `migrate: false` (the offerlane-mcp helper) the schema is never changed: a database the running app hasn't
    /// brought up to date is refused instead. `key` opens an encrypted (SQLCipher) database; nil = unencrypted.
    public init(url: URL? = nil, key: Data? = nil, migrate: Bool = true) throws {
        if let url {
            if migrate { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
            var config = Configuration(); config.foreignKeysEnabled = true
            if let key { Encryption.configure(&config, key: key) }
            // The app and the offerlane-mcp helper can write at the same time: wait for the other's write instead of failing.
            config.busyMode = .timeout(5)
            db = try DatabasePool(path: url.path, configuration: config)
        } else {
            db = try DatabaseQueue()
        }
        if migrate { try Self.migrator.migrate(db) }
        else if try !db.read({ try Self.migrator.hasCompletedMigrations($0) }) { throw StoreError.outdated }
    }

    public static func openDefault() throws -> Store {
        try Paths.ensure(); return try Backup.openStore(root: Paths.root, secrets: Keychain(service: Paths.keychainService(for: Paths.account)))
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "job") { t in
                t.primaryKey("id", .text)
                t.column("company", .text).notNull()
                t.column("title", .text).notNull()
                for c in ["location", "url", "apply_url", "ats", "ats_slug", "source", "description", "status", "first_seen", "updated",
                          "last_seen", "llm_reason", "variant", "visa", "folder", "changes_summary", "tailor_note", "error", "autofill", "site", "notes"] {
                    t.column(c, .text).notNull().defaults(to: "")
                }
                t.column("posted", .text)
                t.column("local_score", .double)
                t.column("llm_score", .integer)
                t.column("min_years", .integer)
                t.column("keywords", .jsonText).notNull().defaults(to: "[]")
                t.column("quick", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "job_status", on: "job", columns: ["status"])
            try db.create(table: "event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("job_id", .text).notNull().indexed()
                t.column("ts", .text).notNull()
                t.column("status", .text).notNull()
                t.column("source", .text).notNull()
                t.column("detail", .text).notNull()
            }
            try db.create(table: "kv") { t in
                t.primaryKey("key", .text)
                t.column("value", .blob).notNull()
            }
            try db.create(table: "resume_version") { t in
                t.primaryKey("name", .text)
                t.column("label", .text).notNull()
                t.column("is_default", .boolean).notNull().defaults(to: false)
                t.column("content", .jsonText).notNull()
                t.column("source_text", .text).notNull()
                t.column("source_file", .text).notNull()
                t.column("template_tex", .text)
                t.column("template", .jsonText)
                t.column("created", .text).notNull()
            }
            try db.create(table: "account") { t in
                t.primaryKey("host", .text)
                t.column("company", .text).notNull()
                t.column("email", .text).notNull()
                t.column("approved", .boolean).notNull().defaults(to: false)
                t.column("approved_at", .text)
                t.column("created", .text)
            }
            try db.create(table: "email_seen") { t in t.primaryKey("message_id", .text) }
            try db.create(table: "usage") { t in
                t.primaryKey("day", .text)
                t.column("calls", .integer).notNull().defaults(to: 0)
                t.column("input_tokens", .integer).notNull().defaults(to: 0)
                t.column("output_tokens", .integer).notNull().defaults(to: 0)
                t.column("cached_tokens", .integer).notNull().defaults(to: 0)
                t.column("usd", .double).notNull().defaults(to: 0)
            }
        }
        // v0.2: answers the AI already gave, keyed by a hash of everything that went into the question,
        // so a repeated posting or an unchanged email never costs a second call. Additive: v1 data is untouched.
        m.registerMigration("v2-llm-cache") { db in
            try db.create(table: "llm_cache") { t in
                t.primaryKey("key", .text)
                t.column("kind", .text).notNull()
                t.column("value", .blob).notNull()
                t.column("created", .text).notNull()
            }
            try db.create(index: "llm_cache_kind", on: "llm_cache", columns: ["kind", "created"])
        }
        // v0.3: result tier from scoring ("fit" | "stretch"; empty = not scored yet).
        m.registerMigration("v3-job-tier") { db in
            try db.alter(table: "job") { t in t.add(column: "tier", .text).notNull().defaults(to: "") }
        }
        // v4 P1.8: the interview's date and time, entered by the user (local ISO seconds; NULL = not set).
        m.registerMigration("v4-interview-at") { db in
            try db.alter(table: "job") { t in t.add(column: "interview_at", .text) }
        }
        return m
    }

    // MARK: AI answer cache

    public func cached(_ key: String) throws -> Data? {
        try db.read { try Data.fetchOne($0, sql: "SELECT value FROM llm_cache WHERE key = ?", arguments: [key]) }
    }
    public func cache(_ key: String, kind: String, value: Data) throws {
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO llm_cache(key, kind, value, created) VALUES (?, ?, ?, ?)",
                                      arguments: [key, kind, value, Dates.now()]) }
    }
    /// Keeps the cache small: drops entries older than `days`.
    @discardableResult
    public func pruneCache(olderThanDays days: Int = 120) throws -> Int {
        let cutoff = Dates.now(Date().addingTimeInterval(-Double(days) * 86_400))
        return try db.write { db in try db.execute(sql: "DELETE FROM llm_cache WHERE created < ?", arguments: [cutoff]); return db.changesCount }
    }
    public func cacheCount() throws -> Int { try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM llm_cache") ?? 0 } }

    // MARK: key-value documents (profile, search, settings, caches)

    public enum Key: String, Sendable { case profile, search, settings, atsCache = "ats_resolved", sponsorState = "sponsor_state", rankBrief = "rank_brief", sourceRuns = "source_runs", boardRegistry = "board_registry", linkChecks = "link_checks", skillPlan = "skill_plan", interviewPrep = "interview_prep", offers, contacts }

    /// An unreadable document is moved to `<key>.corrupt-<day>` (bytes kept) and reads as empty, so the app still opens.
    public func get<T: Decodable>(_ key: Key, as: T.Type = T.self) throws -> T? {
        guard let data = try db.read({ try Data.fetchOne($0, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key.rawValue]) }) else { return nil }
        do { return try JSONCoding.decoder.decode(T.self, from: data) } catch {
            try db.write { db in
                try db.execute(sql: "INSERT OR REPLACE INTO kv(key, value) VALUES (?, ?)", arguments: ["\(key.rawValue).corrupt-\(Dates.today())", data])
                try db.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [key.rawValue])
            }
            Log.error("store: \(key.rawValue) couldn't be read; kept a copy and reset it")
            return nil
        }
    }
    /// Keys of documents set aside by `get` because they couldn't be read (newest day last).
    public func corruptBackups() throws -> [String] {
        try db.read { try String.fetchAll($0, sql: "SELECT key FROM kv WHERE key LIKE '%.corrupt-%' ORDER BY substr(key, -10), key") }
    }
    public func set<T: Encodable>(_ key: Key, _ value: T) throws {
        let data = try JSONCoding.encoder.encode(value)
        try db.write { db in try db.execute(sql: "INSERT OR REPLACE INTO kv(key, value) VALUES (?, ?)", arguments: [key.rawValue, data]) }
    }

    public func profile() throws -> Profile { try get(.profile) ?? Profile() }
    public func search() throws -> SearchConfig { try get(.search) ?? SearchConfig() }
    public func settings() throws -> AppSettings { try get(.settings) ?? AppSettings() }

    // MARK: jobs

    public func job(_ id: String) throws -> Job? { try db.read { try Job.fetchOne($0, key: id) } }

    public func jobs(_ statuses: [JobStatus]? = nil) throws -> [Job] {
        try db.read { db in
            if let statuses { return try Job.filter(statuses.map(\.rawValue).contains(Column("status"))).fetchAll(db) }
            return try Job.fetchAll(db)
        }
    }

    /// Insert a newly discovered posting. Returns false for a known fingerprint (and never resurrects a hidden role).
    @discardableResult
    public func upsert(_ incoming: Job) throws -> Bool {
        try db.write { db in
            var j = incoming; j.description = String(j.description.prefix(8000))
            if var old = try Job.fetchOne(db, key: j.id) {
                old.lastSeen = Dates.now()
                if !old.status.isHidden {
                    if !j.url.isEmpty { old.url = j.url }
                    if !j.applyUrl.isEmpty { old.applyUrl = j.applyUrl }
                    if j.description.count > old.description.count { old.description = j.description }
                }
                try old.update(db); return false
            }
            j.status = .found; j.firstSeen = Dates.now(); j.updated = Dates.now(); j.lastSeen = Dates.now()
            try j.insert(db); return true
        }
    }

    public func save(_ job: Job) throws { try db.write { try job.save($0) } }

    /// Apply `change` to a job inside one transaction.
    @discardableResult
    public func update(_ id: String, _ change: (inout Job) throws -> Void) throws -> Job {
        try db.write { db in
            guard var j = try Job.fetchOne(db, key: id) else { throw StoreError.missingJob(id) }
            try change(&j); j.updated = Dates.now(); try j.update(db); return j
        }
    }

    /// The one way a status changes: validates the move, strips hidden roles, records an event.
    @discardableResult
    public func transition(_ id: String, to status: JobStatus, by source: String, detail: String = "",
                           _ change: ((inout Job) -> Void)? = nil) throws -> Job {
        try db.write { db in
            guard var j = try Job.fetchOne(db, key: id) else { throw StoreError.missingJob(id) }
            try StateMachine.check(j.status, to: status)
            change?(&j)
            j.status = status; j.updated = Dates.now()
            if status.isHidden { j.stripForHiding() }
            try j.update(db)
            var e = JobEvent(jobId: id, status: status.rawValue, source: source, detail: String(detail.prefix(300)))
            try e.insert(db)
            return j
        }
    }

    public func addEvent(_ id: String, status: String, source: String, detail: String) throws {
        try db.write { db in var e = JobEvent(jobId: id, status: status, source: source, detail: detail); try e.insert(db) }
    }

    public func events(for id: String? = nil, limit: Int = 500) throws -> [JobEvent] {
        try db.read { db in
            var q = JobEvent.order(Column("id").desc).limit(limit)
            if let id { q = q.filter(Column("job_id") == id) }
            return try q.fetchAll(db)
        }
    }

    // MARK: resumes

    public func resumeVersions() throws -> [ResumeVersion] { try db.read { try ResumeVersion.order(Column("created")).fetchAll($0) } }
    public func resume(_ name: String? = nil) throws -> ResumeVersion? {
        try db.read { db in
            if let name, !name.isEmpty, let r = try ResumeVersion.fetchOne(db, key: name) { return r }
            return try ResumeVersion.filter(Column("is_default") == true).fetchOne(db) ?? ResumeVersion.order(Column("created")).fetchOne(db)
        }
    }
    /// Save a version; the first one saved becomes the default.
    public func saveResume(_ r: ResumeVersion) throws {
        try db.write { db in
            var r = r
            if try ResumeVersion.filter(Column("is_default") == true && Column("name") != r.name).fetchCount(db) == 0 { r.isDefault = true }
            try r.save(db)
        }
    }
    public func setDefaultResume(_ name: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE resume_version SET is_default = (name = ?)", arguments: [name])
        }
    }
    public func deleteResume(_ name: String) throws {
        try db.write { db in
            _ = try ResumeVersion.deleteOne(db, key: name)
            if try ResumeVersion.filter(Column("is_default") == true).fetchCount(db) == 0 {
                try db.execute(sql: "UPDATE resume_version SET is_default = 1 WHERE name = (SELECT name FROM resume_version ORDER BY created LIMIT 1)")
            }
        }
    }

    // MARK: accounts, emails, usage

    public func account(host: String) throws -> SiteAccount? { try db.read { try SiteAccount.fetchOne($0, key: host) } }
    public func accounts() throws -> [SiteAccount] { try db.read { try SiteAccount.order(Column("company")).fetchAll($0) } }
    public func saveAccount(_ a: SiteAccount) throws { try db.write { try a.save($0) } }
    public func deleteAccount(host: String) throws { _ = try db.write { try SiteAccount.deleteOne($0, key: host) } }

    /// Returns the IDs not seen before and marks them seen.
    public func markEmailsSeen(_ ids: [String]) throws -> Set<String> {
        try db.write { db in
            var fresh = Set<String>()
            for id in ids where try Int.fetchOne(db, sql: "SELECT 1 FROM email_seen WHERE message_id = ?", arguments: [id]) == nil {
                try db.execute(sql: "INSERT INTO email_seen(message_id) VALUES (?)", arguments: [id]); fresh.insert(id)
            }
            return fresh
        }
    }

    public func meter(input: Int, output: Int, cached: Int, usd: Double, day: String = Dates.today()) throws {
        try db.write { db in
            var u = try UsageDay.fetchOne(db, key: day) ?? UsageDay(day: day)
            u.calls += 1; u.inputTokens += input; u.outputTokens += output; u.cachedTokens += cached; u.usd += usd
            try u.save(db)
        }
    }
    public func usage(days: Int = 60) throws -> [UsageDay] {
        try db.read { try UsageDay.order(Column("day").desc).limit(days).fetchAll($0) }
    }

    /// Settings → Delete all my data.
    public func eraseEverything() throws {
        try db.write { db in
            for t in ["job", "event", "kv", "resume_version", "account", "email_seen", "usage", "llm_cache"] { try db.execute(sql: "DELETE FROM \(t)") }
        }
    }
}

public enum StoreError: LocalizedError {
    case missingJob(String), outdated, changed, keyMissing, keyUnavailable, encryptionFailed
    public var errorDescription: String? {
        switch self {
        case .missingJob(let id): "That role (\(id)) no longer exists."
        case .outdated: "Offerlane's data needs an update. Open Offerlane once, then try again."
        case .changed: "That role changed while the draft was being saved (it may have been tailored meanwhile). Nothing was replaced."
        case .keyMissing: "Offerlane's data is locked and its key is missing from your Mac's Keychain. To get it back, restore a backup: Settings → Your data → Restore from Backup…."
        case .keyUnavailable: "Offerlane couldn't read its key from your Mac's Keychain. Unlock your Mac and allow access when macOS asks, then try again. Nothing was changed."
        case .encryptionFailed: "Offerlane couldn't secure your data, so nothing was changed and your data is safe. Restart Offerlane to try again; if it keeps happening, use Help → Send Diagnostics."
        }
    }
}
