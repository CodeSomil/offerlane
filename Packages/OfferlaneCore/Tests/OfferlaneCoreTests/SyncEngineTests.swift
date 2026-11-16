import CryptoKit
import XCTest
@testable import OfferlaneCore

/// In-memory server with the API's rules: versions start at 1, If-None-Match/If-Match preconditions, 409 when stale.
final class FakeSyncServer: SyncRemote, @unchecked Sendable {
    var userId = "user-1"
    var blobs: [String: SyncBlob] = [:]
    var puts = 0
    /// Runs once before the next PUT (another device writing first).
    var beforePut: (() -> Void)?
    func me() async throws -> String { userId }
    func get(_ kind: String) async throws -> SyncBlob? { blobs[kind] }
    func put(_ kind: String, expected: Int?, keyId: String, ciphertext: Data) async throws -> SyncPut {
        if let f = beforePut { beforePut = nil; f() }
        puts += 1
        guard blobs[kind]?.version == expected else { return .conflict }
        let v = (expected ?? 0) + 1
        blobs[kind] = .init(version: v, keyId: keyId, ciphertext: ciphertext)
        return .ok(version: v)
    }
}
final class MemoryLocal: SyncLocal {
    var values: [String: Any] = [:], backups: [String: Any] = [:], state: SyncState?
    func read(_ kind: String) throws -> Any? { values[kind] }
    func update(_ kind: String, _ change: (Any?) -> Any?) throws -> Any? { values[kind] = change(values[kind]); return values[kind] }
    func backup(_ kind: String, _ value: Any, saved: String) throws { backups[kind] = value }
    func loadState() throws -> SyncState? { state }
    func saveState(_ s: SyncState?) throws { state = s }
}
final class MemoryKeys: SyncKeyStore, @unchecked Sendable {
    var keys: [String: SymmetricKey] = [:]
    func load(userId: String) -> SymmetricKey? { keys[userId] }
    func save(_ key: SymmetricKey, userId: String) throws { keys[userId] = key }
    func delete(userId: String) { keys[userId] = nil }
}

final class SyncEngineTests: XCTestCase {
    let server = FakeSyncServer()
    func device() -> (SyncEngine, MemoryLocal) { let l = MemoryLocal(); return (SyncEngine(remote: server, local: l, keys: MemoryKeys()), l) }
    func rec(_ v: String, _ t: String) -> [String: Any] { ["v": v, "updated": t] }

