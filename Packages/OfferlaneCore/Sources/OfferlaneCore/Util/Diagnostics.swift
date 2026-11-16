import Foundation

/// "Send diagnostics": a plain-text report a user can read in full before sharing.
/// It never contains resumes, job descriptions, form answers, passwords, keys, tokens or contact details.
public enum Diagnostics {
    public struct Info: Sendable {
        public var appVersion = OfferlaneCore.version
        public var macOS = ProcessInfo.processInfo.operatingSystemVersionString
        public var chip = SystemCheck.chip.rawValue
        public var translated = SystemCheck.isTranslated
        public var ramGB = Int(SystemCheck.ramBytes / 1_073_741_824)
        public var freeDisk = SystemCheck.gb(SystemCheck.freeDiskBytes())
        public var provider = ""
        public var model = ""
        public var signIn = ""            // "google" / "password" / "none"
        public var emailTracking = ""     // "off" / "imap" / "gmail"
        public var counts: [String: Int] = [:]
        public var health: [Health.Item] = []
        public init() {}
    }

    /// Builds the report. `known` lists strings that must never appear (the user's name, emails, phone…).
    public static func report(_ i: Info, log: String, known: [String] = [], now: String = Dates.now()) -> String {
        var lines = [
            "Offerlane diagnostics",
            "Created: \(now)",
            "",
            "App: \(i.appVersion)",
            "macOS: \(i.macOS)",
            "Chip: \(i.chip)\(i.translated ? " (running under Rosetta)" : "") · Memory: \(i.ramGB) GB · Free disk: \(i.freeDisk)",
            "AI: \(i.provider.isEmpty ? "none" : i.provider)\(i.model.isEmpty ? "" : " · \(i.model)")",
            "Sign-in: \(i.signIn) · Email tracking: \(i.emailTracking)",
            "Counts: " + i.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "),
            "",
            "Checks:",
        ]
        lines += i.health.map { "- \($0.title): \(String(describing: $0.status)) · \($0.message)" }
        lines += ["", "Recent log (last \(maxLogLines) lines, personal details removed):"]
        let tail = log.split(separator: "\n", omittingEmptySubsequences: true).suffix(maxLogLines).joined(separator: "\n")
        lines.append(tail.isEmpty ? "(empty)" : tail)
        return redact(lines.joined(separator: "\n"), known: known)
    }

    public static let maxLogLines = 200

    /// Everything `Log.redact` removes, plus home-folder paths, URL paths and queries, bearer and OAuth tokens,
    /// long random-looking strings, and any of the `known` personal strings.
    public static func redact(_ s: String, known: [String] = []) -> String {
        var x = Log.redact(s)   // emails, phones and keys first, so a name inside an email doesn't break it apart
        for k in known.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ $0.count >= 3 }).sorted(by: { $0.count > $1.count }) {
            x = x.replacingOccurrences(of: k, with: "<personal>", options: [.caseInsensitive])
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        x = x.replacingOccurrences(of: home, with: "~")
        x = Re.sub("/Users/[^/\\s]+", "/Users/<user>", x)
        x = Re.sub("(?i)(bearer|authorization:?|token[\"']?\\s*[:=])\\s*[\"']?[A-Za-z0-9._~+/=-]{8,}", "$1 <secret>", x)
        x = Re.sub("ya29\\.[A-Za-z0-9._-]+", "<secret>", x)
        x = Re.sub("1//[A-Za-z0-9._-]{10,}", "<secret>", x)
        x = Re.sub("(?i)(password|passwd|secret|api[_-]?key)([\"']?\\s*[:=]\\s*)[\"']?[^\\s\"',}]+", "$1$2<secret>", x)
        // Keep which site a URL was on, drop the rest (paths and queries can carry names and tokens).
        x = Re.sub("(https?://[A-Za-z0-9.-]+)(:[0-9]+)?[^\\s\"'<>)]*", "$1/…", x)
        x = Re.sub("(?=[A-Za-z0-9+_=-]{32,})(?=[A-Za-z+_=-]*[0-9])[A-Za-z0-9+_=-]{32,}", "<secret>", x)
        return x
    }

    /// The last part of the app log, if there is one.
    public static func logTail(maxBytes: Int = 64 << 10) -> String {
        let url = Paths.logs.appendingPathComponent("offerlane.log")
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        return String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
    }
}
