import CommonCrypto
import CryptoKit
import Foundation
import GRDB
import ZIPFoundation

public enum BackupError: Error, LocalizedError, Equatable {
    case weakPassphrase, wrongPassphrase, damaged, notABackup, diskFull, failed(String)
    public var errorDescription: String? {
        switch self {
        case .weakPassphrase: "Use a passphrase of at least \(Backup.minPassphrase) characters. Write it down: without it the backup can't be opened."
        case .wrongPassphrase: "That passphrase doesn't open this backup. Check it and try again."
        case .damaged: "This backup is damaged or was changed after it was made, so Offerlane won't restore it. Your current data is unchanged."
        case .notABackup: "This isn't an Offerlane backup file. Choose a file ending in .\(Backup.fileExtension)."
        case .diskFull: "There isn't enough free space. Free up some space or choose another place, then try again."
        case .failed(let why): "The backup didn't work: \(why). Your current data is unchanged."
        }
    }
}

/// One encrypted `.offerlane-backup` file holding a profile's database (resumes, roles, settings) and application folders.
/// Layout: "OFLBACK1" | PBKDF2 rounds (UInt32 BE) | salt (16) | key check (16) | AES-GCM nonce + ciphertext + tag.
/// The first 44 bytes are authenticated as associated data. The key check tells a wrong passphrase apart from a damaged file.
/// Restore never overwrites live data: `stageRestore` checks the backup into `.restore-staged-<id>` in the profile folder,
/// `confirmRestore` (the user's click) marks it pending, and the swap happens the next time the profile opens (`openStore`);
/// the replaced data is moved to a "Before restore …" folder, not deleted. Unconfirmed staged copies are removed on open.
public enum Backup {
    public static let fileExtension = "offerlane-backup"
    // SHORTCUT: PBKDF2-SHA256 (built into macOS) rather than a memory-hard KDF like scrypt/Argon2; upgrade if a vetted dependency is approved.
    public static let defaultRounds: UInt32 = 600_000
    public static let minPassphrase = 10
    static let magic = Data("OFLBACK1".utf8)
    static let headerSize = 44
    static let pendingName = ".restore-pending"
    static let keptPrefix = "Before restore"

    public struct Summary: Equatable, Sendable {
        public var created = "", roles = 0, resumes = 0
        /// Folder (in the profile folder) holding the checked backup until `confirmRestore`.
        public var stagedName = ""
    }
    struct Manifest: Codable { var format = 1, created = Dates.now(), app = OfferlaneCore.version }

