import Foundation

/// Where the Offerlane cloud is: the API and its OIDC provider. Info.plist keys OfferlaneAPIOrigin / OfferlaneOIDCIssuer /
/// OfferlaneOIDCClientID; the defaults are the local dev stack (compose.dev.yml), like the web's vite.config.ts.
// SHORTCUT: the dev defaults stand until hosting (P2 H2/H3) sets the real values, the same step as the web's VITE_* origins.
public struct CloudConfig: Sendable, Equatable {
    public var api: URL, issuer: URL, clientID: String
    public init(api: URL, issuer: URL, clientID: String) { self.api = api; self.issuer = issuer; self.clientID = clientID }
    public static let dev = CloudConfig(api: URL(string: "http://localhost:8787")!, issuer: URL(string: "http://localhost:9000/")!, clientID: "offerlane-api")
    public static func load(bundle: Bundle = .main) -> CloudConfig {
        var c = dev
        let s = { (k: String) in (bundle.object(forInfoDictionaryKey: k) as? String).flatMap { $0.isEmpty ? nil : $0 } }
        if let v = s("OfferlaneAPIOrigin").flatMap(URL.init(string:)) { c.api = v }
        if let v = s("OfferlaneOIDCIssuer").flatMap(URL.init(string:)) { c.issuer = v }
        if let v = s("OfferlaneOIDCClientID") { c.clientID = v }
        if let v = TestHooks.env["OFFERLANE_API_ORIGIN"].flatMap(URL.init(string:)) { c.api = v }
        if let v = TestHooks.env["OFFERLANE_OIDC_ISSUER"].flatMap(URL.init(string:)) { c.issuer = v }
        return c
    }
    /// https only, except the loopback dev stack.
    static func allowed(_ u: URL) -> Bool {
        u.scheme == "https" || (u.scheme == "http" && ["localhost", "127.0.0.1"].contains(u.host() ?? ""))
    }
}

/// The bearer the API takes: the ID token (the API's OIDC_AUDIENCE is our client id), as on the web (apps/web/src/auth.ts).
public struct CloudSession: Codable, Sendable, Equatable {
    public var token: String, sub: String, expires: Date
    public var isValid: Bool { expires > Date().addingTimeInterval(60) }
}

/// Sign-in to the Offerlane cloud: OIDC authorization code + PKCE (S256) + state + nonce, loopback redirect.
/// The ID token comes straight from the token endpoint over TLS, so the client checks its claims (iss, aud, exp, nonce)
/// and leaves the signature to the API, which verifies it on every call (OIDC Core 3.1.3.7).
public struct CloudSignIn: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case insecure, unreachable, notOIDC, stateMismatch, denied, rejected, badToken
        public var errorDescription: String? {
            switch self {
            case .insecure: "The sign-in service isn't using a secure connection, so Offerlane didn't use it."
            case .unreachable: "Couldn't reach the sign-in service. Check your connection and try again."
            case .notOIDC: "The sign-in service isn't set up for app sign-in."
            case .stateMismatch: "The sign-in answer didn't match this request, so Offerlane ignored it for your safety. Try again."
            case .denied: "Sign-in was cancelled."
            case .rejected: "The sign-in service refused the sign-in. It expires after a minute or so; try again."
            case .badToken: "The sign-in service sent an answer Offerlane can't use. Try again."
            }
        }
    }

    public let config: CloudConfig
    public let transport: any HTTPTransport
    public let openBrowser: @Sendable (URL) async -> Void
    public init(config: CloudConfig, transport: any HTTPTransport = URLSessionTransport(), openBrowser: @escaping @Sendable (URL) async -> Void) {
        self.config = config; self.transport = transport; self.openBrowser = openBrowser
    }

    struct Server { var authorize: URL; var token: URL; var issuer: String }

    func discover() async throws -> Server {
        guard CloudConfig.allowed(config.issuer) else { throw Failure.insecure }
        let url = config.issuer.appendingPathComponent(".well-known/openid-configuration")
        var r = URLRequest(url: url); r.timeoutInterval = 15
        let (d, resp): (Data, HTTPURLResponse)
        do { (d, resp) = try await transport.send(r) } catch { throw Failure.unreachable }
        guard resp.statusCode == 200, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let a = (j["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let t = (j["token_endpoint"] as? String).flatMap(URL.init(string:)), let iss = j["issuer"] as? String else { throw Failure.notOIDC }
        guard CloudConfig.allowed(a), CloudConfig.allowed(t) else { throw Failure.insecure }
        return Server(authorize: a, token: t, issuer: iss)
    }

    public func signIn(timeout: TimeInterval = 300) async throws -> CloudSession {
        let as_ = try await discover()
        let server = try LoopbackServer()
        defer { server.stop() }
        let redirect = try await server.start(host: "localhost")
        let pkce = PKCE(), state = Base64URL.random(), nonce = Base64URL.random()
        await openBrowser(authorizationURL(as_, redirect: redirect, pkce: pkce, state: state, nonce: nonce))
        return try await complete(as_, callback: try await server.waitForCallback(timeout: timeout), state: state, nonce: nonce, pkce: pkce, redirect: redirect)
    }

    func authorizationURL(_ s: Server, redirect: URL, pkce: PKCE, state: String, nonce: String) -> URL {
        var c = URLComponents(url: s.authorize, resolvingAgainstBaseURL: false)!
        c.queryItems = (c.queryItems ?? []) + [
            .init(name: "client_id", value: config.clientID), .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: "openid"), .init(name: "state", value: state),
            .init(name: "nonce", value: nonce), .init(name: "code_challenge", value: pkce.challenge), .init(name: "code_challenge_method", value: pkce.method),
        ]
        return c.url!
    }

    func complete(_ s: Server, callback q: [String: String], state: String, nonce: String, pkce: PKCE, redirect: URL, now: Date = Date()) async throws -> CloudSession {
        guard let got = q["state"], constantTimeEquals(got, state) else { throw Failure.stateMismatch }
        if q["error"] != nil { throw Failure.denied }
        guard let code = q["code"], !code.isEmpty else { throw Failure.denied }
        var r = URLRequest(url: s.token); r.httpMethod = "POST"; r.timeoutInterval = 15
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        let form = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirect.absoluteString, "client_id": config.clientID, "code_verifier": pkce.verifier]
        r.httpBody = Data(form.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
        let (d, resp): (Data, HTTPURLResponse)
        do { (d, resp) = try await transport.send(r) } catch { throw Failure.unreachable }
        guard resp.statusCode == 200 else { throw Failure.rejected }
        guard let token = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["id_token"] as? String else { throw Failure.badToken }
        return try Self.session(token, issuer: s.issuer, clientID: config.clientID, nonce: nonce, now: now)
    }

    static func session(_ jwt: String, issuer: String, clientID: String, nonce: String, now: Date) throws -> CloudSession {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = Base64URL.decode(String(parts[1])),
              let c = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw Failure.badToken }
        let aud = (c["aud"] as? String).map { [$0] } ?? (c["aud"] as? [String]) ?? []
        guard c["iss"] as? String == issuer, aud.contains(clientID), let sub = c["sub"] as? String, !sub.isEmpty,
              let exp = (c["exp"] as? NSNumber)?.doubleValue, Date(timeIntervalSince1970: exp) > now,
              let n = c["nonce"] as? String, constantTimeEquals(n, nonce) else { throw Failure.badToken }
        return CloudSession(token: jwt, sub: sub, expires: Date(timeIntervalSince1970: exp))
    }
}
