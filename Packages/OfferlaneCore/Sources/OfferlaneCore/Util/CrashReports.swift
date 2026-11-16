import Foundation

/// Opt-in crash reports (off by default). macOS already writes a crash file (`.ips`) for every crash; when the user has
/// opted in, Offerlane turns the ones written after that moment into short reports in a local outbox. A report keeps
/// only a whitelist of technical fields (versions, exception type, the crashed thread's code symbols and library names)
/// and then goes through `Diagnostics.redact`. Messages, paths, thread names, environment and memory details are
/// never copied, so resume, job and email text can't get in. Nothing is uploaded: the outbox is a folder the user opens.
public enum CrashReports {
    public static var outbox: URL { Paths.logs.appendingPathComponent("CrashOutbox", isDirectory: true) }
    public static var systemReports: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
    }
    static let maxFrames = 40

    /// A redacted report for one Offerlane `.ips` crash file, or nil if it isn't one.
    public static func summarize(ips: String, known: [String] = []) -> String? {
        let parts = ips.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let header = try? JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any],
              header["app_name"] as? String == "Offerlane",
              let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any] else { return nil }
        let str = { (d: [String: Any]?, k: String) in d?[k] as? String ?? "?" }
        let exc = body["exception"] as? [String: Any]
        var lines = [
            "Offerlane crash report",
            "App: \(str(header, "app_version")) (\(str(header, "build_version"))) · \(str(header, "os_version")) · CPU: \(str(body, "cpuType"))",
            "Exception: \(str(exc, "type")) (\(str(exc, "signal")))",
            "Crashed thread:",
        ]
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let crashed = threads.first { $0["triggered"] as? Bool == true } ?? (body["faultingThread"] as? Int).flatMap { threads.indices.contains($0) ? threads[$0] : nil }
        for (i, f) in (crashed?["frames"] as? [[String: Any]] ?? []).prefix(maxFrames).enumerated() {
            let image = (f["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "?"
            let symbol = (f["symbol"] as? String).map { String($0.prefix(200)) } ?? "+\(f["imageOffset"] as? Int ?? 0)"
            lines.append("\(i) \(image)  \(symbol)")
        }
        return Diagnostics.redact(lines.joined(separator: "\n"), known: known)
    }

    /// Turns Offerlane crash files modified at or after `since` (the moment the user opted in) into outbox reports,
    /// once each. Returns the new reports.
    @discardableResult
    public static func collect(since: Date, from dir: URL = systemReports, into out: URL = outbox, known: [String] = []) -> [URL] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var written: [URL] = []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where f.pathExtension == "ips" && f.lastPathComponent.hasPrefix("Offerlane") {
            guard let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m >= since else { continue }
            let dest = out.appendingPathComponent(f.deletingPathExtension().lastPathComponent + ".txt")
            guard !fm.fileExists(atPath: dest.path), let text = try? String(contentsOf: f, encoding: .utf8),
                  let report = summarize(ips: text, known: known) else { continue }
            do {
                try fm.createDirectory(at: out, withIntermediateDirectories: true)
                try Data(report.utf8).write(to: dest, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
                written.append(dest)
            } catch { Log.error("crash report: couldn't write to the outbox") }
        }
        return written
    }
}