    public static func hasPendingRestore(in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(pendingName).path)
    }

    /// Writes the encrypted backup of `store` (+ `root/Applications`) to `file`. All in memory, written atomically.
    // SHORTCUT: whole backup held in memory; switch to chunked encryption if backups grow past a few hundred MB.
    public static func create(store: Store, root: URL, to file: URL, passphrase: String, rounds: UInt32 = defaultRounds,
                              write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        guard passphrase.count >= minPassphrase else { throw BackupError.weakPassphrase }
        let fm = FileManager.default
        // Plaintext work files stay in the profile folder (not /tmp), so a crash leaves them where Delete All My Data looks.
        let work = root.appendingPathComponent(".restore-work-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let plain: Data
        do {
            let stage = work.appendingPathComponent("stage", isDirectory: true)
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            // Consistent snapshot, unencrypted inside the backup: the backup's own passphrase protects it and it must
            // restore on another Mac, where this Mac's database key doesn't exist.
            try Encryption.export(store.db, to: stage.appendingPathComponent("offerlane.sqlite"), key: nil)
            let apps = root.appendingPathComponent("Applications")
            if fm.fileExists(atPath: apps.path) { try fm.copyItem(at: apps, to: stage.appendingPathComponent("Applications")) }
            try JSONCoding.encoder.encode(Manifest()).write(to: stage.appendingPathComponent("manifest.json"))
            let zip = work.appendingPathComponent("b.zip")
            try fm.zipItem(at: stage, to: zip, shouldKeepParent: false)
            plain = try Data(contentsOf: zip)
        } catch { throw mapped(error) }

        let salt = random(16), key = try deriveKey(passphrase, salt: salt, rounds: rounds)
        var header = magic
        withUnsafeBytes(of: rounds.bigEndian) { header.append(contentsOf: $0) }
        header += salt + check(key)
        let sealed: Data
        do { sealed = try AES.GCM.seal(plain, using: key, authenticating: header).combined! } catch { throw BackupError.failed("encryption failed") }
        do { try write(header + sealed, file) } catch { throw mapped(error) }
    }

    /// Decrypts and checks `file`, then stages it in `root` for the next open. Changes nothing else.
    @discardableResult
    public static func stageRestore(_ file: URL, passphrase: String, into root: URL) throws -> Summary {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: file), data.count > headerSize + 28, data.prefix(8) == magic else { throw BackupError.notABackup }
        let header = data.prefix(headerSize)
        let rounds = header.subdata(in: 8..<12).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard (1...10_000_000).contains(rounds) else { throw BackupError.damaged }
        let key = try deriveKey(passphrase, salt: header.subdata(in: 12..<28), rounds: rounds)
        guard check(key) == header.subdata(in: 28..<44) else { throw BackupError.wrongPassphrase }
        let plain: Data
        do { plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(headerSize)), using: key, authenticating: header) }
        catch { throw BackupError.damaged }

        let id = UUID().uuidString
        let staging = root.appendingPathComponent(".restore-staging-\(id)", isDirectory: true)
        let zip = root.appendingPathComponent(".restore-work-\(id).zip")
        defer { try? fm.removeItem(at: zip); try? fm.removeItem(at: staging) }
        do {
            try plain.write(to: zip)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try fm.unzipItem(at: zip, to: staging)   // ZIPFoundation refuses entries that point outside `staging`
        } catch { throw mapped(error) }

        let db = staging.appendingPathComponent("offerlane.sqlite")
        var summary = Summary()
        do {
            let q = try DatabaseQueue(path: db.path)
            guard try q.read({ try String.fetchOne($0, sql: "PRAGMA integrity_check") }) == "ok" else { throw BackupError.damaged }
            try q.close()
            let s = try Store(url: db)   // also migrates a backup made by an older version
            summary.roles = try s.jobs().count; summary.resumes = try s.resumeVersions().count
            _ = try s.db.writeWithoutTransaction { try $0.checkpoint(.truncate) }   // migration writes into the main file
            try s.db.close()
        } catch let e as BackupError { throw e } catch { throw BackupError.damaged }
        if let m = try? JSONCoding.decoder.decode(Manifest.self, from: Data(contentsOf: staging.appendingPathComponent("manifest.json"))) { summary.created = m.created }

        summary.stagedName = ".restore-staged-\(id)"
        do { try fm.moveItem(at: staging, to: root.appendingPathComponent(summary.stagedName)) } catch { throw mapped(error) }
        return summary
    }

    /// The user confirmed: the checked backup replaces this profile's data the next time it opens.
    public static func confirmRestore(_ s: Summary, in root: URL) throws {
        let fm = FileManager.default, pending = root.appendingPathComponent(pendingName)
        guard s.stagedName.hasPrefix(".restore-staged-"), fm.fileExists(atPath: root.appendingPathComponent(s.stagedName).path) else { throw BackupError.failed("the checked backup is gone; check it again") }
        try? fm.removeItem(at: pending)
        do { try fm.moveItem(at: root.appendingPathComponent(s.stagedName), to: pending) } catch { throw mapped(error) }
    }

    /// Opens the profile's database, first swapping in a confirmed restore and removing unconfirmed or abandoned work.
    /// An unencrypted database (from v3 or a restored backup) is encrypted first, with the key from `secrets`.
    public static func openStore(root: URL, secrets: any SecretStore) throws -> Store {
        try Encryption.recover(root.appendingPathComponent("offerlane.sqlite"))
        try finishPendingRestore(in: root)
        for u in leftovers(in: root) where u.lastPathComponent.hasPrefix(".restore-") { try? FileManager.default.removeItem(at: u) }
        let url = root.appendingPathComponent("offerlane.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = try Encryption.key(for: url, in: secrets)
        try Encryption.encryptIfNeeded(url, key: key)
        let store = try Store(url: url, key: key)
        Encryption.finish(url)
        // Copies kept by a restore before encryption existed are encrypted too, so no readable copy stays behind.
        for kept in leftovers(in: root) where kept.lastPathComponent.hasPrefix(keptPrefix) {
            let old = kept.appendingPathComponent("offerlane.sqlite")
            if FileManager.default.fileExists(atPath: old.path), Encryption.isReadable(old) {
                do { try Encryption.encryptIfNeeded(old, key: key); Encryption.finish(old) } catch { Log.error("encryption: kept copy: \(error)") }
            }
        }
        return store
    }

    /// Moves the current database and application folders to "Before restore <time>", then the staged ones in.
    static func finishPendingRestore(in root: URL) throws {
        let fm = FileManager.default, pending = root.appendingPathComponent(pendingName)
        guard fm.fileExists(atPath: pending.path) else { return }
        let names = ["offerlane.sqlite", "offerlane.sqlite-wal", "offerlane.sqlite-shm", "Applications"]
        var kept: URL?
        func keep(_ cur: URL) throws {
            if kept == nil {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH-mm-ss"
                var k = root.appendingPathComponent("\(keptPrefix) \(f.string(from: Date()))", isDirectory: true)
                if fm.fileExists(atPath: k.path) { k = root.appendingPathComponent("\(k.lastPathComponent) \(UUID().uuidString.prefix(4))") }
                try fm.createDirectory(at: k, withIntermediateDirectories: true); kept = k
            }
            try fm.moveItem(at: cur, to: kept!.appendingPathComponent(cur.lastPathComponent))
        }
        // Restartable: the current data moves out only while the restored database is still waiting in pending.
        // If an earlier swap stopped after moving it in, the rest of pending just follows it.
        if fm.fileExists(atPath: pending.appendingPathComponent("offerlane.sqlite").path) {
            for name in names where fm.fileExists(atPath: root.appendingPathComponent(name).path) { try keep(root.appendingPathComponent(name)) }
        }
        for name in names where fm.fileExists(atPath: pending.appendingPathComponent(name).path) {
            let dest = root.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) { try keep(dest) }
            try fm.moveItem(at: pending.appendingPathComponent(name), to: dest)
        }
        try fm.removeItem(at: pending)
        Log.info("restore: backup swapped in" + (kept.map { "; previous data kept in \($0.lastPathComponent)" } ?? ""))
    }

    /// Restore leftovers ("Before restore …" copies, a staged restore) that "Delete all my data" must remove too.
    public static func leftovers(in root: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(keptPrefix) || $0.lastPathComponent.hasPrefix(".restore-") || $0.lastPathComponent.hasPrefix(".encrypt-") }
    }

    // MARK: crypto

    static func deriveKey(_ passphrase: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        var out = Data(count: 32)
        let pw = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        let status = out.withUnsafeMutableBytes { o in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { CChar(bitPattern: $0) }, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                     rounds, o.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        guard status == kCCSuccess else { throw BackupError.failed("key derivation failed") }
        return SymmetricKey(data: out)
    }

    static func check(_ key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("offerlane-backup-key-check".utf8), using: key)).prefix(16)
    }

    static func random(_ n: Int) -> Data { Data(SymmetricKey(size: .init(bitCount: n * 8)).withUnsafeBytes { Array($0) }) }

    static func mapped(_ error: Error) -> BackupError {
        if let e = error as? BackupError { return e }
        let ns = error as NSError
        if ns.code == NSFileWriteOutOfSpaceError || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
            || (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ENOSPC) { return .diskFull }
        return .failed(ns.localizedDescription)
    }
}
