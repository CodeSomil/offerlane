import Foundation

/// Google OAuth settings. The client ID lives in ONE file: App/Resources/OAuthConfig.plist (placeholder until you fill it in).
public struct OAuthConfig: Sendable, Equatable {
    public static let placeholder = "REPLACE_WITH_YOUR_DESKTOP_CLIENT_ID.apps.googleusercontent.com"
    public var clientID: String
    /// Google's "Desktop app" client type issues a secret that is NOT confidential (it ships in every copy of the app);
    /// Google still requires it on the token endpoint. Security comes from PKCE + the loopback redirect, not from this value.
    public var clientSecret: String
    /// Gmail inbox reading (restricted scope): only while the Google project is in Testing mode, for named test users.
    public var gmailEnabled: Bool
    public var authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public var tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    public var jwksURL = URL(string: "https://www.googleapis.com/oauth2/v3/certs")!
    public var revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!

    public init(clientID: String, clientSecret: String = "", gmailEnabled: Bool = false) {
        self.clientID = clientID; self.clientSecret = clientSecret; self.gmailEnabled = gmailEnabled
    }
    public var isConfigured: Bool { !clientID.isEmpty && clientID != Self.placeholder && clientID.hasSuffix(".apps.googleusercontent.com") }

    /// Reads OAuthConfig.plist from `bundle`. OFFERLANE_GMAIL=1 turns the Gmail preview on for testing.
    public static func load(bundle: Bundle = .main) -> OAuthConfig {
        var c = OAuthConfig(clientID: Self.placeholder)
        if let url = bundle.url(forResource: "OAuthConfig", withExtension: "plist"), let data = try? Data(contentsOf: url),
           let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            c.clientID = (d["GoogleClientID"] as? String ?? c.clientID).trimmingCharacters(in: .whitespaces)
            c.clientSecret = (d["GoogleClientSecret"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            c.gmailEnabled = d["GmailTestingMode"] as? Bool ?? false
        }
        if TestHooks.env["OFFERLANE_GMAIL"] == "1" { c.gmailEnabled = true }
        return c
    }
}

/// Sends HTTP requests (URLSession in the app, a scripted mock in tests).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init() {
        let c = URLSessionConfiguration.ephemeral          // no cookies, no cache: nothing about the user is kept here
        c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.urlCache = nil; c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 30
        session = URLSession(configuration: c)
    }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (d, r) = try await session.data(for: request)
        guard let h = r as? HTTPURLResponse else { throw OAuthError.network("No answer from the server.") }
        return (d, h)
    }
}

public struct GoogleTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var accessExpiry: Date
    public var refreshToken: String?
    public var scopes: [String]
    public func has(_ scope: String) -> Bool { scopes.contains(scope) }
}

public enum OAuthError: Error, Equatable, LocalizedError {
    case notConfigured, stateMismatch, denied, revoked, missingCode
    case http(Int, String), network(String)
    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Google sign-in isn't set up in this copy of Offerlane yet. Use email and password instead."
        case .stateMismatch: "The sign-in answer didn't match this request, so Offerlane ignored it for your safety. Try again."
        case .denied: "Google sign-in was cancelled. Try again whenever you're ready."
        case .revoked: "Your Google connection has expired or was removed. Connect again to keep going."
        case .missingCode: "Google didn't send a sign-in code. Try again."
        case .http(let code, _): "Google couldn't complete sign-in (error \(code)). Try again in a moment."
        case .network: "Offerlane couldn't reach Google. Check your internet connection and try again."
        }
    }
}

/// Google sign-in for a desktop app: authorization code + PKCE, loopback redirect on 127.0.0.1,
/// `state` and `nonce` checked, ID token signature and claims verified.
public struct GoogleOAuth: Sendable {
    public static let signInScopes = ["openid", "email", "profile"]
    public static let gmailScope = "https://www.googleapis.com/auth/gmail.readonly"

    public let config: OAuthConfig
    public let transport: any HTTPTransport
    /// Opens the authorization page (the user's browser in the app; a simulated browser in tests).
    public let openBrowser: @Sendable (URL) async -> Void
    public var now: @Sendable () -> Date = { Date() }

    public init(config: OAuthConfig, transport: any HTTPTransport = URLSessionTransport(), openBrowser: @escaping @Sendable (URL) async -> Void) {
        self.config = config; self.transport = transport; self.openBrowser = openBrowser
    }

    public struct Grant: Sendable, Equatable {
        public let identity: IDToken
        public let tokens: GoogleTokens
    }

