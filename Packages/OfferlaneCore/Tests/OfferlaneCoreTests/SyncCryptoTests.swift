import CryptoKit
import XCTest
@testable import OfferlaneCore

/// The Swift port of libs/core/test/sync.test.ts, plus the cross-client vectors (Fixtures/sync, P4.4a).
final class SyncCryptoTests: XCTestCase {
    let u = "user-1"
    typealias C = SyncCrypto

    func testFixedKinds() { XCTAssertEqual(C.kinds, ["keyring", "profile", "resumes", "applications", "contacts", "settings"]) }

    func testBlobFormatRoundTripsWithFreshNonces() throws {
        let key = C.makeAccountKey(), ad = C.aad(userId: u, kind: "profile", version: 1, keyId: "k1")
        let blob = try C.seal(Data("hello".utf8), key: key, aad: ad)
        XCTAssertEqual(blob.first, 1)
        XCTAssertEqual(blob.count, 1 + 12 + 5 + 16)
        XCTAssertEqual(String(decoding: try C.open(blob, key: key, aad: ad), as: UTF8.self), "hello")
        XCTAssertNotEqual(try C.seal(Data("hello".utf8), key: key, aad: ad), blob)
    }

    func testAADBindsUserKindVersionKeyIdAndBytes() throws {
        let key = C.makeAccountKey(), ok = C.aad(userId: u, kind: "resumes", version: 3, keyId: "k1")
        let blob = try C.seal(Data("x".utf8), key: key, aad: ok)
        for ad in [C.aad(userId: "user-2", kind: "resumes", version: 3, keyId: "k1"), C.aad(userId: u, kind: "profile", version: 3, keyId: "k1"),
                   C.aad(userId: u, kind: "resumes", version: 2, keyId: "k1"), C.aad(userId: u, kind: "resumes", version: 3, keyId: "k2")] {
            XCTAssertThrowsError(try C.open(blob, key: key, aad: ad))
        }
        var bad = blob; bad[20] ^= 1
        XCTAssertThrowsError(try C.open(bad, key: key, aad: ok))
        var v2 = blob; v2[0] = 2
        XCTAssertThrowsError(try C.open(v2, key: key, aad: ok))
        XCTAssertThrowsError(try C.open(blob.prefix(20), key: key, aad: ok))
        XCTAssertNoThrow(try C.open(blob.suffix(from: 0), key: key, aad: ok))
    }

    func testKeyIdsAndRecoveryKeys() {
        XCTAssertNotNil(C.makeKeyId().range(of: "^[0-9a-f]{16}$", options: .regularExpression))
        let rk = C.makeRecoveryKey(), s = C.formatRecoveryKey(rk)
        XCTAssertNotNil(s.range(of: "^([A-Z2-7]{4}-){6}[A-Z2-7]{2}$", options: .regularExpression))
        XCTAssertEqual(C.parseRecoveryKey(s), rk)
        XCTAssertEqual(C.parseRecoveryKey(" \(s.lowercased().replacingOccurrences(of: "-", with: " ")) "), rk)
        XCTAssertEqual(C.formatRecoveryKey(Data(count: 16)), "AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AA")
        XCTAssertEqual(C.formatRecoveryKey(Data(repeating: 255, count: 16)), "7777-7777-7777-7777-7777-7777-74")
        XCTAssertNil(C.parseRecoveryKey(String(s.dropLast())))
        XCTAssertNil(C.parseRecoveryKey(s + "A"))
        XCTAssertNil(C.parseRecoveryKey(String(s.dropLast()) + "1"))
        XCTAssertNil(C.parseRecoveryKey("7777-7777-7777-7777-7777-7777-77"))
        XCTAssertNil(C.parseRecoveryKey(""))
    }

    func testKeyringWrapBindsUserAndVersion() throws {
        let ak = C.makeAccountKey(), rk = C.makeRecoveryKey()
        let ring = try C.wrapAccountKey(ak, keyId: "0123abcd0123abcd", rk: rk, userId: u, version: 1, ringId: "rk-1")
        let back = try C.unwrapAccountKey(ring, rk: rk, userId: u, version: 1, ringId: "rk-1")
        XCTAssertEqual(back.keyId, "0123abcd0123abcd")
        XCTAssertThrowsError(try C.wrapAccountKey(ak, keyId: "bad id!", rk: rk, userId: u, version: 1, ringId: "rk-1"))
        XCTAssertThrowsError(try C.wrapAccountKey(SymmetricKey(size: .bits128), keyId: "k1", rk: rk, userId: u, version: 1, ringId: "rk-1"))
        let blob = try C.seal(Data("data".utf8), key: ak, aad: C.aad(userId: u, kind: "profile", version: 1, keyId: "k1"))
        XCTAssertEqual(try C.open(blob, key: back.key, aad: C.aad(userId: u, kind: "profile", version: 1, keyId: "k1")), Data("data".utf8))
        XCTAssertThrowsError(try C.unwrapAccountKey(ring, rk: C.makeRecoveryKey(), userId: u, version: 1, ringId: "rk-1"))
        XCTAssertThrowsError(try C.unwrapAccountKey(ring, rk: rk, userId: "user-2", version: 1, ringId: "rk-1"))
        XCTAssertThrowsError(try C.unwrapAccountKey(ring, rk: rk, userId: u, version: 2, ringId: "rk-1"))
    }

