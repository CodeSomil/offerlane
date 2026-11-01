import Foundation

/// Where everything the user owns lives: ~/Library/Application Support/Offerlane (override with OFFERLANE_HOME for tests).
public enum Paths {
    public static var root: URL {
        if let home = ProcessInfo.processInfo.environment["OFFERLANE_HOME"] { return URL(fileURLWithPath: home, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Offerlane", isDirectory: true)
    }
    public static var applications: URL { root.appendingPathComponent("Applications", isDirectory: true) }
    /// UK / NL government sponsor registers (only downloaded when the user needs sponsorship).
    public static var sponsors: URL { root.appendingPathComponent("sponsors", isDirectory: true) }
    public static var logs: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Offerlane", isDirectory: true)
    }
    public static func ensure() throws {
        for d in [root, applications, logs] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }
}

public enum OfferlaneCore {
    public static let version = "0.1.0"
}