    /// Runs the whole browser flow. `scopes` beyond sign-in are requested incrementally (`include_granted_scopes`).
    public func authorize(scopes: [String] = GoogleOAuth.signInScopes, loginHint: String? = nil, timeout: TimeInterval = 300) async throws -> Grant {
        guard config.isConfigured else { throw OAuthError.notConfigured }
        let server = try LoopbackServer()
        defer { server.stop() }
        let redirect = try await server.start()
        let pkce = PKCE(), state = Base64URL.random(), nonce = Base64URL.random()
        let url = authorizationURL(scopes: scopes, redirect: redirect, pkce: pkce, state: state, nonce: nonce, loginHint: loginHint)
        await openBrowser(url)
        let q = try await server.waitForCallback(timeout: timeout)
        return try await complete(callback: q, expectedState: state, nonce: nonce, pkce: pkce, redirect: redirect)
    }

    public func authorizationURL(scopes: [String], redirect: URL, pkce: PKCE, state: String, nonce: String, loginHint: String?) -> URL {
        var c = URLComponents(url: config.authURL, resolvingAgainstBaseURL: false)!
        let wantsOffline = scopes.contains(Self.gmailScope)
        c.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: pkce.method),
            .init(name: "include_granted_scopes", value: "true"),
            .init(name: "access_type", value: wantsOffline ? "offline" : "online"),
            .init(name: "prompt", value: wantsOffline ? "consent" : "select_account"),
        ] + (loginHint.map { [.init(name: "login_hint", value: $0)] } ?? [])
        return c.url!
    }

    /// Checks the redirect, exchanges the code and verifies the ID token.
    public func complete(callback q: [String: String], expectedState: String, nonce: String, pkce: PKCE, redirect: URL) async throws -> Grant {
        guard let state = q["state"], constantTimeEquals(state, expectedState) else { throw OAuthError.stateMismatch }
        if let e = q["error"] { throw e == "access_denied" ? OAuthError.denied : OAuthError.http(400, e) }
        guard let code = q["code"], !code.isEmpty else { throw OAuthError.missingCode }
        let body = try await post(config.tokenURL, [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect.absoluteString,
            "client_id": config.clientID, "client_secret": config.clientSecret, "code_verifier": pkce.verifier,
        ])
        guard let idToken = body["id_token"] as? String else { throw OAuthError.http(200, "no id_token") }
        let (jwks, jr) = try await send(URLRequest(url: config.jwksURL))
        guard jr.statusCode == 200 else { throw OAuthError.http(jr.statusCode, "jwks") }
        let identity = try IDToken.verify(idToken, jwks: jwks, clientID: config.clientID, nonce: nonce, now: now())
        return Grant(identity: identity, tokens: tokens(from: body, previous: nil))
    }

    /// A fresh access token. Throws `.revoked` when Google no longer accepts the refresh token.
    public func refresh(_ t: GoogleTokens) async throws -> GoogleTokens {
        guard let rt = t.refreshToken else { throw OAuthError.revoked }
        let body = try await post(config.tokenURL, ["grant_type": "refresh_token", "refresh_token": rt,
                                                    "client_id": config.clientID, "client_secret": config.clientSecret])
        return tokens(from: body, previous: t)
    }

    /// Best effort: tells Google to drop the grant (used by Disconnect Gmail).
    public func revoke(_ token: String) async {
        _ = try? await post(config.revokeURL, ["token": token])
    }

    private func tokens(from body: [String: Any], previous: GoogleTokens?) -> GoogleTokens {
        let expiresIn = (body["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let scopes = (body["scope"] as? String)?.split(separator: " ").map(String.init) ?? previous?.scopes ?? []
        return GoogleTokens(accessToken: body["access_token"] as? String ?? "", accessExpiry: now().addingTimeInterval(expiresIn - 60),
                            refreshToken: (body["refresh_token"] as? String) ?? previous?.refreshToken, scopes: scopes)
    }

    private func post(_ url: URL, _ form: [String: String]) async throws -> [String: Any] {
        var r = URLRequest(url: url); r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        r.httpBody = Data(form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
        let (d, resp) = try await send(r)
        let json = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard resp.statusCode == 200 else {
            let err = json["error"] as? String ?? ""
            if err == "invalid_grant" { throw OAuthError.revoked }
            throw OAuthError.http(resp.statusCode, err)
        }
        return json
    }

    private func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await transport.send(r) }
        catch let e as OAuthError { throw e }
        catch { throw OAuthError.network(error.localizedDescription) }
    }
}
