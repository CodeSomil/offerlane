import XCTest
@testable import OfferlaneCore

final class PKCESignInTests: XCTestCase {
    private let endpoints = PKCESignIn.Endpoints(authURL: URL(string: "https://openrouter.ai/auth")!,
                                                 exchangeURL: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)

    func testRegistryOffersSignInOnlyForOpenRouter() throws {
        let specs = try ProviderRegistry.load()
        XCTAssertEqual(specs.filter { $0.pkceSignIn != nil }.map(\.id), ["openrouter"])
        XCTAssertEqual(specs.first { $0.id == "openrouter" }?.pkceSignIn, endpoints)
    }

    /// The "browser" reads the authorization URL, then hits the loopback redirect like OpenRouter would.
    func testFullSignInReturnsKey() async throws {
        let t = MockTransport { r in
            XCTAssertEqual(r.url, self.endpoints.exchangeURL); XCTAssertEqual(r.httpMethod, "POST")
            let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: String]
            XCTAssertEqual(body["code"], "auth-code"); XCTAssertEqual(body["code_challenge_method"], "S256")
            XCTAssertFalse((body["code_verifier"] ?? "").isEmpty, "PKCE verifier sent")
            return (200, Data(#"{"key":"sk-or-v1-test","user_id":"u1"}"#.utf8))
        }
        let s = PKCESignIn(endpoints: endpoints, transport: t) { url in
            let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(q["code_challenge_method"], "S256"); XCTAssertFalse((q["code_challenge"] ?? "").isEmpty)
            XCTAssertTrue(q["callback_url"]!.hasPrefix("http://localhost:"))
            var cb = URLComponents(string: q["callback_url"]!)!
            cb.queryItems = [.init(name: "code", value: "auth-code"), .init(name: "state", value: q["state"]!)]
            _ = Task.detached { _ = try await URLSession.shared.data(from: cb.url!) }
        }
        let key = try await s.authorize(timeout: 20)
        XCTAssertEqual(key, "sk-or-v1-test")
    }

    func testBadAnswersAreRejected() async {
        let pkce = PKCE()
        let never = PKCESignIn(endpoints: endpoints, transport: MockTransport { _ in XCTFail("no exchange"); return (500, Data()) }) { _ in }
        await assertFails(.stateMismatch) { try await never.complete(callback: ["code": "c", "state": "other"], expectedState: "s", pkce: pkce) }
        await assertFails(.denied) { try await never.complete(callback: ["error": "access_denied", "state": "s"], expectedState: "s", pkce: pkce) }
        await assertFails(.missingCode) { try await never.complete(callback: ["state": "s"], expectedState: "s", pkce: pkce) }

        let expired = PKCESignIn(endpoints: endpoints, transport: MockTransport { _ in (403, Data(#"{"error":"Authorization code expired"}"#.utf8)) }) { _ in }
        await assertFails(.rejected(403)) { try await expired.complete(callback: ["code": "c", "state": "s"], expectedState: "s", pkce: pkce) }
        let empty = PKCESignIn(endpoints: endpoints, transport: MockTransport { _ in (200, Data(#"{"key":""}"#.utf8)) }) { _ in }
        await assertFails(.noKey) { try await empty.complete(callback: ["code": "c", "state": "s"], expectedState: "s", pkce: pkce) }
        let offline = PKCESignIn(endpoints: endpoints, transport: MockTransport { _ in throw URLError(.notConnectedToInternet) }) { _ in }
        await assertFails(.network) { try await offline.complete(callback: ["code": "c", "state": "s"], expectedState: "s", pkce: pkce) }
    }

    private func assertFails(_ expected: PKCESignIn.Failure, _ body: () async throws -> String, line: UInt = #line) async {
        do { _ = try await body(); XCTFail("expected \(expected)", line: line) }
        catch { XCTAssertEqual(error as? PKCESignIn.Failure, expected, line: line) }
    }
}