    func testTwoDevicesShareDataThroughTheRecoveryKey() async throws {
        let (mac, macData) = device(), (other, otherData) = device()
        let s0 = try await mac.setup()
        XCTAssertEqual(s0, .newAccount)
        let rk = try await mac.createKeyring()
        macData.values["profile"] = ["name": "Zoë"]
        macData.values["applications"] = ["a": rec("mac", "2026-11-10T00:00:00.000Z")]
        let r1 = try await mac.syncNow()
        XCTAssertEqual(r1.pushed, 2)
        let s1 = try await other.setup()
        XCTAssertEqual(s1, .needsKey)
        do { try await other.restoreKeyring("AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AA"); XCTFail("wrong key accepted") } catch {}
        try await other.restoreKeyring(rk.lowercased())
        XCTAssertEqual(otherData.state?.keyId, macData.state?.keyId)  // one key id per account key
        let r2 = try await other.syncNow()
        XCTAssertEqual(r2.pulled, 2); XCTAssertEqual(r2.pushed, 0)
        XCTAssertEqual(SyncEngine.canon(otherData.values["profile"]), #"{"name":"Zoë"}"#)
        let puts = server.puts
        _ = try await mac.syncNow(); _ = try await other.syncNow()
        XCTAssertEqual(server.puts, puts, "nothing changed, so nothing is written")
    }

    func testWholeKindsLastWriterWinsAndKeepABackup() async throws {
        let (a, aData) = device(), (b, bData) = device()
        let rk = try await a.createKeyring(); try await b.restoreKeyring(rk)
        aData.values["profile"] = ["name": "A"]
        _ = try await a.syncNow()
        bData.values["profile"] = ["name": "B-before"]  // b had its own data before its first sync: remote wins, b's is kept aside
        let r = try await b.syncNow()
        XCTAssertEqual(r.replaced, ["profile"])
        XCTAssertEqual(SyncEngine.canon(bData.backups["profile"]), #"{"name":"B-before"}"#)
        XCTAssertEqual(SyncEngine.canon(bData.values["profile"]), #"{"name":"A"}"#)
        // both edit: the one that syncs second keeps its edit and pushes it
        aData.values["profile"] = ["name": "A2"]; bData.values["profile"] = ["name": "B2"]
        _ = try await a.syncNow(); _ = try await b.syncNow(); _ = try await a.syncNow()
        XCTAssertEqual(SyncEngine.canon(aData.values["profile"]), #"{"name":"B2"}"#)
    }

    func testRecordsMergeAndAConflictRetries() async throws {
        let (a, aData) = device(), (b, bData) = device()
        let rk = try await a.createKeyring(); try await b.restoreKeyring(rk)
        aData.values["applications"] = ["x": rec("a", "2026-11-10T00:00:00.000Z"), "y": rec("a", "2026-11-12T00:00:00.000Z")]
        _ = try await a.syncNow()
        bData.values["applications"] = ["x": rec("b", "2026-11-11T00:00:00.000Z"), "z": rec("b", "2026-11-11T00:00:00.000Z")]
        // a writes again between b's read and b's write: b gets a 409, starts over, and merges a's change in
        let newA: [String: Any] = ["x": rec("a", "2026-11-10T00:00:00.000Z"), "y": rec("a", "2026-11-13T00:00:00.000Z")]
        aData.values["applications"] = newA
        let ak = a.keys.load(userId: "user-1")!, keyId = aData.state!.keyId
        server.beforePut = { [server] in
            let v = server.blobs["applications"]!.version + 1
            let blob = try! SyncCrypto.seal(Data(SyncEngine.canon(newA).utf8), key: ak, aad: SyncCrypto.aad(userId: "user-1", kind: "applications", version: v, keyId: keyId))
            server.blobs["applications"] = .init(version: v, keyId: keyId, ciphertext: blob)
        }
        let puts = server.puts
        _ = try await b.syncNow()
        XCTAssertEqual(server.puts - puts, 2, "one 409, then the merged write")
        _ = try await a.syncNow()
        for d in [aData, bData] {
            let m = d.values["applications"] as! [String: [String: String]]
            XCTAssertEqual(m.mapValues { $0["v"]! }, ["x": "b", "y": "a", "z": "b"])
        }
    }

    func testRefusesRollbackAndForeignKeys() async throws {
        let (a, aData) = device()
        _ = try await a.createKeyring()
        aData.values["profile"] = ["n": 1]; _ = try await a.syncNow()
        aData.values["profile"] = ["n": 2]; _ = try await a.syncNow()
        let v2 = server.blobs["profile"]!
        server.blobs["profile"]!.version = 1
        do { _ = try await a.syncNow(); XCTFail("rollback accepted") } catch let e as SyncCrypto.Failure { XCTAssertTrue(e.message.contains("older data")) }
        server.blobs["profile"] = v2
        server.blobs["profile"]!.ciphertext[20] ^= 1
        do { _ = try await a.syncNow(); XCTFail("tampered blob accepted") } catch let e as SyncCrypto.Failure { XCTAssertTrue(e.message.contains("decrypted")) }
        XCTAssertEqual(SyncEngine.canon(aData.values["profile"]), #"{"n":2}"#, "nothing changed")
        server.userId = "user-2"
        do { _ = try await a.syncNow(); XCTFail("other account accepted") } catch {}
        let s = try await a.setup()
        XCTAssertEqual(s, .otherAccount)
        try a.forget()
        XCTAssertNil(aData.state)
    }

    /// The engine pulls what the web (TS) sealed: Fixtures/sync/ts_sealed.json, applications at version 7.
    func testPullsWhatTheWebWrote() async throws {
        struct V: Decodable { struct B: Decodable { var kind: String; var version: Int; var keyId: String; var plaintext: String; var blob: String }; var blobs: [B] }
        let v = try JSONDecoder().decode(V.self, from: Fixture.data("sync/ts_sealed.json"))
        let b = v.blobs.first { $0.kind == "applications" }!
        server.blobs["applications"] = .init(version: b.version, keyId: b.keyId, ciphertext: Data(base64Encoded: b.blob)!)
        let keys = MemoryKeys(); keys.keys["user-1"] = SymmetricKey(data: Data(0..<32))
        let local = MemoryLocal(); local.state = SyncState(userId: "user-1", keyId: b.keyId)
        let r = try await SyncEngine(remote: server, local: local, keys: keys).syncNow()
        XCTAssertEqual(r.pulled, 1)
        XCTAssertEqual(SyncEngine.canon(local.values["applications"]), SyncEngine.canon(try JSONSerialization.jsonObject(with: Data(b.plaintext.utf8))))
        XCTAssertEqual(local.state?.kinds["applications"]?.version, 7)
    }
}
