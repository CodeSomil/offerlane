import XCTest
@testable import OfferlaneCore

final class BackupTests: XCTestCase {
    var tmp: URL!
    let pass = "correct horse battery staple"
    let rounds: UInt32 = 1_000   // fast in tests; real backups use Backup.defaultRounds

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// A profile folder with a database (one role, one setting) and an application PDF.
    func makeProfile(_ name: String, company: String) throws -> (URL, Store) {
        let root = tmp.appendingPathComponent(name, isDirectory: true)
        let store = try Store(url: root.appendingPathComponent("offerlane.sqlite"))
        _ = try store.upsert(Job(company: company, title: "Engineer", id: "j1"))
        var s = AppSettings(); s.runTokenLimit = 12_345; try store.set(.settings, s)
        let app = root.appendingPathComponent("Applications/\(company)", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("%PDF \(company)".utf8).write(to: app.appendingPathComponent("resume.pdf"))
        return (root, store)
    }

    func testRoundTripStagesThenSwapsInOnNextOpenKeepingOldCopy() throws {
        let (src, store) = try makeProfile("src", company: "Initech")
        let file = tmp.appendingPathComponent("my.offerlane-backup")
        try Backup.create(store: store, root: src, to: file, passphrase: pass, rounds: rounds)
        let bytes = try Data(contentsOf: file)
        XCTAssertNil(bytes.range(of: Data("Initech".utf8)), "nothing readable in the file")
        XCTAssertNil(bytes.range(of: Data("SQLite format".utf8)))

        let (dest, destStore) = try makeProfile("dest", company: "Globex")
        let summary = try Backup.stageRestore(file, passphrase: pass, into: dest)
        XCTAssertEqual(summary.roles, 1)
        try Backup.confirmRestore(summary, in: dest)
        XCTAssertEqual(try destStore.jobs().first?.company, "Globex", "staging alone changes nothing")
        try destStore.db.close()

        let secrets = MemorySecrets()
        let reopened = try Backup.openStore(root: dest, secrets: secrets)
        XCTAssertEqual(try reopened.jobs().map(\.company), ["Initech"])
        XCTAssertEqual(try reopened.settings().runTokenLimit, 12_345)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("Applications/Initech/resume.pdf")), Data("%PDF Initech".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Applications/Globex").path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: dest.path).filter { $0.hasPrefix("Before restore") }
        XCTAssertEqual(kept.count, 1, "the replaced data is kept, never deleted")
        XCTAssertEqual(Backup.leftovers(in: dest).map(\.lastPathComponent), kept, "Delete All My Data removes it too")
        let oldURL = dest.appendingPathComponent(kept[0]).appendingPathComponent("offerlane.sqlite")
        XCTAssertFalse(Encryption.isReadable(oldURL), "the kept copy is encrypted too")
        let old = try Store(url: oldURL, key: Encryption.storedKey(secrets))
        XCTAssertEqual(try old.jobs().first?.company, "Globex")
    }

    func testWrongPassphraseIsPlainAndChangesNothing() throws {
        let (src, store) = try makeProfile("src", company: "Initech")
        let file = tmp.appendingPathComponent("b.offerlane-backup")
        try Backup.create(store: store, root: src, to: file, passphrase: pass, rounds: rounds)
        let (dest, _) = try makeProfile("dest", company: "Globex")
        XCTAssertThrowsError(try Backup.stageRestore(file, passphrase: "wrong", into: dest)) {
            XCTAssertEqual($0 as? BackupError, .wrongPassphrase)
            XCTAssertEqual(($0 as? BackupError)?.errorDescription, "That passphrase doesn't open this backup. Check it and try again.")
        }
        XCTAssertFalse(Backup.hasPendingRestore(in: dest))
    }

    func testTamperedOrForeignFilesAreRejected() throws {
        let (src, store) = try makeProfile("src", company: "Initech")
        let file = tmp.appendingPathComponent("b.offerlane-backup")
        try Backup.create(store: store, root: src, to: file, passphrase: pass, rounds: rounds)
        let (dest, _) = try makeProfile("dest", company: "Globex")
        let good = try Data(contentsOf: file)
        for at in [good.count - 1, good.count / 2, 50] {   // tag, ciphertext, nonce
            var bad = good; bad[at] ^= 0x01; try bad.write(to: file)
            XCTAssertThrowsError(try Backup.stageRestore(file, passphrase: pass, into: dest)) { XCTAssertEqual($0 as? BackupError, .damaged, "byte \(at)") }
        }
        var badSalt = good; badSalt[14] ^= 0x01; try badSalt.write(to: file)   // a changed salt gives a different key
        XCTAssertThrowsError(try Backup.stageRestore(file, passphrase: pass, into: dest)) { XCTAssertEqual($0 as? BackupError, .wrongPassphrase) }
        var badRounds = good; badRounds[11] ^= 0x01; try badRounds.write(to: file)
        XCTAssertThrowsError(try Backup.stageRestore(file, passphrase: pass, into: dest))
        try Data("PK\u{3}\u{4} not a backup".utf8).write(to: file)
        XCTAssertThrowsError(try Backup.stageRestore(file, passphrase: pass, into: dest)) { XCTAssertEqual($0 as? BackupError, .notABackup) }
        XCTAssertFalse(Backup.hasPendingRestore(in: dest))
    }

    func testUnconfirmedRestoreNeverTakesEffect() throws {
        let (src, store) = try makeProfile("src", company: "Initech")
        let file = tmp.appendingPathComponent("b.offerlane-backup")
        try Backup.create(store: store, root: src, to: file, passphrase: pass, rounds: rounds)
        let (dest, destStore) = try makeProfile("dest", company: "Globex")
        _ = try Backup.stageRestore(file, passphrase: pass, into: dest)   // checked, then the user cancels or quits
        XCTAssertFalse(Backup.hasPendingRestore(in: dest))
        try destStore.db.close()
        let reopened = try Backup.openStore(root: dest, secrets: MemorySecrets())
        XCTAssertEqual(try reopened.jobs().map(\.company), ["Globex"])
        XCTAssertEqual(Backup.leftovers(in: dest), [], "the unconfirmed copy is removed on open")
    }

    func testSwapThatStoppedHalfwayFinishesOnNextOpen() throws {
        let (src, store) = try makeProfile("src", company: "Initech")
        let file = tmp.appendingPathComponent("b.offerlane-backup")
        try Backup.create(store: store, root: src, to: file, passphrase: pass, rounds: rounds)
        let (dest, destStore) = try makeProfile("dest", company: "Globex")
        try Backup.confirmRestore(try Backup.stageRestore(file, passphrase: pass, into: dest), in: dest)
        try destStore.db.close()
        // Simulate a swap that stopped after moving the current data out and the restored database in.
        let fm = FileManager.default, pending = dest.appendingPathComponent(".restore-pending")
        let kept = dest.appendingPathComponent("Before restore earlier")
        try fm.createDirectory(at: kept, withIntermediateDirectories: true)
        for n in ["offerlane.sqlite", "offerlane.sqlite-wal", "offerlane.sqlite-shm", "Applications"] where fm.fileExists(atPath: dest.appendingPathComponent(n).path) {
            try fm.moveItem(at: dest.appendingPathComponent(n), to: kept.appendingPathComponent(n))
        }
        try fm.moveItem(at: pending.appendingPathComponent("offerlane.sqlite"), to: dest.appendingPathComponent("offerlane.sqlite"))

        let reopened = try Backup.openStore(root: dest, secrets: MemorySecrets())
        XCTAssertEqual(try reopened.jobs().map(\.company), ["Initech"])
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("Applications/Initech/resume.pdf").path))
        XCTAssertFalse(Backup.hasPendingRestore(in: dest))
        XCTAssertEqual(Backup.leftovers(in: dest).map(\.lastPathComponent), ["Before restore earlier"], "no second copy of the restored data")
    }

    func testDiskFullLeavesNoPartialFile() throws {
        let (src, store) = try makeProfile("src", company: "Initech")
        let file = tmp.appendingPathComponent("full.offerlane-backup")
        let full = { (_: Data, _: URL) throws in throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try Backup.create(store: store, root: src, to: file, passphrase: pass, rounds: rounds, write: full)) {
            XCTAssertEqual($0 as? BackupError, .diskFull)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testShortPassphraseRefused() throws {
        let (src, store) = try makeProfile("src", company: "Initech")
        XCTAssertThrowsError(try Backup.create(store: store, root: src, to: tmp.appendingPathComponent("x"), passphrase: "short", rounds: rounds)) {
            XCTAssertEqual($0 as? BackupError, .weakPassphrase)
        }
    }
}
