import Foundation

/// "Sign in with <provider>" that hands the app an API key: browser authorization + PKCE (S256) + `state`,
/// loopback redirect, then the code is exchanged for a key. Endpoints come from the registry (`ProviderSpec.pkceSignIn`).
/// Flow per https://openrouter.ai/docs/use-cases/oauth-pkce (checked 2026-11-11).
public struct PKCESignIn: Sendable {
    public struct Endpoints: Codable, Sendable, Equatable {
        public var authURL: URL
        public var exchangeURL: URL
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case stateMismatch, denied, missingCode, rejected(Int), noKey, network
        public var errorDescription: String? {
            switch self {
            case .stateMismatch: "The sign-in answer didn't match this request, so Offerlane ignored it for your safety. Try again."
            case .denied: "Sign-in was cancelled. Try again, or paste a key instead."
            case .missingCode, .noKey: "The provider didn't send a key back. Try again, or paste a key instead."
            case .rejected(let code): "The provider refused the sign-in (error \(code)). The code expires after 10 minutes, so try again."
            case .network: "Offerlane couldn't reach the provider. Check your internet connection and try again."
            }
        }
    }

    public let endpoints: Endpoints
    public let transport: any HTTPTransport
    /// Opens the authorization page (the user's browser in the app; a simulated browser in tests).
    public let openBrowser: @Sendable (URL) async -> Void

    public init(endpoints: Endpoints, transport: any HTTPTransport = URLSessionTransport(), openBrowser: @escaping @Sendable (URL) async -> Void) {
        self.endpoints = endpoints; self.transport = transport; self.openBrowser = openBrowser
    }

    /// Runs the whole browser flow and returns the new API key (never logged).
    public func authorize(timeout: TimeInterval = 300) async throws -> String {
        let server = try LoopbackServer()
        defer { server.stop() }
        let redirect = try await server.start(host: "localhost")  // OpenRouter accepts localhost callbacks on any port.
        let pkce = PKCE(), state = Base64URL.random()
        await openBrowser(authorizationURL(redirect: redirect, pkce: pkce, state: state))
        return try await complete(callback: try await server.waitForCallback(timeout: timeout), expectedState: state, pkce: pkce)
    }

    public func authorizationURL(redirect: URL, pkce: PKCE, state: String) -> URL {
        var c = URLComponents(url: endpoints.authURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "callback_url", value: redirect.absoluteString), .init(name: "code_challenge", value: pkce.challenge),
                        .init(name: "code_challenge_method", value: pkce.method), .init(name: "state", value: state),
                        .init(name: "key_label", value: "Offerlane")]
        return c.url!
    }

    /// Checks the redirect, then exchanges the code for a key.
    public func complete(callback q: [String: String], expectedState: String, pkce: PKCE) async throws -> String {
        guard let state = q["state"], constantTimeEquals(state, expectedState) else { throw Failure.stateMismatch }
        if q["error"] != nil { throw Failure.denied }
        guard let code = q["code"], !code.isEmpty else { throw Failure.missingCode }
        var req = URLRequest(url: endpoints.exchangeURL)
        req.httpMethod = "POST"; req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": pkce.verifier, "code_challenge_method": pkce.method])
        let (data, resp): (Data, HTTPURLResponse)
        do { (data, resp) = try await transport.send(req) } catch { throw Failure.network }
        guard resp.statusCode == 200 else { throw Failure.rejected(resp.statusCode) }
        guard let key = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["key"] as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.noKey }
        return key
    }
}
