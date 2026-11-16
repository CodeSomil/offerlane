import CryptoKit
import Foundation

/// The Mac's data as the web's sync JSON (apps/web/src/sync.ts SYNCED), so every client opens the same blobs:
/// - `profile`: the Profile document (same snake_case shape as libs/core models.ts).
/// - `resumes`: the default ResumeVersion (the web has one resume). Mac-only fields (template_tex, template) are kept on a pull.
/// - `applications`: `{ <job id>: { job, status, score, created, updated, plan?, answers? } }` (web jobs.ts `Saved`), for every
///   job the user acted on (status ≠ found) plus every id that came from sync. Times on the wire are UTC ISO; the Mac keeps local time.
///   Mac-only job fields (notes, folder, events, …) stay here; a pull only updates the fields the web has.
public final class StoreSyncLocal: SyncLocal {
    let store: Store
    public init(store: Store) { self.store = store }

    /// What sync last stored per synced job: the record as it was (so keys the Mac doesn't model, like plan/answers, survive and
    /// go back out verbatim) and the job's local `updated` at that moment (unchanged since → the record is sent back as it was).
    /// An array, not an id-keyed map: the Store's snake_case coder would rewrite dictionary keys.
    struct Record: Codable { var id: String; var json: String; var stamp: String }
    struct Backup: Codable { var kind: String; var saved: String; var json: String }

    public func loadState() throws -> SyncState? { try store.get(.syncState) }
    public func saveState(_ state: SyncState?) throws {
        if let state { try store.set(.syncState, state) } else { try store.delete(.syncState) }
    }
    public func backup(_ kind: String, _ value: Any, saved: String) throws {
        // SHORTCUT: as on the web, no restore UI for these yet; the last one per kind is kept in the database.
        var all: [Backup] = try store.get(.syncBackups) ?? []
        all.removeAll { $0.kind == kind }
        all.append(.init(kind: kind, saved: saved, json: SyncEngine.canon(value)))
        try store.set(.syncBackups, all)
    }

    public func read(_ kind: String) throws -> Any? {
        switch kind {
        case "profile": return try store.get(.profile, as: Profile.self).map(Self.json)
        case "resumes": return try store.resume().map(Self.json)
        case "applications": return try applications()
        default: return nil
        }
    }

    public func update(_ kind: String, _ change: (Any?) -> Any?) throws -> Any? {
        let next = change(try read(kind))
        switch kind {
        case "profile":
            if let p: Profile = Self.decode(next) { try store.set(.profile, p) }
        case "resumes":
            if var r: ResumeVersion = Self.decode(next) {
                let o = next as? [String: Any] ?? [:]
                if let mine = try store.resume(r.name) {
                    if o["template_tex"] == nil { r.templateTex = mine.templateTex }
                    if o["template"] == nil { r.template = mine.template }
                }
                guard ResumeVersion.validName(r.name) else { break }
                try store.saveResume(r)
                try store.setDefaultResume(r.name)
            }
        case "applications":
            try apply(next as? [String: Any] ?? [:])
        default: break
        }
        return try read(kind)
    }

    // MARK: applications

    static let macOwned: Set<String> = ["job", "status", "score", "created", "updated"]

    func applications() throws -> [String: Any] {
        let records: [Record] = try store.get(.syncRecords) ?? []
        let byId = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        var out: [String: Any] = [:]
        for j in try store.jobs() where j.status != .found || byId[j.id] != nil {
            let r = byId[j.id]
            if let r, r.stamp == j.updated, let same = Self.parse(r.json) { out[j.id] = same; continue }
            var rec = (r.flatMap { Self.parse($0.json) } as? [String: Any] ?? [:]).filter { !Self.macOwned.contains($0.key) }
            rec["job"] = Self.wireJob(j)
            rec["status"] = j.status.rawValue
            rec["score"] = j.score
            rec["created"] = Self.utc(j.firstSeen)
            rec["updated"] = Self.utc(j.updated)
            out[j.id] = rec
        }
        // Records the Mac couldn't take in (an unknown status, a broken job) go back out as they came.
        for r in records where out[r.id] == nil { out[r.id] = Self.parse(r.json) }
        return out
    }

