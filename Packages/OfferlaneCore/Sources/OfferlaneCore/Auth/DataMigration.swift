import Foundation

/// Moves v0.1 data (which lived directly in the base folder) into the first account, after taking a backup.
public enum LegacyData {
    static let items = ["offerlane.sqlite", "offerlane.sqlite-wal", "offerlane.sqlite-shm", "Applications", "sponsors"]

    /// v0.1 data is on this Mac and hasn't been claimed by an account yet.
    public static func available(base: URL = Paths.base, accounts: AccountStore) -> Bool {
        !accounts.legacyClaimed && FileManager.default.fileExists(atPath: base.appendingPathComponent("offerlane.sqlite").path)
    }

    public struct Report: Sendable, Equatable {
        public var backup: URL
        public var roles: Int
        public var secrets: Int
    }

    /// 1. copy everything to Backups/v0.1-<time>/  2. move it into accounts/<id>/  3. move its Keychain items
    /// 4. open the moved database to prove it works  5. record that the data was claimed.
    public static func claim(into id: String, base: URL = Paths.base, accounts: AccountStore,
                             legacyKeychain: Keychain = Keychain(service: Paths.keychainService(for: nil))) throws -> Report {
        let fm = FileManager.default
        let stamp = Dates.now().replacingOccurrences(of: ":", with: "-")
        let backup = base.appendingPathComponent("Backups/v0.1-\(stamp)", isDirectory: true)
        let dest = Paths.accountRoot(id, base: base)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let present = items.filter { fm.fileExists(atPath: base.appendingPathComponent($0).path) }
        for name in present { try fm.copyItem(at: base.appendingPathComponent(name), to: backup.appendingPathComponent(name)) }
        if present.contains("offerlane.sqlite") {   // the account's own WAL/SHM must not sit beside a different database
            for n in ["offerlane.sqlite-wal", "offerlane.sqlite-shm"] { try? fm.removeItem(at: dest.appendingPathComponent(n)) }
        }
        for name in present {
            let target = dest.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: base.appendingPathComponent(name), to: target)
        }
        let accountKeychain = Keychain(service: Paths.keychainService(for: id))
        let secrets = try legacyKeychain.copyAll(to: accountKeychain)
        // The moved database keeps its own key (copied above); an unencrypted one is encrypted when the account opens.
        let moved = dest.appendingPathComponent("offerlane.sqlite")
        let store = try Store(url: moved, key: Encryption.isReadable(moved) ? nil : Encryption.storedKey(accountKeychain))
        let roles = (try? store.jobs().count) ?? 0
        legacyKeychain.deleteAll()
        if var a = accounts.account(id) { a.claimedLegacy = true; try accounts.save(a) }
        try accounts.markLegacyClaimed()
        return Report(backup: backup, roles: roles, secrets: secrets)
    }

    /// Backups of v0.1 data (a full copy of the old database and PDFs).
    public static func backups(base: URL = Paths.base) -> [URL] {
        let dir = base.appendingPathComponent("Backups", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("v0.1-") }
    }

    /// How long a v0.1 claim copy is kept. It is unencrypted, so a week, not a month (human decision, P1.10).
    public static let keepDays = 7

    /// Deletes v0.1 backups older than `days` (all of them with `days: 0`). Returns how many were removed.
    @discardableResult
    public static func removeBackups(olderThanDays days: Int = keepDays, base: URL = Paths.base, now: Date = Date()) -> Int {
        var n = 0
        for b in backups(base: base) {
            let created = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if days == 0 || now.timeIntervalSince(created) > Double(days) * 86_400 { if (try? FileManager.default.removeItem(at: b)) != nil { n += 1 } }
        }
        return n
    }

    /// The user chose "Start fresh": keep the old data where it is, but stop asking.
    public static func decline(accounts: AccountStore) throws { try accounts.markLegacyClaimed() }
}
