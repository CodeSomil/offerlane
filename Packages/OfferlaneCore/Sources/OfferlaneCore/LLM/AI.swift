import Foundation

/// The app's one entry point for model calls: picks the configured client, meters every call, and turns replies
/// into validated JSON (with one cheap repair retry, as the prototype did).
public final class AI: @unchecked Sendable {
    public let client: any LLMClient
    let store: Store?
    private let lock = NSLock()
    private var _callsThisRun = 0
    private var _usdThisRun = 0.0

    public init(client: any LLMClient, store: Store?) { self.client = client; self.store = store }

    public var callsThisRun: Int { lock.withLock { _callsThisRun } }
    public var usdThisRun: Double { lock.withLock { _usdThisRun } }
    public func resetRunCounters() { lock.withLock { _callsThisRun = 0; _usdThisRun = 0 } }

    public func chat(_ r: LLMRequest) async throws -> String {
        try Task.checkCancellation()
        let res = try await client.complete(r)
        lock.withLock { _callsThisRun += 1; _usdThisRun += res.usd }
        try? store?.meter(input: res.usage.input + res.usage.cacheWrite, output: res.usage.output, cached: res.usage.cacheRead, usd: res.usd)
        Log.info("llm \(client.displayName) in=\(res.usage.input) out=\(res.usage.output) cached=\(res.usage.cacheRead)")
        return res.text
    }

    /// Ask for JSON and decode it as `T`. On a parse/decode failure, ask once more with a stricter instruction.
    public func json<T: Decodable>(_ r: LLMRequest, as type: T.Type = T.self) async throws -> T {
        let first = try await chat(r)
        if let v = try? Self.decode(first, as: T.self) { return v }
        Log.info("JSON repair retry")
        var again = r; again.prompt += "\n\nReturn ONLY valid JSON matching the schema, no prose."
        let second = try await chat(again)
        do { return try Self.decode(second, as: T.self) } catch { throw LLMError.badJSON(second) }
    }

    /// Strips code fences, then tries the whole text, the outermost {...}, and the outermost [...].
    public static func decode<T: Decodable>(_ text: String, as: T.Type) throws -> T {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        t = Re.sub("^```(?:json)?|```$", "", t, [.anchorsMatchLines]).trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [t]
        if let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"), a < b { candidates.append(String(t[a...b])) }
        if let a = t.firstIndex(of: "["), let b = t.lastIndex(of: "]"), a < b { candidates.append(String(t[a...b])) }
        var lastError: Error = LLMError.badJSON(text)
        for c in candidates {
            do { return try JSONCoding.decoder.decode(T.self, from: Data(c.utf8)) } catch { lastError = error }
        }
        throw lastError
    }
}

extension NSLock {
    func withLock<T>(_ f: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try f() }
}