    func testMergeRecords() {
        let local: [String: Any] = ["a": ["updated": "2026-11-10T00:00:00.000Z", "v": "L"], "b": ["updated": "2026-11-12T00:00:00.000Z", "v": "L"], "c": ["updated": "2026-11-01T00:00:00.000Z", "v": "L"]]
        let remote: [String: Any] = ["a": ["updated": "2026-11-11T00:00:00.000Z", "v": "R"], "b": ["updated": "2026-11-11T00:00:00.000Z", "v": "R"], "c": ["updated": "2026-11-01T00:00:00.000Z", "v": "R"], "d": ["updated": "", "v": "R"]]
        let m = C.mergeRecords(local: local, remote: remote)
        XCTAssertEqual(m.mapValues { ($0 as! [String: String])["v"]! }, ["a": "R", "b": "L", "c": "L", "d": "R"])
        XCTAssertEqual(C.mergeRecords(local: nil, remote: remote).count, 4)
        XCTAssertEqual(C.mergeRecords(local: local, remote: "not a map").count, 3)
    }

    // MARK: cross-client vectors (same keys as libs/core/test/syncVectors.test.ts; test-only)
    let ak = SymmetricKey(data: Data(0..<32)), rk = Data((0..<16).map { 0xa0 + UInt8($0) }), keyId = "0123abcd0123abcd"
    struct Vectors: Codable {
        struct Ring: Codable { var version: Int; var ringId: String; var blob: String }
        struct Blob: Codable { var kind: String; var version: Int; var keyId: String; var plaintext: String; var blob: String }
        var recoveryKey: String; var keyring: Ring; var blobs: [Blob]
    }

    func testSwiftVectors() throws {
        let dst = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sync/swift_sealed.json")
        if ProcessInfo.processInfo.environment["OFFERLANE_WRITE_GOLDEN"] == "1" {
            var plain: [(String, Int, String)] = [("resumes", 2, #"{"name":"Zoë Example","label":"Café ☕️"}"#), ("settings", 1, "null")]
            // What the Mac Store really sends (StoreSyncLocal): the web must read these with its own decoders (syncVectors.test.ts).
            let store = try Store(), local = StoreSyncLocal(store: store)
            let g = (try JSONSerialization.jsonObject(with: Fixture.data("core/core_expected.json")) as! [String: Any])["inputs"] as! [String: Any]
            try store.set(.profile, StoreSyncLocal.decode(g["profile"]) as Profile?)
            var j = Job(company: "Acme Ünited", title: "Data Scientist", location: "Zürich", url: "https://example.com/j/1", id: "gh:acme:1")
            j.ats = "greenhouse"; j.minYears = 3; j.posted = "2026-11-01"; j.localScore = 0.82; j.notes = "Mac-only"
            try store.save(j); try store.transition("gh:acme:1", to: .tailoring, by: "test")
            plain += [("profile", 4, SyncEngine.canon(try local.read("profile"))), ("applications", 3, SyncEngine.canon(try local.read("applications")))]
            let v = Vectors(recoveryKey: C.formatRecoveryKey(rk),
                            keyring: .init(version: 1, ringId: "rk-1", blob: try C.wrapAccountKey(ak, keyId: keyId, rk: rk, userId: u, version: 1, ringId: "rk-1").base64EncodedString()),
                            blobs: try plain.map { .init(kind: $0.0, version: $0.1, keyId: keyId, plaintext: $0.2,
                                                         blob: try C.seal(Data($0.2.utf8), key: ak, aad: C.aad(userId: u, kind: $0.0, version: $0.1, keyId: keyId)).base64EncodedString()) })
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try (enc.encode(v) + Data("\n".utf8)).write(to: dst)
        }
        try opens(try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: dst)))
    }

    func testOpensWhatTSSealed() throws {
        try opens(try JSONDecoder().decode(Vectors.self, from: Fixture.data("sync/ts_sealed.json")))
    }

    func opens(_ v: Vectors) throws {
        XCTAssertEqual(v.recoveryKey, C.formatRecoveryKey(rk))
        let ring = try C.unwrapAccountKey(Data(base64Encoded: v.keyring.blob)!, rk: rk, userId: u, version: v.keyring.version, ringId: v.keyring.ringId)
        XCTAssertEqual(ring.keyId, keyId)
        XCTAssertFalse(v.blobs.isEmpty)
        for b in v.blobs {
            let blob = Data(base64Encoded: b.blob)!
            XCTAssertEqual(String(decoding: try C.open(blob, key: ring.key, aad: C.aad(userId: u, kind: b.kind, version: b.version, keyId: b.keyId)), as: UTF8.self), b.plaintext)
            XCTAssertThrowsError(try C.open(blob, key: ring.key, aad: C.aad(userId: u, kind: b.kind, version: b.version + 1, keyId: b.keyId)))
        }
    }
}