    func apply(_ next: [String: Any]) throws {
        let cur = try applications()
        var records: [Record] = try store.get(.syncRecords) ?? []
        for (id, value) in next where SyncEngine.canon(value) != SyncEngine.canon(cur[id]) {
            guard let rec = value as? [String: Any] else { continue }
            var stamp = ""
            if let w = rec["job"] as? [String: Any], (w["id"] as? String) == id, let status = (rec["status"] as? String).flatMap(JobStatus.init(rawValue:)) {
                let updated = Self.local(rec["updated"] as? String ?? "")
                var j = try store.job(id) ?? {
                    var n = Job(company: "", title: "", id: id)
                    n.firstSeen = Self.local(rec["created"] as? String ?? ""); n.lastSeen = n.firstSeen
                    n.localScore = rec["score"] as? Double
                    n.source = "sync"
                    return n
                }()
                let old = j.status
                Self.takeWire(w, into: &j)
                j.status = status
                j.updated = updated.isEmpty ? Dates.now() : updated
                if status.isHidden { j.stripForHiding() }
                try store.save(j)
                if old != status { try store.addEvent(id, status: status.rawValue, source: "sync", detail: "") }
                stamp = j.updated
            }
            records.removeAll { $0.id == id }
            records.append(.init(id: id, json: SyncEngine.canon(rec), stamp: stamp))
        }
        try store.set(.syncRecords, records)
    }

    /// libs/core models.ts `Job`: the fields every client has.
    static func wireJob(_ j: Job) -> [String: Any] {
        ["id": j.id, "company": j.company, "title": j.title, "location": j.location, "url": j.url, "apply_url": j.applyUrl,
         "ats": j.ats, "ats_slug": j.atsSlug, "posted": j.posted as Any? ?? NSNull(), "description": j.description, "visa": j.visa,
         "min_years": j.minYears as Any? ?? NSNull(), "variant": j.variant, "tailor_note": j.tailorNote]
    }
    static func takeWire(_ w: [String: Any], into j: inout Job) {
        let s = { (k: String) in w[k] as? String ?? "" }
        j.company = s("company"); j.title = s("title"); j.location = s("location"); j.url = s("url"); j.applyUrl = s("apply_url")
        j.ats = s("ats"); j.atsSlug = s("ats_slug"); j.posted = w["posted"] as? String; j.description = String(s("description").prefix(8000))
        j.visa = s("visa"); j.minYears = w["min_years"] as? Int; j.variant = s("variant"); j.tailorNote = s("tailor_note")
    }

    // MARK: helpers

    static func json<T: Encodable>(_ v: T) -> Any? { (try? JSONCoding.encoder.encode(v)).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
    static func decode<T: Decodable>(_ v: Any?) -> T? {
        guard let v, !(v is NSNull), let d = try? JSONSerialization.data(withJSONObject: v) else { return nil }
        return try? JSONCoding.decoder.decode(T.self, from: d)
    }
    static func parse(_ s: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed) }

    static let isoMs: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    static let iso = ISO8601DateFormatter()
    /// The Mac's local "yyyy-MM-dd'T'HH:mm:ss" → UTC ISO with milliseconds (what the web writes and compares).
    static func utc(_ local: String) -> String { Dates.isoSeconds.date(from: local).map(isoMs.string(from:)) ?? local }
    static func local(_ utc: String) -> String { (isoMs.date(from: utc) ?? iso.date(from: utc)).map { Dates.now($0) } ?? "" }
}

/// The account key in the Keychain (login keychain until the Developer ID exists; see Keychain.Protection).
extension Keychain: SyncKeyStore {
    static func syncAccount(_ userId: String) -> String { "sync-account-key:\(userId)" }
    public func load(userId: String) -> SymmetricKey? {
        get(account: Self.syncAccount(userId)).flatMap { Data(base64Encoded: $0) }.flatMap { $0.count == 32 ? SymmetricKey(data: $0) : nil }
    }
    public func save(_ key: SymmetricKey, userId: String) throws {
        try set(key.withUnsafeBytes { Data($0) }.base64EncodedString(), account: Self.syncAccount(userId))
    }
    public func delete(userId: String) { delete(account: Self.syncAccount(userId)) }
}
