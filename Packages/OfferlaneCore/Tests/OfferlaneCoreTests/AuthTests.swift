import os
import XCTest
import Security
@testable import OfferlaneCore

/// Scripted HTTP server: each request is answered by `handler`; every request is recorded.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }
    let handler: @Sendable (URLRequest) throws -> (Int, Data)
    init(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let (code, body) = try handler(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

func form(_ r: URLRequest) -> [String: String] {
    var out: [String: String] = [:]
    for pair in String(decoding: r.httpBody ?? Data(), as: UTF8.self).split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
        if kv.count == 2 { out[kv[0]] = kv[1] }
    }
    return out
}
func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

/// A throwaway RSA key standing in for Google's signing key.
struct TestSigner {
    let key: SecKey
    let kid = "test-kid"
    init() {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        key = SecKeyCreateRandomKey(attrs as CFDictionary, nil)!
    }
    var jwks: Data {
        let der = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data
        let (n, e) = Self.parsePKCS1(der)
        return json(["keys": [["kty": "RSA", "alg": "RS256", "use": "sig", "kid": kid, "n": Base64URL.encode(n), "e": Base64URL.encode(e)]]])
    }
    func token(_ claims: [String: Any], kid: String? = nil, alg: String = "RS256") -> String {
        let h = Base64URL.encode(json(["alg": alg, "kid": kid ?? self.kid, "typ": "JWT"]))
        let p = Base64URL.encode(json(claims))
        let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data("\(h).\(p)".utf8) as CFData, nil)! as Data
        return "\(h).\(p).\(Base64URL.encode(sig))"
    }
    /// Minimal DER reader for RSAPublicKey ::= SEQUENCE { n INTEGER, e INTEGER }.
    static func parsePKCS1(_ d: Data) -> (Data, Data) {
        let b = [UInt8](d); var i = 0
        func len() -> Int {
            let first = Int(b[i]); i += 1
            if first < 0x80 { return first }
            var n = 0; for _ in 0..<(first & 0x7F) { n = n << 8 | Int(b[i]); i += 1 }; return n
        }
        i += 1; _ = len()                       // SEQUENCE
        i += 1; let nl = len(); let n = Data(b[i..<i + nl]); i += nl
        i += 1; let el = len(); let e = Data(b[i..<i + el])
        return (n, e)
    }
}

final class AuthTests: XCTestCase {
    let clientID = "123-test.apps.googleusercontent.com"
    var signer: TestSigner!
    var tmp: URL!
    var authKeychain: Keychain!

    override func setUp() {
        signer = TestSigner()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("offerlane-auth-\(UUID().uuidString)")
        authKeychain = Keychain(service: "com.somilmanke.Offerlane.tests.\(UUID().uuidString)")
    }
    override func tearDown() {
        authKeychain.deleteAll()
        try? FileManager.default.removeItem(at: tmp)
    }

    func claims(nonce: String, aud: Any? = nil, exp: TimeInterval = 3600, iss: String = "https://accounts.google.com", verified: Bool = true) -> [String: Any] {
        let now = Date().timeIntervalSince1970
        return ["iss": iss, "aud": aud ?? clientID, "sub": "1084", "email": "Test@Example.com", "email_verified": verified,
                "name": "Test Person", "iat": now, "exp": now + exp, "nonce": nonce]
    }

    // MARK: PKCE / state

