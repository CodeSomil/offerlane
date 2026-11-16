import Foundation
import OfferlaneCore
import XCTest
@testable import OfferlaneAPI

/// Live check (v4 P4.4e), opt-in: OFFERLANE_LIVE_SYNC=1 with the dev stack up
/// (`docker compose -f compose.preview.yml -f compose.dev.yml up -d`). Real sign-in at the dev issuer (code + PKCE over the
/// loopback), real SyncHTTP against the API, two Macs, and a 409 from the server's own ETag check.
final class SyncLiveTests: XCTestCase {
    struct Remote: SyncRemote {
        let http: SyncHTTP
        func me() async throws -> String { try await http.me() }
        func get(_ kind: String) async throws -> SyncBlob? { try await http.get(kind).map { SyncBlob(version: $0.version, keyId: $0.keyId, ciphertext: $0.ciphertext) } }
        func put(_ kind: String, expected: Int?, keyId: String, ciphertext: Data) async throws -> SyncPut {
            switch try await http.put(kind, expected: expected, keyId: keyId, ciphertext: ciphertext) { case .ok(let v): .ok(version: v); case .conflict: .conflict }
        }
    }
    func testTwoMacsThroughTheRealAPI() async throws {
        guard ProcessInfo.processInfo.environment["OFFERLANE_LIVE_SYNC"] == "1" else { throw XCTSkip("set OFFERLANE_LIVE_SYNC=1 with the dev stack up") }
        let config = CloudConfig.dev
        let sub = "live-\(UUID().uuidString.prefix(8))"
        // The "browser": the dev issuer auto-consents for login_hint and redirects to our loopback.
        let signIn = CloudSignIn(config: config) { url in
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            c.queryItems! += [.init(name: "login_hint", value: sub)]
            _ = Task.detached { _ = try? await URLSession.shared.data(from: c.url!) }
        }
        let session = try await signIn.signIn(timeout: 20)
        XCTAssertEqual(session.sub, sub)
        let token = session.token
        let http = SyncHTTP(client: .offerlane(serverURL: config.api, token: { token }))
        let me = try await http.me()
        XCTAssertFalse(me.isEmpty)

        let a = try Store(), b = try Store()
        var p = Profile(); p.personal.firstName = "Zoë"; try a.set(.profile, p)
        try a.upsert(Job(company: "Acme", title: "Eng", id: "live-1")); try a.transition("live-1", to: .tailoring, by: "test")
        let ka = Keychain(service: "com.somilmanke.Offerlane.tests.live-\(UUID().uuidString)"), kb = Keychain(service: "com.somilmanke.Offerlane.tests.live-\(UUID().uuidString)")
        defer { ka.delete(userId: me); kb.delete(userId: me) }
        let ea = SyncEngine(remote: Remote(http: http), local: StoreSyncLocal(store: a), keys: ka)
        let eb = SyncEngine(remote: Remote(http: http), local: StoreSyncLocal(store: b), keys: kb)
        let s0 = try await ea.setup()
        XCTAssertEqual(s0, .newAccount)
        let rk = try await ea.createKeyring()
        let r1 = try await ea.syncNow()
        XCTAssertEqual(r1.pushed, 2)
        try await eb.restoreKeyring(rk)
        _ = try await eb.syncNow()
        XCTAssertEqual(try b.profile().personal.firstName, "Zoë")
        XCTAssertEqual(try b.job("live-1")?.status, .tailoring)

        // A stale If-Match gets the server's 409; the engine starts over and merges.
        let stale = try await http.get("applications")!
        _ = try b.update("live-1") { $0.location = "Berlin" }
        _ = try await eb.syncNow()
        let conflict = try await http.put("applications", expected: stale.version, keyId: stale.keyId, ciphertext: stale.ciphertext)
        XCTAssertEqual(conflict, .conflict)
        _ = try await ea.syncNow()
        XCTAssertEqual(try a.job("live-1")?.location, "Berlin")
        let settled = try await http.get("applications")!.version
        _ = try await ea.syncNow(); _ = try await eb.syncNow()
        let after = try await http.get("applications")!.version
        XCTAssertEqual(after, settled, "nothing rewritten once both Macs agree")
    }
}
