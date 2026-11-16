import Foundation
import CryptoKit
import GRDB

/// Where the database key is kept. `Keychain` in the app; an in-memory stub in tests. The data-protection Keychain
/// and Touch ID binding (blocked on the Developer ID) plug in here without touching the database code.
public protocol SecretStore: Sendable {
    func get(account: String) -> String?
    func set(_ value: String, account: String) throws
    /// Adds a new item; fails if one already exists (so an unreadable item is never replaced).
    func add(_ value: String, account: String) throws
}
extension Keychain: SecretStore {}

/// Database encryption at rest (SQLCipher, v4 P1.7). Each profile has its own random 256-bit key in its own
/// Keychain service; the key never leaves the Keychain except to open the database.
public enum Encryption {
    public static let keyAccount = "database-key"
    static let oldName = ".encrypt-old", workName = ".encrypt-work.sqlite"
    static let sqliteMagic = Data("SQLite format 3\0".utf8)

    /// The key for the database at `url`, created on first use. Refuses to make a new key for a database that is
    /// already encrypted (that data would be lost): the user gets a clear error instead.
    static func key(for url: URL, in secrets: any SecretStore) throws -> Data {
        if let k = storedKey(secrets) { return k }
        guard isReadable(url) else { throw StoreError.keyMissing }
        let k = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
        // Add-only: a read that failed (access denied, locked) must never lead to a new key over the old one.
        do { try secrets.add(hex(k), account: keyAccount) }
        catch let e as KeychainError where e.status == errSecDuplicateItem { throw StoreError.keyUnavailable }
        return k
    }

    public static func storedKey(_ secrets: any SecretStore) -> Data? {
        guard let h = secrets.get(account: keyAccount), h.count == 64 else { return nil }
        var out = Data(); var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }

    /// True for a missing, empty or unencrypted database (one that opens without a key).
    static func isReadable(_ url: URL) -> Bool {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return true }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 16)) ?? Data()
        return head.isEmpty || head == sqliteMagic
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    /// SQLCipher's raw-key form: no key derivation on every connection.
    static func pragmaKey(_ key: Data) -> String { "x'\(hex(key))'" }

    static func configure(_ config: inout Configuration, key: Data) {
        let k = pragmaKey(key)
        config.prepareDatabase { db in try db.usePassphrase(k) }
    }

    /// Writes a consistent copy of `source` to the new file `url`, encrypted with `key` (nil = unencrypted, for backups).
    /// Returns the source's row counts per table, taken in the same transaction as the copy.
    @discardableResult
    static func export(_ source: any DatabaseWriter, to url: URL, key: Data?) throws -> [String: Int] {
        try source.writeWithoutTransaction { db in
            // An explicit KEY is required: without it the copy would silently take the main database's key.
            try db.execute(sql: "ATTACH DATABASE ? AS export KEY ?", arguments: [url.path, key.map(pragmaKey) ?? ""])
            defer { try? db.execute(sql: "DETACH DATABASE export") }
            // IMMEDIATE holds the write lock across processes (offerlane-mcp too), so the copy is one moment in time.
            try db.execute(sql: "BEGIN IMMEDIATE")
            do {
                let n = try counts(db)
                _ = try Row.fetchAll(db, sql: "SELECT sqlcipher_export('export')")
                try db.execute(sql: "COMMIT")
                return n
            } catch { try? db.execute(sql: "ROLLBACK"); throw error }
        }
    }

    /// One-time move of an unencrypted database to an encrypted one, verified before anything is replaced.
    /// 1. finish or undo a move a crash interrupted  2. export to a work file  3. check it (integrity + row counts per table)
    /// 4. move the old files aside, the new one in. The old copy is removed by `finish` once the new one has opened.
    static func encryptIfNeeded(_ url: URL, key: Data) throws {
        let fm = FileManager.default, root = url.deletingLastPathComponent()
        let old = root.appendingPathComponent(oldName, isDirectory: true), work = root.appendingPathComponent(workName)
        let names = [url.lastPathComponent, url.lastPathComponent + "-wal", url.lastPathComponent + "-shm"]
        try recover(url)
        try? fm.removeItem(at: work)
        guard fm.fileExists(atPath: url.path), isReadable(url) else { return }

        let plain = try DatabaseQueue(path: url.path)
        let before = try export(plain, to: work, key: key)
        try plain.close()
        var config = Configuration(); configure(&config, key: key)
        let check = try DatabaseQueue(path: work.path, configuration: config)
        let ok = try check.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") } == "ok"
        let after = try counts(check)
        try check.close()
        guard ok, after == before, !isReadable(work) else {
            try? fm.removeItem(at: work)
            throw StoreError.encryptionFailed
        }
        try? fm.removeItem(at: old)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        for n in names where fm.fileExists(atPath: root.appendingPathComponent(n).path) {
            try fm.moveItem(at: root.appendingPathComponent(n), to: old.appendingPathComponent(n))
        }
        try fm.moveItem(at: work, to: url)
        Log.info("encryption: database encrypted (\(before.values.reduce(0, +)) rows checked)")
    }

    /// Crashed between moving the old database out and the new one in: put the old one back (it is then encrypted again).
    /// Runs before a waiting restore is swapped in, so that original ends up in "Before restore …", not deleted.
    static func recover(_ url: URL) throws {
        let fm = FileManager.default, root = url.deletingLastPathComponent(), old = root.appendingPathComponent(oldName)
        guard !fm.fileExists(atPath: url.path), fm.fileExists(atPath: old.appendingPathComponent(url.lastPathComponent).path) else { return }
        for n in [url.lastPathComponent, url.lastPathComponent + "-wal", url.lastPathComponent + "-shm"]
        where fm.fileExists(atPath: old.appendingPathComponent(n).path) {
            try fm.moveItem(at: old.appendingPathComponent(n), to: root.appendingPathComponent(n))
        }
    }

    /// The encrypted database opened: the unencrypted copy kept during the move is no longer needed.
    static func finish(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(oldName))
    }

    static func counts(_ reader: any DatabaseReader) throws -> [String: Int] { try reader.read { try counts($0) } }
    static func counts(_ db: Database) throws -> [String: Int] {
        let tables = try String.fetchAll(db, sql: "SELECT name FROM main.sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        return try Dictionary(uniqueKeysWithValues: tables.map { t in
            (t, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM main.\(t.quotedDatabaseIdentifier)") ?? 0)
        })
    }
}
