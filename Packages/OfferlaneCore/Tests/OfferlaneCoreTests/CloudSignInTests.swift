import XCTest
@testable import OfferlaneCore

/// Mac sign-in to the Offerlane cloud (P4.4d): OIDC code + PKCE over a loopback redirect, claims checked on the ID token.
final class CloudSignInTests: XCTestCase {
    let config = CloudConfig(api: URL(string: "https://api.test")!, issuer: URL(string: "https://id.test/")!, clientID: "offerlane-api")
    static let discovery = #"{"issuer":"https://id.test/","authorization_endpoint":"https://id.test/authorize","token_endpoint":"https://id.test/oauth/token"}"#

    func jwt(_ claims: [String: Any]) -> String {
        let enc = { (o: Any) in Base64URL.encode(try! JSONSerialization.data(withJSONObject: o)) }
        return "\(enc(["alg": "ES256"])).\(enc(claims)).c2ln"
    }
    func claims(nonce: String, exp: Date = Date().addingTimeInterval(7200)) -> [String: Any] {
        ["iss": "https://id.test/", "aud": "offerlane-api", "sub": "dev-user", "exp": exp.timeIntervalSince1970, "nonce": nonce]
    }

    func testFullSignInReturnsTheIDTokenSession() async throws {
        let t = MockTransport { r in
            if r.url?.path == "/.well-known/openid-configuration" { return (200, Data(Self.discovery.utf8)) }
            XCTAssertEqual(r.url?.absoluteString, "https://id.test/oauth/token")
            let form = String(decoding: r.httpBody!, as: UTF8.self)
            XCTAssertTrue(form.contains("grant_type=authorization_code")); XCTAssertTrue(form.contains("code=auth-code"))
            XCTAssertTrue(form.contains("code_verifier=")); XCTAssertTrue(form.contains("client_id=offerlane-api"))
            XCTAssertTrue(form.contains("redirect_uri=http%3A%2F%2Flocalhost%3A"))
            return (200, Data(#"{"id_token":"\#(Self.pending.token)"}"#.utf8))
        }
        let s = CloudSignIn(config: config, transport: t) { url in
            let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(url.host(), "id.test")
            XCTAssertEqual(q["code_challenge_method"], "S256"); XCTAssertEqual(q["scope"], "openid"); XCTAssertEqual(q["client_id"], "offerlane-api")
            Self.pending.token = self.jwt(self.claims(nonce: q["nonce"]!))
            var cb = URLComponents(string: q["redirect_uri"]!)!
            cb.queryItems = [.init(name: "code", value: "auth-code"), .init(name: "state", value: q["state"]!)]
            _ = Task.detached { _ = try await URLSession.shared.data(from: cb.url!) }
        }
        let session = try await s.signIn(timeout: 20)
        XCTAssertEqual(session.sub, "dev-user")
        XCTAssertEqual(session.token, Self.pending.token)
        XCTAssertTrue(session.isValid)
    }
    final class Box: @unchecked Sendable { var token = "" }
    static let pending = Box()

    func testClaimsAreChecked() throws {
        let now = Date()
        XCTAssertNoThrow(try CloudSignIn.session(jwt(claims(nonce: "n")), issuer: "https://id.test/", clientID: "offerlane-api", nonce: "n", now: now))
        var bad: [[String: Any]] = []
        for (k, v) in [("iss", "https://evil.test/"), ("aud", "other-app"), ("nonce", "replayed"), ("sub", "")] as [(String, Any)] {
            var c = claims(nonce: "n"); c[k] = v; bad.append(c)
        }
        bad.append(claims(nonce: "n", exp: now.addingTimeInterval(-1)))
        var noNonce = claims(nonce: "n"); noNonce["nonce"] = nil; bad.append(noNonce)
        for c in bad {
            XCTAssertThrowsError(try CloudSignIn.session(jwt(c), issuer: "https://id.test/", clientID: "offerlane-api", nonce: "n", now: now)) {
                XCTAssertEqual($0 as? CloudSignIn.Failure, .badToken, "\(c)")
            }
        }
        XCTAssertThrowsError(try CloudSignIn.session("not.a-jwt", issuer: "https://id.test/", clientID: "offerlane-api", nonce: "n", now: now))
    }

    func testRefusesCleartextAndBadAnswers() async throws {
        let plain = CloudSignIn(config: .init(api: config.api, issuer: URL(string: "http://id.test/")!, clientID: "x"),
                                transport: MockTransport { _ in XCTFail("no request over http"); return (500, Data()) }) { _ in }
        await assertThrows(.insecure) { _ = try await plain.discover() }
        let downgrade = CloudSignIn(config: config, transport: MockTransport { _ in
            (200, Data(#"{"issuer":"https://id.test/","authorization_endpoint":"http://id.test/authorize","token_endpoint":"https://id.test/t"}"#.utf8)) }) { _ in }
        await assertThrows(.insecure) { _ = try await downgrade.discover() }
        let otherIssuer = CloudSignIn(config: config, transport: MockTransport { _ in
            (200, Data(#"{"issuer":"https://evil.test/","authorization_endpoint":"https://id.test/a","token_endpoint":"https://id.test/t"}"#.utf8)) }) { _ in }
        await assertThrows(.notOIDC) { _ = try await otherIssuer.discover() }
        let s = CloudSignIn(config: config, transport: MockTransport { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }) { _ in }
        let srv = CloudSignIn.Server(authorize: URL(string: "https://id.test/a")!, token: URL(string: "https://id.test/t")!, issuer: "https://id.test/")
        let r = URL(string: "http://localhost:1/")!
        await assertThrows(.stateMismatch) { _ = try await s.complete(srv, callback: ["code": "c", "state": "x"], state: "s", nonce: "n", pkce: PKCE(), redirect: r) }
        await assertThrows(.denied) { _ = try await s.complete(srv, callback: ["error": "access_denied", "state": "s"], state: "s", nonce: "n", pkce: PKCE(), redirect: r) }
        await assertThrows(.rejected) { _ = try await s.complete(srv, callback: ["code": "c", "state": "s"], state: "s", nonce: "n", pkce: PKCE(), redirect: r) }
        XCTAssertTrue(CloudConfig.allowed(URL(string: "http://localhost:9000/")!))
        XCTAssertFalse(CloudConfig.allowed(URL(string: "http://localhost.evil.test/")!))
    }

    func assertThrows(_ want: CloudSignIn.Failure, _ f: () async throws -> Void, line: UInt = #line) async {
        do { try await f(); XCTFail("no error", line: line) } catch { XCTAssertEqual(error as? CloudSignIn.Failure, want, line: line) }
    }
}
