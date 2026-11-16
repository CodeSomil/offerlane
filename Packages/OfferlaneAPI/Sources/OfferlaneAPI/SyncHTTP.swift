import Foundation
import OpenAPIRuntime

/// `/v1/me` and `/v1/sync/{kind}` for the Mac sync engine (OfferlaneCore `SyncEngine`, P4.4), with the web's rules
/// (apps/web/src/sync.ts httpRemote): each PUT is one logical write with one Idempotency-Key; a network failure retries
/// with the same key (the server replays the first answer), any HTTP answer ends it.
public struct SyncHTTP: Sendable {
    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }
    public enum Put: Sendable, Equatable { case ok(version: Int), conflict }

    let client: Client
    public init(client: Client) { self.client = client }

    static func status(_ code: Int) -> Failure {
        switch code {
        case 401: Failure(message: "Your sign-in has expired. Sign in again to sync.")
        case 413: Failure(message: "This data is too large to sync (over 8 MB).")
        case 429: Failure(message: "Too many sync requests in a short time. Try again in a minute.")
        default: Failure(message: "The sync service answered \(code). Try again later.")
        }
    }
    static let offline = Failure(message: "Couldn't reach the sync service. Check your connection and try again.")
    static let unreadable = Failure(message: "The sync service sent an answer this version can't read. Try again later.")

    func call<T>(tries: Int = 1, _ f: () async throws -> T) async throws -> T {
        for i in 1... {
            do { return try await f() } catch {
                if error is Failure || error is BearerAuthError { throw error }
                // Only a transport failure is "offline" and retried; an answer we can't decode is not.
                guard ((error as? ClientError)?.underlyingError ?? error) is URLError else { throw Self.unreadable }
                if i >= tries { throw Self.offline }
            }
        }
        fatalError("unreachable")
    }

    public func me() async throws -> String {
        switch try await call({ try await client.getMe() }) {
        case .ok(let r): try r.body.json.id
        case .unauthorized: throw Self.status(401)
        case .tooManyRequests: throw Self.status(429)
        case .internalServerError: throw Self.status(500)
        case .undocumented(let code, _): throw Self.status(code)
        }
    }

    public func get(_ kind: String) async throws -> (version: Int, keyId: String, ciphertext: Data)? {
        guard let k = Operations.GetSync.Input.Path.KindPayload(rawValue: kind) else { throw Failure(message: "Unknown sync kind.") }
        switch try await call(tries: 2, { try await client.getSync(path: .init(kind: k)) }) {
        case .ok(let r):
            let b = try r.body.json
            guard let data = Data(base64Encoded: b.ciphertext) else { throw Failure(message: "The sync service sent unreadable data. Try again later.") }
            return (b.version, b.keyId, data)
        case .notFound: return nil
        case .badRequest: throw Self.status(400)
        case .unauthorized: throw Self.status(401)
        case .tooManyRequests: throw Self.status(429)
        case .internalServerError: throw Self.status(500)
        case .undocumented(let code, _): throw Self.status(code)
        }
    }

    /// expected = nil: create only (If-None-Match: *); otherwise If-Match: "v<expected>".
    public func put(_ kind: String, expected: Int?, keyId: String, ciphertext: Data) async throws -> Put {
        guard let k = Operations.PutSync.Input.Path.KindPayload(rawValue: kind) else { throw Failure(message: "Unknown sync kind.") }
        let headers: Operations.PutSync.Input.Headers = expected.map { .init(ifMatch: "\"v\($0)\"", idempotencyKey: UUID().uuidString) }
            ?? .init(ifNoneMatch: .init(rawValue: "*")!, idempotencyKey: UUID().uuidString)
        let body = Operations.PutSync.Input.Body.json(.init(keyId: keyId, ciphertext: ciphertext.base64EncodedString()))
        switch try await call(tries: 3, { try await client.putSync(path: .init(kind: k), headers: headers, body: body) }) {
        case .ok(let r): return .ok(version: try r.body.json.version)
        case .conflict: return .conflict
        case .contentTooLarge: throw Self.status(413)
        case .unauthorized: throw Self.status(401)
        case .tooManyRequests: throw Self.status(429)
        case .badRequest: throw Self.status(400)
        case .unsupportedMediaType: throw Self.status(415)
        case .unprocessableContent: throw Self.status(422)
        case .preconditionRequired: throw Self.status(428)
        case .internalServerError: throw Self.status(500)
        case .undocumented(let code, _): throw Self.status(code)
        }
    }
}
