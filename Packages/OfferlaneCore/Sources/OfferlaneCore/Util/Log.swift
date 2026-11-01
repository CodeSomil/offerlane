import Foundation
import os

/// Logs to the unified log and ~/Library/Logs/Offerlane/offerlane.log, with emails, phone numbers and
/// secrets-looking strings redacted.
public enum Log {
    static let logger = Logger(subsystem: "com.somilmanke.Offerlane", category: "app")
    static let queue = DispatchQueue(label: "offerlane.log")

    public static func info(_ m: String) { write("INFO", m) }
    public static func error(_ m: String) { write("ERROR", m) }

    public static func redact(_ s: String) -> String {
        var x = Re.sub("[\\w.+-]+@[\\w-]+\\.[\\w.]+", "<email>", s)
        x = Re.sub("\\+?\\d[\\d ()-]{8,}\\d", "<phone>", x)
        x = Re.sub("sk-ant-[A-Za-z0-9_-]+", "<key>", x)
        return x
    }

    static func write(_ level: String, _ m: String) {
        let line = redact(m)
        logger.log("\(level, privacy: .public) \(line, privacy: .public)")
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        queue.async {
            let url = Paths.logs.appendingPathComponent("offerlane.log")
            try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
            let entry = "\(Dates.now()) \(level) \(line)\n"
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close() }
            else { try? entry.write(to: url, atomically: true, encoding: .utf8) }
        }
    }
}
