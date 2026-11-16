import CryptoKit
import XCTest
@testable import OfferlaneCore

/// The Mac Store as the web's sync JSON (P4.4c): what the web writes lands in the Store and goes back out unchanged.
final class SyncMappingTests: XCTestCase {
    func golden() throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: Fixture.data("core/core_expected.json")) as! [String: Any])["inputs"] as! [String: Any]
    }
    func canon(_ v: Any?) -> String { SyncEngine.canon(v) }

    func testProfileAndResumeTakeTheWebShapeAndKeepMacOnlyFields() throws {
        let store = try Store(), local = StoreSyncLocal(store: store), g = try golden()
        XCTAssertNil(try local.read("profile"))
        XCTAssertNil(try local.read("resumes"))
        let profile = g["profile"]!
        let back = try local.update("profile") { _ in profile }
        XCTAssertEqual(canon(back), canon(try local.read("profile")))
        XCTAssertEqual(try store.profile(), StoreSyncLocal.decode(profile))

        var mine: ResumeVersion = StoreSyncLocal.decode(g["version"])!
        mine.templateTex = "\\documentclass{article}"; mine.isDefault = true
        try store.saveResume(mine)
        var web = g["version"] as! [String: Any]
        web["label"] = "Edited on the web"; web.removeValue(forKey: "template_tex"); web.removeValue(forKey: "template")
        _ = try local.update("resumes") { _ in web }
        let r = try XCTUnwrap(try store.resume())
        XCTAssertEqual(r.label, "Edited on the web")
        XCTAssertEqual(r.templateTex, "\\documentclass{article}", "a pull from the web doesn't drop the Mac's LaTeX template")
    }

    func testApplicationsRoundTripWithoutChurnAndKeepWebOnlyKeys() throws {
        let store = try Store(), local = StoreSyncLocal(store: store), g = try golden()
        var job = g["job"] as! [String: Any]; job["id"] = "gh:acme:1"
        let rec: [String: Any] = ["job": job, "status": "review", "score": 82, "created": "2026-11-10T09:00:00.000Z",
                                  "updated": "2026-11-15T12:34:56.789Z", "plan": g["plan"]!, "answers": "Why us? Because."]
        let back = try local.update("applications") { _ in ["gh:acme:1": rec] }
        XCTAssertEqual(canon(back), canon(["gh:acme:1": rec]), "what the web wrote goes back out exactly (no push, no churn)")

        var j = try XCTUnwrap(try store.job("gh:acme:1"))
        XCTAssertEqual(j.status, .review)
        XCTAssertEqual(j.title, job["title"] as? String)
        XCTAssertEqual(j.updated, Dates.now(StoreSyncLocal.isoMs.date(from: "2026-11-15T12:34:56.789Z")!), "kept in the Mac's local time")
        XCTAssertEqual(try store.events(for: "gh:acme:1").first?.source, "sync")

        // The Mac edits the role: Mac-only fields stay local, the web's plan and answers survive, the time goes out as UTC.
        j = try store.update("gh:acme:1") { $0.notes = "Mac-only note"; $0.location = "Berlin" }
        let out = try XCTUnwrap((try local.read("applications") as? [String: Any])?["gh:acme:1"] as? [String: Any])
        XCTAssertEqual((out["job"] as? [String: Any])?["location"] as? String, "Berlin")
        XCTAssertNil((out["job"] as? [String: Any])?["notes"])
        XCTAssertEqual(out["answers"] as? String, "Why us? Because.")
        XCTAssertEqual(canon(out["plan"]), canon(g["plan"]))
        XCTAssertEqual(out["updated"] as? String, StoreSyncLocal.utc(j.updated))
        XCTAssertTrue((out["updated"] as! String).hasSuffix("Z"))
    }

    func testOnlyActedOnJobsAndUnknownRecordsPassThrough() throws {
        let store = try Store(), local = StoreSyncLocal(store: store)
        try store.upsert(Job(company: "Found", title: "Match", id: "found-1"))
        try store.upsert(Job(company: "Acme", title: "Eng", id: "acted-1"))
        try store.transition("acted-1", to: .tailoring, by: "test")
        XCTAssertEqual((try local.read("applications") as? [String: Any])?.keys.sorted(), ["acted-1"])
        let future: [String: Any] = ["job": ["id": "x"], "status": "some-future-status", "updated": "2026-11-15T00:00:00.000Z"]
        let back = try local.update("applications") { cur in (cur as? [String: Any] ?? [:]).merging(["x": future]) { $1 } }
        XCTAssertNil(try store.job("x"), "an unknown status isn't applied")
        XCTAssertEqual(canon((back as? [String: Any])?["x"]), canon(future), "but it isn't dropped from the synced data either")
    }

    func testTwoMacsThroughTheEngine() async throws {
        let server = FakeSyncServer(), keys = MemoryKeys()
        let a = try Store(), b = try Store()
        try a.upsert(Job(company: "Acme", title: "Eng", id: "acted-1"))
        try a.transition("acted-1", to: .tailoring, by: "test")
        var p = Profile(); p.personal.firstName = "Zoë"; try a.set(.profile, p)
        let ea = SyncEngine(remote: server, local: StoreSyncLocal(store: a), keys: keys)
        let rk = try await ea.createKeyring()
        _ = try await ea.syncNow()
        let eb = SyncEngine(remote: server, local: StoreSyncLocal(store: b), keys: MemoryKeys())
        try await eb.restoreKeyring(rk)
        _ = try await eb.syncNow()
        XCTAssertEqual(try b.job("acted-1")?.status, .tailoring)
        XCTAssertEqual(try b.profile().personal.firstName, "Zoë")
        let puts = server.puts
        _ = try await ea.syncNow(); _ = try await eb.syncNow(); _ = try await ea.syncNow()
        XCTAssertEqual(server.puts, puts, "settled: no device keeps rewriting what it pulled")
        try ea.forget()
        XCTAssertNil(try a.get(.syncState, as: SyncState.self))
    }

    func testAccountKeyInTheKeychain() throws {
        let kc = Keychain(service: "com.somilmanke.Offerlane.tests.sync-\(UUID().uuidString)")
        let key = SymmetricKey(size: .bits256)
        do { try kc.save(key, userId: "u1") } catch { throw XCTSkip("Keychain unavailable here: \(error)") }
        defer { kc.delete(userId: "u1") }
        XCTAssertEqual(kc.load(userId: "u1")?.withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })
        XCTAssertNil(kc.load(userId: "u2"))
        kc.delete(userId: "u1")
        XCTAssertNil(kc.load(userId: "u1"))
    }
}
