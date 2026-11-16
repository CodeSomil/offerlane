import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// The generated client (`Client`, `Operations`, `Components`) comes from openapi.json at build time; nothing here is hand-written API.
/// The bearer token goes in through a middleware so callers can't forget it. No app wiring yet (P2.8).
public struct BearerAuth: ClientMiddleware {
    let token: @Sendable () async throws -> String
    public init(token: @escaping @Sendable () async throws -> String) { self.token = token }
    public func intercept(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
                          next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)) async throws -> (HTTPResponse, HTTPBody?) {
        // Never over cleartext (localhost is fine for dev), and not on the unauthenticated probes.
        let local = ["localhost", "127.0.0.1", "::1"].contains(baseURL.host() ?? "")
        guard baseURL.scheme?.lowercased() == "https" || local else { throw BearerAuthError.insecureServer }
        guard !["health", "ready"].contains(operationID) else { return try await next(request, body, baseURL) }
        var request = request
        request.headerFields[.authorization] = "Bearer \(try await token())"
        return try await next(request, body, baseURL)
    }
}

public enum BearerAuthError: Error { case insecureServer }

/// The generator URI-encodes header parameters, so `If-Match: "v2"` would go out as `%22v2%22` (a 400).
/// This puts the spec's request headers back to their literal values; the generator encodes every one, so decoding is exact.
public struct LiteralHeaders: ClientMiddleware {
    static let names = ["if-match", "if-none-match", "idempotency-key"].compactMap { HTTPField.Name($0) }
    public init() {}
    public func intercept(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
                          next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        for name in Self.names {
            if let v = request.headerFields[name] { request.headerFields[name] = v.removingPercentEncoding ?? v }
        }
        return try await next(request, body, baseURL)
    }
}

public extension Client {
    /// A client for `serverURL` (URLSession by default), sending the token from `token` on every call.
    static func offerlane(serverURL: URL, transport: any ClientTransport = URLSessionTransport(),
                          token: @escaping @Sendable () async throws -> String) -> Client {
        Client(serverURL: serverURL, transport: transport, middlewares: [LiteralHeaders(), BearerAuth(token: token)])
    }
}
