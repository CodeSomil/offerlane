import Foundation

/// Settings → Export everything / Delete all my data.
public enum DataTools {
    /// Writes a self-contained folder: JSON for every document and role (with events), resume versions, application PDFs.
    @discardableResult
    public static func export(store: Store, to dir: URL) throws -> URL {
        let out = dir.appendingPathComponent("Offerlane Export \(Dates.today())", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let enc = JSONCoding.encoder
        try enc.encode(try store.profile()).write(to: out.appendingPathComponent("profile.json"))
        try enc.encode(try store.search()).write(to: out.appendingPathComponent("search.json"))
        try enc.encode(try store.settings()).write(to: out.appendingPathComponent("settings.json"))
        struct JobsDoc: Encodable { let jobs: [Job]; let events: [JobEvent] }
        try enc.encode(JobsDoc(jobs: try store.jobs(), events: try store.events(limit: 100_000))).write(to: out.appendingPathComponent("jobs.json"))
        try enc.encode(try store.accounts()).write(to: out.appendingPathComponent("accounts.json"))
        try enc.encode(try store.usage(days: 3650)).write(to: out.appendingPathComponent("usage.json"))
        let rdir = out.appendingPathComponent("resumes", isDirectory: true)
        for v in try store.resumeVersions() {
            let d = rdir.appendingPathComponent(v.name, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try enc.encode(v.content).write(to: d.appendingPathComponent("resume.json"))
            try v.sourceText.write(to: d.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
            if let t = v.templateTex { try t.write(to: d.appendingPathComponent("template.tex"), atomically: true, encoding: .utf8) }
        }
        if FileManager.default.fileExists(atPath: Paths.applications.path) {
            try FileManager.default.copyItem(at: Paths.applications, to: out.appendingPathComponent("Applications"))
        }
        try "Exported by Offerlane on \(Dates.now()). Passwords are not included; they stay in your Mac's Keychain.\n"
            .write(to: out.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        return out
    }

    /// Removes the database contents, every Keychain item, application folders, sponsor lists and logs.
    public static func deleteAll(store: Store, keychain: Keychain) throws {
        try store.eraseEverything()
        keychain.deleteAll()
        for d in [Paths.applications, Paths.sponsors, Paths.logs] { try? FileManager.default.removeItem(at: d) }
        try Paths.ensure()
    }
}
