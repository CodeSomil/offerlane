import XCTest
import GRDB
@testable import OfferlaneCore

/// In-memory stand-in for the Keychain (no real Keychain writes in these tests).
final class MemorySecrets: SecretStore, @unchecked Sendable {
    private var items: [String: String] = [:]
    private let lock = NSLock()
    func get(account: String) -> String? { lock.withLock { items[account] } }
    func set(_ value: String, account: String) throws { lock.withLock { items[account] = value } }
    func add(_ value: String, account: String) throws {
        try lock.withLock {
            guard items[account] == nil else { throw KeychainError(status: errSecDuplicateItem) }
            items[account] = value
        }
    }
}

/// A Keychain whose item exists but can't be read (access denied).
final class DeniedSecrets: SecretStore, @unchecked Sendable {
    var added = false
    func get(account: String) -> String? { nil }
    func set(_ value: String, account: String) throws { XCTFail("never overwrites") }
    func add(_ value: String, account: String) throws { added = true; throw KeychainError(status: errSecDuplicateItem) }
}

/// v4 P1.7: database encryption at rest (SQLCipher) and the one-time move from an unencrypted database.
final class EncryptionTests: XCTestCase {
    var root: URL!
    var db: URL { root.appendingPathComponent("offerlane.sqlite") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("enc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Every byte on disk for the profile's database (main file + WAL).
    func diskBytes() throws -> Data {
        ["", "-wal"].reduce(into: Data()) { d, s in
            if let x = try? Data(contentsOf: URL(fileURLWithPath: db.path + s)) { d += x }
        }
    }

    func seedPlain() throws {
        let s = try Store(url: db)
        _ = try s.upsert(Job(company: "Initech", title: "Engineer", id: "j1"))
        _ = try s.upsert(Job(company: "Globex", title: "Analyst", id: "j2"))
        var p = Profile(); p.personal.email = "alex.rivera@example.com"; try s.set(.profile, p)
        try s.db.close()
    }

    func testNewDatabaseIsEncryptedWithAStableKey() throws {
        let secrets = MemorySecrets()
        let s = try Backup.openStore(root: root, secrets: secrets)
        _ = try s.upsert(Job(company: "Initech", title: "Engineer", id: "j1"))
        var p = Profile(); p.personal.email = "alex.rivera@example.com"; try s.set(.profile, p)
        try s.db.close()
        let bytes = try diskBytes()
        XCTAssertNil(bytes.range(of: Data("Initech".utf8)), "no readable data on disk")
        XCTAssertNil(bytes.range(of: Data("alex.rivera".utf8)))
        XCTAssertNil(bytes.range(of: Encryption.sqliteMagic), "not an ordinary SQLite file")
        let key = try XCTUnwrap(Encryption.storedKey(secrets)); XCTAssertEqual(key.count, 32)

        let again = try Backup.openStore(root: root, secrets: secrets)
        XCTAssertEqual(try again.jobs().map(\.company), ["Initech"])
        XCTAssertEqual(Encryption.storedKey(secrets), key, "the key is made once")
    }

    func testWrongOrMissingKeyIsRefusedAndNoNewKeyIsMade() throws {
        _ = try Backup.openStore(root: root, secrets: MemorySecrets())   // encrypted with a key that is then "lost"
        let empty = MemorySecrets()
        XCTAssertThrowsError(try Backup.openStore(root: root, secrets: empty)) { XCTAssertTrue($0.plainMessage.contains("Restore from Backup")) }
        XCTAssertNil(empty.get(account: Encryption.keyAccount), "never a new key over encrypted data")
        let wrong = MemorySecrets(); try wrong.set(String(repeating: "ab", count: 32), account: Encryption.keyAccount)
        XCTAssertThrowsError(try Backup.openStore(root: root, secrets: wrong))
        XCTAssertThrowsError(try Store(url: db), "no key: can't be read")
    }

    func testUnencryptedDatabaseMovesOverWithEveryRow() throws {
        try seedPlain()
        let before = try Encryption.counts(DatabaseQueue(path: db.path))
        let s = try Backup.openStore(root: root, secrets: MemorySecrets())
        XCTAssertEqual(try Encryption.counts(s.db), before, "same rows in every table")
        XCTAssertEqual(try s.jobs().map(\.company).sorted(), ["Globex", "Initech"])
        XCTAssertEqual(try s.profile().personal.email, "alex.rivera@example.com")
        XCTAssertFalse(Encryption.isReadable(db))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".encrypt") }, [],
                       "the unencrypted copy is gone once the new one opened")
    }

    func testCrashMidSwapPutsTheOriginalBackAndRetries() throws {
        try seedPlain()
        // Simulate a crash after the original moved aside but before the encrypted copy moved in.
        let fm = FileManager.default, old = root.appendingPathComponent(Encryption.oldName)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.moveItem(at: db, to: old.appendingPathComponent("offerlane.sqlite"))
        try Data("half-written".utf8).write(to: root.appendingPathComponent(Encryption.workName))
        let s = try Backup.openStore(root: root, secrets: MemorySecrets())
        XCTAssertEqual(try s.jobs().count, 2, "nothing lost")
        XCTAssertFalse(Encryption.isReadable(db))
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(Encryption.workName).path))
    }

    func testEncryptingTwiceChangesNothing() throws {
        try seedPlain()
        let secrets = MemorySecrets()
        try Backup.openStore(root: root, secrets: secrets).db.close()
        let first = try Data(contentsOf: db)
        let key = try XCTUnwrap(Encryption.storedKey(secrets))
        try Encryption.encryptIfNeeded(db, key: key)
        XCTAssertEqual(try Data(contentsOf: db), first, "an encrypted database is left alone")
    }

    func testBackupOfEncryptedDataRestoresUnderAnotherKey() throws {
        let s = try Backup.openStore(root: root, secrets: MemorySecrets())
        _ = try s.upsert(Job(company: "Initech", title: "Engineer", id: "j1"))
        let file = root.appendingPathComponent("b.offerlane-backup")
        try Backup.create(store: s, root: root, to: file, passphrase: "correct horse battery staple", rounds: 1_000)
        let other = root.appendingPathComponent("other-mac", isDirectory: true), otherKeys = MemorySecrets()
        try Backup.openStore(root: other, secrets: otherKeys).db.close()
        let summary = try Backup.stageRestore(file, passphrase: "correct horse battery staple", into: other)
        XCTAssertEqual(summary.roles, 1)
        try Backup.confirmRestore(summary, in: other)
        let restored = try Backup.openStore(root: other, secrets: otherKeys)
        XCTAssertEqual(try restored.jobs().map(\.company), ["Initech"])
        XCTAssertFalse(Encryption.isReadable(other.appendingPathComponent("offerlane.sqlite")), "restored data is encrypted again")
    }

    func testUnreadableKeyIsNeverReplaced() throws {
        try seedPlain()
        XCTAssertThrowsError(try Backup.openStore(root: root, secrets: DeniedSecrets())) { XCTAssertTrue($0.plainMessage.contains("Keychain")) }
        XCTAssertTrue(Encryption.isReadable(db), "nothing changed")
    }

    func testRowsOnlyInTheWALMoveOver() throws {
        let q = try DatabasePool(path: db.path)   // WAL mode; keep it open so rows stay in the -wal file
        try q.write { try $0.execute(sql: "CREATE TABLE t(x); INSERT INTO t VALUES (1), (2), (3)") }
        XCTAssertGreaterThan((try? Data(contentsOf: URL(fileURLWithPath: db.path + "-wal")))?.count ?? 0, 0)
        try q.close()
        let s = try Backup.openStore(root: root, secrets: MemorySecrets())
        XCTAssertEqual(try s.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM t") }, 3)
    }

    func testOldPlainCopiesKeptByARestoreAreEncrypted() throws {
        try seedPlain()
        let kept = root.appendingPathComponent("Before restore 2026-01-01 10-00-00")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: db, to: kept.appendingPathComponent("offerlane.sqlite"))
        let secrets = MemorySecrets()
        _ = try Backup.openStore(root: root, secrets: secrets)
        let old = kept.appendingPathComponent("offerlane.sqlite")
        XCTAssertFalse(Encryption.isReadable(old))
        XCTAssertEqual(try Store(url: old, key: Encryption.storedKey(secrets)).jobs().count, 2, "still opens with this profile's key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.appendingPathComponent(Encryption.oldName).path))
    }

    func testInterruptedEncryptionThenRestoreKeepsTheOriginal() throws {
        let src = root.appendingPathComponent("src", isDirectory: true)
        let srcStore = try Store(url: src.appendingPathComponent("offerlane.sqlite"))
        _ = try srcStore.upsert(Job(company: "Restored", title: "Engineer", id: "r1"))
        let file = root.appendingPathComponent("b.offerlane-backup")
        try Backup.create(store: srcStore, root: src, to: file, passphrase: "correct horse battery staple", rounds: 1_000)
        try seedPlain()
        let fm = FileManager.default, old = root.appendingPathComponent(Encryption.oldName)   // encryption stopped mid-swap
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.moveItem(at: db, to: old.appendingPathComponent("offerlane.sqlite"))
        try Backup.confirmRestore(try Backup.stageRestore(file, passphrase: "correct horse battery staple", into: root), in: root)
        let secrets = MemorySecrets()
        let s = try Backup.openStore(root: root, secrets: secrets)
        XCTAssertEqual(try s.jobs().map(\.company), ["Restored"])
        let kept = try XCTUnwrap(Backup.leftovers(in: root).first { $0.lastPathComponent.hasPrefix("Before restore") })
        XCTAssertEqual(try Store(url: kept.appendingPathComponent("offerlane.sqlite"), key: Encryption.storedKey(secrets)).jobs().count, 2,
                       "the original went to Before restore, encrypted, not deleted")
    }

    func testDeleteAllKeepsOnlyTheDatabaseKey() throws {
        let kc = Keychain(service: "com.somilmanke.Offerlane.tests.\(UUID().uuidString)"); defer { kc.deleteAll() }
        try kc.set("sk-secret", account: Keychain.Account.anthropicKey)
        setenv("OFFERLANE_HOME", root.path, 1); defer { unsetenv("OFFERLANE_HOME") }
        let s = try Backup.openStore(root: Paths.root, secrets: kc)
        try DataTools.deleteAll(store: s, keychain: kc)
        XCTAssertEqual(kc.allAccounts(), [Encryption.keyAccount])
        try s.db.close()
        XCTAssertNoThrow(try Backup.openStore(root: Paths.root, secrets: kc), "the emptied database still opens")
    }
}