    func testPKCEMatchesRFC7636Vector() {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(p.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(p.method, "S256")
        let a = PKCE(), b = PKCE()
        XCTAssertNotEqual(a.verifier, b.verifier, "fresh verifier every time")
        XCTAssertTrue((43...128).contains(a.verifier.count), "RFC 7636 length")
        XCTAssertNil(a.verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")), "base64url, unpadded")
    }

    func testAuthorizationURLCarriesPKCEStateNonceAndMinimalScopes() {
        let o = GoogleOAuth(config: OAuthConfig(clientID: clientID), transport: MockTransport { _ in (500, Data()) }) { _ in }
        let p = PKCE()
        let url = o.authorizationURL(scopes: GoogleOAuth.signInScopes, redirect: URL(string: "http://127.0.0.1:5555/callback")!,
                                     pkce: p, state: "S", nonce: "N", loginHint: nil)
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["scope"], "openid email profile", "sign-in asks for non-sensitive scopes only")
        XCTAssertEqual(q["code_challenge"], p.challenge); XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["state"], "S"); XCTAssertEqual(q["nonce"], "N"); XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["redirect_uri"], "http://127.0.0.1:5555/callback")
        XCTAssertNil(q["client_secret"], "the secret never goes in the browser URL")
    }

    func testStateMismatchAndDenialAreRejectedBeforeAnyNetworkCall() async {
        let t = MockTransport { _ in XCTFail("no token request"); return (500, Data()) }
        let o = GoogleOAuth(config: OAuthConfig(clientID: clientID), transport: t) { _ in }
        let r = URL(string: "http://127.0.0.1:1/callback")!
        do { _ = try await o.complete(callback: ["state": "evil", "code": "c"], expectedState: "good", nonce: "n", pkce: PKCE(), redirect: r); XCTFail() }
        catch { XCTAssertEqual(error as? OAuthError, .stateMismatch) }
        do { _ = try await o.complete(callback: ["code": "c"], expectedState: "good", nonce: "n", pkce: PKCE(), redirect: r); XCTFail() }
        catch { XCTAssertEqual(error as? OAuthError, .stateMismatch, "missing state is a mismatch") }
        do { _ = try await o.complete(callback: ["state": "good", "error": "access_denied"], expectedState: "good", nonce: "n", pkce: PKCE(), redirect: r); XCTFail() }
        catch { XCTAssertEqual(error as? OAuthError, .denied) }
        XCTAssertTrue(t.requests.isEmpty)
    }

    func testUnconfiguredClientIDRefusesToStart() async {
        let o = GoogleOAuth(config: OAuthConfig(clientID: OAuthConfig.placeholder), transport: MockTransport { _ in (500, Data()) }) { _ in XCTFail("no browser") }
        do { _ = try await o.authorize(); XCTFail() } catch { XCTAssertEqual(error as? OAuthError, .notConfigured) }
    }

    // MARK: ID token

    func testIDTokenVerifiesSignatureAndClaims() throws {
        let id = try IDToken.verify(signer.token(claims(nonce: "n1")), jwks: signer.jwks, clientID: clientID, nonce: "n1")
        XCTAssertEqual(id.sub, "1084"); XCTAssertEqual(id.email, "test@example.com"); XCTAssertEqual(id.name, "Test Person")

        func fails(_ jwt: String, _ expected: IDToken.Failure, nonce: String = "n1", line: UInt = #line) {
            XCTAssertThrowsError(try IDToken.verify(jwt, jwks: signer.jwks, clientID: clientID, nonce: nonce), line: line) {
                XCTAssertEqual($0 as? IDToken.Failure, expected, line: line)
            }
        }
        fails(signer.token(claims(nonce: "n1")), .nonceMismatch, nonce: "other")
        fails(signer.token(claims(nonce: "n1", aud: "someone-else.apps.googleusercontent.com")), .wrongAudience)
        fails(signer.token(claims(nonce: "n1", aud: ["x", clientID])), .wrongAudience)        // multi-aud without azp
        fails(signer.token(claims(nonce: "n1", exp: -3600)), .expired)
        fails(signer.token(claims(nonce: "n1", iss: "https://evil.example")), .wrongIssuer)
        fails(signer.token(claims(nonce: "n1", verified: false)), .emailNotVerified)
        fails(signer.token(claims(nonce: "n1"), kid: "unknown"), .unknownKey)
        fails(signer.token(claims(nonce: "n1"), alg: "none"), .unsupportedAlgorithm("none"))
        fails("not.a.jwt", .malformed)
        // A token signed by a different key, presented with our kid.
        fails(TestSigner().token(claims(nonce: "n1"), kid: signer.kid), .badSignature)
        // Tampered payload, original signature.
        let parts = signer.token(claims(nonce: "n1")).split(separator: ".").map(String.init)
        var c = claims(nonce: "n1"); c["email"] = "attacker@example.com"
        fails([parts[0], Base64URL.encode(json(c)), parts[2]].joined(separator: "."), .badSignature)
    }

    // MARK: full flow through the real loopback server

    func testFullSignInThroughLoopbackWithMockGoogle() async throws {
        let signer = self.signer!, clientID = self.clientID
        let captured = NSLock(); nonisolated(unsafe) var nonce = ""
        let t = MockTransport { r in
            if r.url!.absoluteString.hasSuffix("/certs") { return (200, signer.jwks) }
            let f = form(r)
            XCTAssertEqual(f["grant_type"], "authorization_code"); XCTAssertEqual(f["code"], "auth-code")
            XCTAssertFalse((f["code_verifier"] ?? "").isEmpty, "PKCE verifier sent")
            XCTAssertTrue(f["redirect_uri"]!.hasPrefix("http://127.0.0.1:"))
            let n = captured.withLock { nonce }
            let now = Date().timeIntervalSince1970
            let idt = signer.token(["iss": "accounts.google.com", "aud": clientID, "sub": "1084", "email": "t@example.com",
                                    "email_verified": true, "iat": now, "exp": now + 3600, "nonce": n])
            return (200, json(["access_token": "at", "expires_in": 3599, "id_token": idt, "scope": "openid email profile", "token_type": "Bearer"]))
        }
        // The "browser": read state/nonce from the authorization URL, then hit the loopback redirect like Google would.
        let o = GoogleOAuth(config: OAuthConfig(clientID: clientID), transport: t) { url in
            let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            captured.withLock { nonce = q["nonce"]! }
            var cb = URLComponents(string: q["redirect_uri"]!)!
            cb.queryItems = [.init(name: "code", value: "auth-code"), .init(name: "state", value: q["state"]!)]
            _ = Task.detached {
                // A stray request first (browsers ask for favicons) must not end the flow.
                _ = try? await URLSession.shared.data(from: URL(string: q["redirect_uri"]!.replacingOccurrences(of: "/callback", with: "/favicon.ico"))!)
                let (body, _) = try await URLSession.shared.data(from: cb.url!)
                XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("You're signed in"))
            }
        }
        let grant = try await o.authorize(timeout: 20)
        XCTAssertEqual(grant.identity.sub, "1084")
        XCTAssertEqual(grant.tokens.accessToken, "at")
        XCTAssertNil(grant.tokens.refreshToken, "sign-in alone asks for no offline access")

        let accounts = AccountStore(base: tmp, keychain: authKeychain)
        let a = try accounts.googleAccount(for: grant.identity)
        XCTAssertEqual(try accounts.googleAccount(for: grant.identity).id, a.id, "same Google user → same local profile")
    }

    func testLoopbackTimesOut() async throws {
        let s = try LoopbackServer(); _ = try await s.start()
        do { _ = try await s.waitForCallback(timeout: 0.3); XCTFail() } catch { XCTAssertTrue(error is LoopbackServer.Failure) }
    }

    // MARK: tokens

    func testRefreshRotatesAndRevokedTokensAreDropped() async throws {
        let mode = OSAllocatedUnfairLock(initialState: "ok")
        let t = MockTransport { r in
            XCTAssertEqual(form(r)["grant_type"], "refresh_token")
            return mode.withLock { $0 } == "ok" ? (200, json(["access_token": "fresh", "expires_in": 3600, "scope": "openid \(GoogleOAuth.gmailScope)"]))
                                : (400, json(["error": "invalid_grant", "error_description": "Token has been expired or revoked."]))
        }
        let o = GoogleOAuth(config: OAuthConfig(clientID: clientID), transport: t) { _ in }
        let accounts = AccountStore(base: tmp, keychain: authKeychain)
        try accounts.saveGoogleTokens(GoogleTokens(accessToken: "old", accessExpiry: Date(timeIntervalSinceNow: -10), refreshToken: "rt",
                                                   scopes: ["openid", GoogleOAuth.gmailScope]), for: "acct1")
        let provider = GoogleTokenProvider(oauth: o, accounts: accounts, accountID: "acct1")
        let fresh = try await provider.token()
        XCTAssertEqual(fresh, "fresh")
        XCTAssertEqual(accounts.googleTokens(for: "acct1")?.refreshToken, "rt", "refresh token kept when Google doesn't rotate it")
        let reused = try await provider.token()
        XCTAssertEqual(reused, "fresh", "valid token reused without a request")
        XCTAssertEqual(t.requests.count, 1)

        mode.withLock { $0 = "revoked" }
        var expired = accounts.googleTokens(for: "acct1")!; expired.accessExpiry = .distantPast
        try accounts.saveGoogleTokens(expired, for: "acct1")
        do { _ = try await provider.token(); XCTFail() } catch { XCTAssertEqual(error as? OAuthError, .revoked) }
        XCTAssertNil(accounts.googleTokens(for: "acct1"), "revoked tokens removed from Keychain")
    }

    // MARK: email + password

    func testPasswordAccountHashingLockoutAndBackoff() throws {
        let accounts = AccountStore(base: tmp, keychain: authKeychain)
        XCTAssertThrowsError(try accounts.createPasswordAccount(email: "a@b.co", name: "A", password: "short", iterations: 1000))
        let a = try accounts.createPasswordAccount(email: " Me@Example.com ", name: "Me", password: "correct horse battery", iterations: 1000)
        XCTAssertEqual(a.email, "me@example.com")
        XCTAssertThrowsError(try accounts.createPasswordAccount(email: "me@example.com", name: "x", password: "another long pass", iterations: 1000)) {
            XCTAssertEqual($0 as? AccountStore.AuthFailure, .emailTaken)
        }
        let v = accounts.verifier(for: a.id)!
        XCTAssertEqual(v.salt.count, 16); XCTAssertEqual(v.hash.count, 32)
        XCTAssertFalse(String(decoding: (try? Data(contentsOf: tmp.appendingPathComponent("accounts.json"))) ?? Data(), as: UTF8.self).contains("horse"),
                       "nothing secret in accounts.json")
        XCTAssertNotEqual(PasswordVerifier.make("same password!!", iterations: 1000).hash, PasswordVerifier.make("same password!!", iterations: 1000).hash,
                          "per-user salt")
        XCTAssertEqual(PasswordVerifier.defaultIterations, 600_000)

        let t0 = Date()
        for i in 1...4 {
            XCTAssertThrowsError(try accounts.signIn(email: "me@example.com", password: "wrong", now: t0)) {
                XCTAssertEqual($0 as? AccountStore.AuthFailure, .wrongPassword(remaining: 5 - i))
            }
        }
        XCTAssertThrowsError(try accounts.signIn(email: "me@example.com", password: "wrong", now: t0)) {
            XCTAssertEqual($0 as? AccountStore.AuthFailure, .locked(until: t0.addingTimeInterval(30)))
        }
        XCTAssertThrowsError(try accounts.signIn(email: "me@example.com", password: "correct horse battery", now: t0.addingTimeInterval(10)),
                             "even the right password waits out the lock")
        XCTAssertThrowsError(try accounts.signIn(email: "me@example.com", password: "wrong", now: t0.addingTimeInterval(31))) {
            XCTAssertEqual($0 as? AccountStore.AuthFailure, .locked(until: t0.addingTimeInterval(31 + 60)), "backoff doubles")
        }
        XCTAssertEqual(Lockout.delay(afterFailures: 30), 3600, "capped at an hour")
        let ok = try accounts.signIn(email: "ME@example.com", password: "correct horse battery", now: t0.addingTimeInterval(200))
        XCTAssertEqual(ok.id, a.id)
        XCTAssertEqual(accounts.verifier(for: a.id)?.failures, 0, "success resets the counter")
        XCTAssertThrowsError(try accounts.signIn(email: "nobody@example.com", password: "x")) { XCTAssertEqual($0 as? AccountStore.AuthFailure, .unknownEmail) }
    }

    func testPasswordStrength() {
        XCTAssertEqual(PasswordStrength.score("password"), 0)
        XCTAssertNotNil(PasswordStrength.problem("abc"))
        XCTAssertNotNil(PasswordStrength.problem("aaaaaaaaaaaa"))
        XCTAssertNil(PasswordStrength.problem("correct horse battery"))
        XCTAssertGreaterThanOrEqual(PasswordStrength.score("Tr1cky-Lane-2026!"), 3)
    }

    // MARK: session

    func testSessionSurvivesRestartAndSignOutKeepsData() throws {
        let accounts = AccountStore(base: tmp, keychain: authKeychain)
        let a = try accounts.createPasswordAccount(email: "s@example.com", name: "S", password: "correct horse battery", iterations: 1000)
        try accounts.startSession(a)
        try accounts.saveGoogleTokens(GoogleTokens(accessToken: "x", accessExpiry: .distantFuture, refreshToken: "r", scopes: []), for: a.id)
        let dataFile = Paths.accountRoot(a.id, base: tmp).appendingPathComponent("offerlane.sqlite")
        _ = try Store(url: dataFile)

        let relaunched = AccountStore(base: tmp, keychain: authKeychain)   // a new process reads the same Keychain + file
        XCTAssertEqual(relaunched.session?.accountID, a.id)
        relaunched.signOut()
        XCTAssertNil(relaunched.session)
        XCTAssertNil(relaunched.googleTokens(for: a.id), "tokens cleared on sign out")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataFile.path), "data kept on sign out")
        XCTAssertNotNil(relaunched.account(a.id))

        try relaunched.erase(a.id)
        XCTAssertNil(relaunched.account(a.id)); XCTAssertNil(relaunched.verifier(for: a.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataFile.path), "erase removes the profile's data")
    }

    // MARK: v0.1 migration

    func testClaimV01DataBacksUpThenMovesDataAndSecrets() throws {
        let legacyKeychain = Keychain(service: "com.somilmanke.Offerlane.tests.legacy.\(UUID().uuidString)")
        defer { legacyKeychain.deleteAll() }
        // A v0.1 install: database + tailored files in the base folder, secrets in the shared Keychain service.
        do {
            let s = try Store(url: tmp.appendingPathComponent("offerlane.sqlite"))
            try DemoData.seedMatches(s)
        }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("Applications/globex"), withIntermediateDirectories: true)
        try Data("cv".utf8).write(to: tmp.appendingPathComponent("Applications/globex/resume.pdf"))
        try legacyKeychain.set("sk-test", account: Keychain.Account.anthropicKey)

        let accounts = AccountStore(base: tmp, keychain: authKeychain)
        XCTAssertTrue(LegacyData.available(base: tmp, accounts: accounts))
        let a = try accounts.createPasswordAccount(email: "m@example.com", name: "M", password: "correct horse battery", iterations: 1000)
        let accountKeychain = Keychain(service: Paths.keychainService(for: a.id)); defer { accountKeychain.deleteAll() }

        let report = try LegacyData.claim(into: a.id, base: tmp, accounts: accounts, legacyKeychain: legacyKeychain)
        let dest = Paths.accountRoot(a.id, base: tmp)
        XCTAssertEqual(report.roles, 4, "all v0.1 roles readable in the new location")
        XCTAssertEqual(report.secrets, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.backup.appendingPathComponent("offerlane.sqlite").path), "backup taken first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.backup.appendingPathComponent("Applications/globex/resume.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Applications/globex/resume.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("offerlane.sqlite").path), "moved, not duplicated")
        XCTAssertEqual(accountKeychain.get(account: Keychain.Account.anthropicKey), "sk-test")
        XCTAssertNil(legacyKeychain.get(account: Keychain.Account.anthropicKey), "secret now isolated to the account")
        XCTAssertFalse(LegacyData.available(base: tmp, accounts: accounts), "only offered once")
        XCTAssertEqual(try Store(url: report.backup.appendingPathComponent("offerlane.sqlite")).jobs().count, 4, "backup is a working database")
    }

    // MARK: Gmail

    func testGmailListsMetadataAndFetchesBodyOnlyWhenNeeded() async throws {
        let html = "<p>Confirm your account: <a href=\"https://acme.wd1.myworkdayjobs.com/verify?token=abc\">Verify</a></p>"
        let t = MockTransport { r in
            XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            let u = r.url!.absoluteString
            if u.contains("/messages?") { XCTAssertTrue(u.contains("q=newer_than:4d")); return (200, json(["messages": [["id": "m1"], ["id": "m2"]]])) }
            let format = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "format" }!.value!
            let id = r.url!.lastPathComponent
            if format == "metadata" {
                let subject = id == "m1" ? "Your application to Globex" : "Verify your Workday account"
                return (200, json(["id": id, "snippet": "Thanks for applying &amp; good luck",
                                   "payload": ["headers": [["name": "From", "value": "jobs@globex.com"], ["name": "Subject", "value": subject]]]]))
            }
            XCTAssertEqual(id, "m2", "body fetched only for the verification mail")
            return (200, json(["id": id, "payload": ["mimeType": "multipart/alternative", "parts": [
                ["mimeType": "text/html", "body": ["data": Base64URL.encode(Data(html.utf8))]]]]]))
        }
        let g = GmailClient(transport: t) { "tok" }
        let mails = try await g.fetch(days: 4) { Re.search("verif|activat|confirm", $0.subject) }
        XCTAssertEqual(mails.map(\.id), ["gmail:m1", "gmail:m2"])
        XCTAssertEqual(mails[0].snippet, "Thanks for applying & good luck")
        XCTAssertEqual(t.requests.count, 4, "list + 2 metadata + 1 body")
        let v = Tracking.verification(in: mails, hint: "workday")
        XCTAssertEqual(v?.link, "https://acme.wd1.myworkdayjobs.com/verify?token=abc")
    }

    func testGmail401MeansReconnect() async {
        let g = GmailClient(transport: MockTransport { _ in (401, Data()) }) { "tok" }
        do { _ = try await g.fetch(); XCTFail() } catch { XCTAssertEqual(error as? OAuthError, .revoked) }
    }
}
