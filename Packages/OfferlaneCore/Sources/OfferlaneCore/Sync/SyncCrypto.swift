import CryptoKit
import Foundation

/// End-to-end encrypted sync, client side (docs/v4/SYNC_CRYPTO.md, D3): a port of libs/core/src/sync.ts on CryptoKit.
/// The shared fixtures in Fixtures/sync prove the two ports open each other's blobs. Nothing here sends a key or plaintext.
public enum SyncCrypto {
    public static let kinds = ["keyring", "profile", "resumes", "applications", "contacts", "settings"]

    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func aad(userId: String, kind: String, version: Int, keyId: String) -> Data {
        Data("offerlane-sync-v1|\(userId)|\(kind)|\(version)|\(keyId)".utf8)
    }

    public static func random(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        precondition(SecRandomCopyBytes(kSecRandomDefault, n, &b) == errSecSuccess)
        return Data(b)
    }
    public static func makeAccountKey() -> SymmetricKey { SymmetricKey(size: .bits256) }
    public static func makeRecoveryKey() -> Data { random(16) }
    public static func makeKeyId() -> String { random(8).map { String(format: "%02x", $0) }.joined() }

    /// 0x01 ‖ nonce (12) ‖ AES-256-GCM ciphertext ‖ tag (16).
    public static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined else {
            throw Failure(message: "Couldn't encrypt this data for sync.")
        }
        return Data([1]) + combined
    }

    public static func open(_ blob: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let b = Data(blob)  // rebase indices to 0
        guard b.count >= 13 + 16, b[0] == 1 else { throw Failure(message: "This synced data isn't in a format this version can read.") }
        do { return try AES.GCM.open(try AES.GCM.SealedBox(combined: b.dropFirst()), using: key, authenticating: aad) }
        catch { throw Failure(message: "This synced data couldn't be decrypted: wrong key, or it was changed.") }
    }

    // RFC 4648 base32 without padding: 16 bytes → 26 letters, shown in groups of 4.
    static let b32 = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    public static func formatRecoveryKey(_ rk: Data) -> String {
        var bits = 0, acc = 0, s = ""
        for b in rk {
            acc = (acc << 8 | Int(b)) & 0xfff; bits += 8
            while bits >= 5 { s.append(b32[(acc >> (bits - 5)) & 31]); bits -= 5 }
        }
        if bits > 0 { s.append(b32[(acc << (5 - bits)) & 31]) }
        return stride(from: 0, to: s.count, by: 4).map { i in
            String(s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: min(i + 4, s.count))])
        }.joined(separator: "-")
    }
    /// Case, spaces and dashes don't matter. Anything else (wrong length, other letters, set padding bits) is nil.
    public static func parseRecoveryKey(_ text: String) -> Data? {
        let s = text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard s.count == 26 else { return nil }
        var out = Data(), bits = 0, acc = 0
        for c in s {
            guard let v = b32.firstIndex(of: c) else { return nil }
            acc = (acc << 5 | v) & 0xfff; bits += 5
            if bits >= 8 { out.append(UInt8((acc >> (bits - 8)) & 255)); bits -= 8 }
        }
        return acc & ((1 << bits) - 1) == 0 ? out : nil
    }

    static func recoveryKEK(_ rk: Data, userId: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: rk), salt: Data(userId.utf8),
                               info: Data("offerlane-recovery-v1".utf8), outputByteCount: 32)
    }
    static func validKeyId(_ s: String) -> Bool { s.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil }

    /// The keyring blob: the raw account key ‖ its key id (ASCII), sealed under the recovery-key KEK (kind "keyring",
    /// blob key id "rk-<n>"), so every device uses the same key id for the same account key.
    public static func wrapAccountKey(_ ak: SymmetricKey, keyId: String, rk: Data, userId: String, version: Int, ringId: String) throws -> Data {
        guard ak.bitCount == 256, validKeyId(keyId) else { throw Failure(message: "Bad account key or key id.") }
        let plain = ak.withUnsafeBytes { Data($0) } + Data(keyId.utf8)
        return try seal(plain, key: recoveryKEK(rk, userId: userId), aad: aad(userId: userId, kind: "keyring", version: version, keyId: ringId))
    }
    public static func unwrapAccountKey(_ ring: Data, rk: Data, userId: String, version: Int, ringId: String) throws -> (key: SymmetricKey, keyId: String) {
        let raw: Data
        do { raw = try open(ring, key: recoveryKEK(rk, userId: userId), aad: aad(userId: userId, kind: "keyring", version: version, keyId: ringId)) }
        catch { throw Failure(message: "That recovery key doesn't open this account's synced data.") }
        let keyId = String(decoding: raw.dropFirst(32), as: UTF8.self)
        guard raw.count >= 33, validKeyId(keyId) else { throw Failure(message: "This account's keyring isn't in a format this version can read.") }
        return (SymmetricKey(data: raw.prefix(32)), keyId)
    }

    /// Record maps (applications): union by id; the newer ISO `updated` wins, local wins a tie. Records are never deleted.
    public static func mergeRecords(local: Any?, remote: Any?) -> [String: Any] {
        var out = remote as? [String: Any] ?? [:]
        let stamp = { (v: Any?) in (v as? [String: Any])?["updated"] as? String ?? "" }
        for (id, l) in local as? [String: Any] ?? [:] where out[id] == nil || stamp(l) >= stamp(out[id]) { out[id] = l }
        return out
    }
}
