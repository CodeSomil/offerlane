import Foundation
import CryptoKit

/// Where everything the user owns lives: ~/Library/Application Support/Offerlane (override with OFFERLANE_HOME for tests).
/// Each signed-in account has its own folder, `accounts/<id>/`; v0.1 data sits directly in the base folder until it is claimed.
public enum Paths {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _account: String?

    /// The signed-in account; nil means the base folder (v0.1 layout, tests, self-tests).
    public static var account: String? {
        get { lock.withLock { _account } }
        set { lock.withLock { _account = newValue } }
    }
    public static var base: URL {
        if let home = TestHooks.env["OFFERLANE_HOME"] { return URL(fileURLWithPath: home, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Offerlane", isDirectory: true)
    }
    public static func accountRoot(_ id: String, base: URL = Paths.base) -> URL {
        base.appendingPathComponent("accounts", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }
    /// Keychain service holding one account's secrets (AI key, mail password, career-site passwords).
    public static func keychainService(for id: String?) -> String {
        (id.map { "com.somilmanke.Offerlane.acct.\($0)" } ?? "com.somilmanke.Offerlane") + testNamespace
    }
    /// With OFFERLANE_HOME set (tests, self-tests) every Keychain service gets a suffix unique to that folder,
    /// so automated runs can never read, move or delete the real user's secrets.
    public static var testNamespace: String {
        guard let home = TestHooks.env["OFFERLANE_HOME"] else { return "" }
        var h: UInt64 = 0xcbf29ce484222325
        for b in home.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return ".home-" + String(h, radix: 16)
    }
    /// Browser storage (career-site cookies) for the apply window, one per account.
    public static func webStoreID(for id: String?, legacy: Bool) -> UUID {
        let legacyID = UUID(uuidString: "6A0B3C1E-5D2F-4E8A-9B7C-1F2E3D4C5B6A")!
        guard let id, !legacy else { return legacyID }
        var b = [UInt8](SHA256.hash(data: Data(("offerlane-web|" + id + testNamespace).utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50; b[8] = (b[8] & 0x3F) | 0x80        // RFC 4122 name-based layout
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
    public static var root: URL { account.map { accountRoot($0) } ?? base }
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
    public static let version = "0.3.0"
}

/// Test switches (OFFERLANE_* environment variables: fake AI, skip sign-in, another data folder, another LaTeX engine…).
/// They only exist in Debug builds: a shipped app ignores them, so nobody can launch it in a mode that skips the lock
/// or reads its secrets through a test path.
public enum TestHooks {
    /// Read fresh each time (not cached): tests set OFFERLANE_HOME in setUp, and a value cached before that pointed
    /// later tests at the real user's folder and Keychain.
    public static var env: [String: String] {
        #if DEBUG
        return ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("OFFERLANE_") }
        #else
        return [:]
        #endif
    }
}
