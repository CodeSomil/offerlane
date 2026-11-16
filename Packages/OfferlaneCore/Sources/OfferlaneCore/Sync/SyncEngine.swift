import CryptoKit
import Foundation

/// The wire, as the Mac sees it (the HTTP version lives in OfferlaneAPI `SyncHTTP`; tests use a fake).
public struct SyncBlob: Sendable, Equatable {
    public var version: Int, keyId: String, ciphertext: Data
    public init(version: Int, keyId: String, ciphertext: Data) { self.version = version; self.keyId = keyId; self.ciphertext = ciphertext }
}
public enum SyncPut: Sendable, Equatable { case ok(version: Int), conflict }
public protocol SyncRemote: Sendable {
    func me() async throws -> String
    func get(_ kind: String) async throws -> SyncBlob?
    /// expected = nil: create only (If-None-Match: *); otherwise If-Match: "v<expected>".
    func put(_ kind: String, expected: Int?, keyId: String, ciphertext: Data) async throws -> SyncPut
}

/// What this device synced last, per kind: the version (rollback guard: never accept a lower one) and a digest of the
/// plaintext both sides agreed on (local data that no longer matches it was edited here since). The account key is not
/// in here: it lives in the Keychain (`SyncKeyStore`).
public struct SyncState: Codable, Equatable, Sendable {
    public struct Kind: Codable, Equatable, Sendable { public var version: Int; public var digest: String }
    public var userId: String, keyId: String
    public var kinds: [String: Kind] = [:]
    public var last: String?
    public init(userId: String, keyId: String) { self.userId = userId; self.keyId = keyId }
}

/// This device's data per sync kind, as the same JSON the web stores (Foundation JSON values: dictionaries, arrays, …).
public protocol SyncLocal: AnyObject, Sendable {
    func read(_ kind: String) throws -> Any?
    /// Applies `change` to the current value and returns what is stored afterwards (read back, so a push sends what this device really holds).
    func update(_ kind: String, _ change: (Any?) -> Any?) throws -> Any?
    /// Keeps a value that sync is about to replace (whole kinds only), so a restore never silently loses it.
    func backup(_ kind: String, _ value: Any, saved: String) throws
    func loadState() throws -> SyncState?
    func saveState(_ state: SyncState?) throws
}
public protocol SyncKeyStore: Sendable {
    func load(userId: String) -> SymmetricKey?
    func save(_ key: SymmetricKey, userId: String) throws
    func delete(userId: String)
}

/// Sync on the Mac: a port of apps/web/src/sync.ts (same rules, same blobs), so Mac, web and Windows open each other's data.
public struct SyncEngine: Sendable {
    public let remote: any SyncRemote, local: any SyncLocal, keys: any SyncKeyStore
    public init(remote: any SyncRemote, local: any SyncLocal, keys: any SyncKeyStore) { self.remote = remote; self.local = local; self.keys = keys }

    /// What the web syncs; contacts/settings stay on this Mac for now.
    public static let synced: [(kind: String, records: Bool)] = [("profile", false), ("resumes", false), ("applications", true)]
    static func fail(_ m: String) -> SyncCrypto.Failure { .init(message: m) }

    public enum Setup: Equatable { case ready(last: String?), newAccount, needsKey, otherAccount }
    public func setup() async throws -> Setup {
        let userId = try await remote.me()
        if let s = try local.loadState(), keys.load(userId: s.userId) != nil { return s.userId == userId ? .ready(last: s.last) : .otherAccount }
        return try await remote.get("keyring") == nil ? .newAccount : .needsKey
    }

    /// First device: a new account key, wrapped by a new recovery key into the keyring. Returns the recovery key, shown once.
    public func createKeyring() async throws -> String {
        let userId = try await remote.me()
        let ak = SyncCrypto.makeAccountKey(), rk = SyncCrypto.makeRecoveryKey(), keyId = SyncCrypto.makeKeyId()
        // SHORTCUT: as on the web, if the app quits between the PUT and the save, nobody saw the recovery key and there is no reset flow yet.
        let ring = try SyncCrypto.wrapAccountKey(ak, keyId: keyId, rk: rk, userId: userId, version: 1, ringId: "rk-1")
        guard case .ok = try await remote.put("keyring", expected: nil, keyId: "rk-1", ciphertext: ring) else {
            throw Self.fail("Another device just set up sync for this account. Use its recovery key here instead.")
        }
        try keys.save(ak, userId: userId)
        try local.saveState(SyncState(userId: userId, keyId: keyId))
        return SyncCrypto.formatRecoveryKey(rk)
    }

    /// Another device: unwrap the account key with the recovery key the user typed.
    public func restoreKeyring(_ text: String) async throws {
        guard let rk = SyncCrypto.parseRecoveryKey(text) else { throw Self.fail("That isn't a recovery key. It has 26 letters and digits, like ABCD-EFGH-…") }
        let userId = try await remote.me()
        guard let ring = try await remote.get("keyring") else { throw Self.fail("This account has no synced data yet.") }
        let (ak, keyId) = try SyncCrypto.unwrapAccountKey(ring.ciphertext, rk: rk, userId: userId, version: ring.version, ringId: ring.keyId)
        try keys.save(ak, userId: userId)
        try local.saveState(SyncState(userId: userId, keyId: keyId))
    }

    /// "Turn off sync on this Mac": forgets the account key here. Synced data and the other devices are untouched.
    public func forget() throws {
        if let s = try local.loadState() { keys.delete(userId: s.userId) }
        try local.saveState(nil)
    }

