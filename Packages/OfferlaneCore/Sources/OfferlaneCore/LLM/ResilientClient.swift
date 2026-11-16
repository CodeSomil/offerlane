import Foundation

/// Retries passing failures (rate limit, timeout, outage) with backoff, then hands the request to the next
/// AI the user connected. A bad key, bad JSON or a cancel stops at once: those need the user, not a retry.
public struct ResilientClient: LLMClient {
    public let chain: [any LLMClient]
    let retries: Int
    let sleep: @Sendable (Double) async throws -> Void

    public init(chain: [any LLMClient], retries: Int = 2,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        precondition(!chain.isEmpty)
        self.chain = chain; self.retries = retries; self.sleep = sleep
    }

    public var displayName: String { chain[0].displayName }
    public var billed: Bool { chain.contains(where: \.billed) }
    /// The smallest limit in the chain, so a request still fits after a fallback.
    public var maxRequestTokens: Int? { chain.compactMap(\.maxRequestTokens).min() }

    /// Seconds before retry `attempt` (1-based): the provider's retry-after if given, else 2, 4, 8…; never over a minute.
    static func delay(_ e: LLMError, attempt: Int) -> Double {
        if case .rateLimited(_, let after?) = e { return min(after, 60) }
        return min(pow(2, Double(attempt)), 60)
    }

    public func complete(_ r: LLMRequest) async throws -> LLMResponse {
        var last: LLMError = .notConfigured
        for (i, c) in chain.enumerated() {
            var attempt = 0
            while true {
                try Task.checkCancellation()
                do {
                    var res = try await c.complete(r)
                    if i > 0 { res.source = c.displayName }
                    return res
                } catch let e as LLMError where e.shouldFallBack {
                    last = e
                    guard e.isTransient, attempt < retries else { break }
                    attempt += 1
                    try await sleep(Self.delay(e, attempt: attempt))
                }
            }
            if i + 1 < chain.count { Log.info("llm fallback from \(c.displayName) to \(chain[i + 1].displayName)") }
        }
        throw last
    }
}