    public struct Result: Equatable { public var pushed = 0, pulled = 0; public var replaced: [String] = [] }

    /// Pull, merge, push each kind. Rules: a remote version below the last one seen is refused (rollback). Remote changed and
    /// this device didn't (or this device has nothing yet, or never synced this kind): take the remote. Both changed:
    /// applications merge by record (newer `updated` wins); profile and resume keep this device's edit (last writer wins).
    /// A 409 means another device wrote first: start the kind again, at most 3 times.
    public func syncNow(now: Date = Date()) async throws -> Result {
        guard var s = try local.loadState(), let ak = keys.load(userId: s.userId) else { throw Self.fail("Sync isn't set up on this Mac yet.") }
        guard try await remote.me() == s.userId else { throw Self.fail("This Mac syncs with a different account. Turn sync off here, or sign in with that account.") }
        let stamp = ISO8601DateFormatter.string(from: now, timeZone: .gmt, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        var out = Result()
        for (kind, records) in Self.synced {
            var attempt = 0
            while true {
                if attempt == 3 { throw Self.fail("Another device keeps changing this data. Try again in a moment.") }
                attempt += 1
                let seen = s.kinds[kind] ?? .init(version: 0, digest: "")
                let r = try await remote.get(kind)
                if (r?.version ?? 0) < seen.version { throw Self.fail("The sync service sent older data than this Mac already has, so nothing was changed. Try again later.") }
                var remoteValue: Any?
                if let r {
                    let plain: Data
                    do { plain = try SyncCrypto.open(r.ciphertext, key: ak, aad: SyncCrypto.aad(userId: s.userId, kind: kind, version: r.version, keyId: r.keyId)) }
                    catch { throw Self.fail("Synced data couldn't be decrypted with this Mac's key, so nothing was changed. If you reset sync on another device, turn sync off here and enter the new recovery key.") }
                    remoteValue = try JSONSerialization.jsonObject(with: plain, options: .fragmentsAllowed)
                }
                let local0 = try local.read(kind), localText = Self.canon(local0)
                let edited = Self.digest(localText) != seen.digest
                var next = local0
                if let r, r.version > seen.version {
                    next = records ? SyncCrypto.mergeRecords(local: local0, remote: remoteValue)
                        : (!edited || Self.empty(local0) || seen.version == 0) ? remoteValue : local0
                }
                if !records, let local0, !Self.empty(local0), Self.canon(next) != localText {
                    try local.backup(kind, local0, saved: stamp)
                    out.replaced.append(kind)
                }
                if Self.canon(next) != localText {
                    let target = next
                    // An edit made meanwhile merges in (records) or wins (whole), as on the web.
                    next = try local.update(kind) { cur in records ? SyncCrypto.mergeRecords(local: cur, remote: target) : Self.canon(cur) == localText ? target : cur }
                    out.pulled += 1
                }
                let text = Self.canon(next)
                if Self.empty(next) || (r != nil && text == Self.canon(remoteValue)) {
                    s.kinds[kind] = .init(version: r?.version ?? 0, digest: Self.digest(text))
                    break
                }
                let version = (r?.version ?? 0) + 1
                let blob = try SyncCrypto.seal(Data(text.utf8), key: ak, aad: SyncCrypto.aad(userId: s.userId, kind: kind, version: version, keyId: s.keyId))
                guard case .ok(let got) = try await remote.put(kind, expected: r?.version, keyId: s.keyId, ciphertext: blob) else { continue }
                if got != version { throw Self.fail("The sync service numbered this change unexpectedly. Try again later.") }
                s.kinds[kind] = .init(version: version, digest: Self.digest(text))
                out.pushed += 1
                break
            }
            try local.saveState(s)  // per kind: a failure later in the run must not forget what this kind agreed with the server
        }
        s.last = stamp
        try local.saveState(s)
        return out
    }

    static func empty(_ v: Any?) -> Bool { v == nil || v is NSNull }
    /// One spelling per value: JavaScript's JSON.stringify with sorted keys (libs/core sync.ts canonJSON), so both ports agree on
    /// the merge tie-break and the web doesn't push back what it just pulled. Used for equality, digests and what goes on the wire.
    /// Not JSONSerialization: it writes 0.82 as 0.81999999999999995.
    public static func canon(_ v: Any?) -> String {
        switch v {
        case nil, is NSNull: return "null"
        case let s as String: return quote(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            let d = n.doubleValue
            guard d.isFinite else { return "null" }
            if d == d.rounded(), abs(d) < 1e21 { return String(format: "%.0f", d) == "-0" ? "0" : String(format: "%.0f", d) }
            // shortcut: JS writes 1e-5..1e-7 in plain decimals where Swift uses exponents; fine for scores and years, revisit for tiny values.
            return "\(d)".replacingOccurrences(of: "e-0", with: "e-").replacingOccurrences(of: "e+0", with: "e+")
        case let a as [Any]: return "[" + a.map { canon($0) }.joined(separator: ",") + "]"
        case let o as [String: Any]:
            // Sorted by UTF-16 code units, like JavaScript's default sort.
            let keys = o.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            return "{" + keys.map { quote($0) + ":" + canon(o[$0]) }.joined(separator: ",") + "}"
        default: return "null"
        }
    }
    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {  // a Swift String has no lone surrogates, so scalars cover what JSON.stringify escapes
            switch c.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0..<0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }
    static func digest(_ s: String) -> String { Data(SHA256.hash(data: Data(s.utf8))).base64EncodedString() }
}
