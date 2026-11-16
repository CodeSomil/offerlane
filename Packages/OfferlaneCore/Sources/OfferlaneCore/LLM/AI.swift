import Foundation

/// The app's one entry point for model calls: picks the configured client, meters every call, and turns replies
/// into validated JSON (with one cheap repair retry, as the prototype did).
public final class AI: @unchecked Sendable {
    public let client: any LLMClient
    let store: Store?
    private let lock = NSLock()
    private var _callsThisRun = 0
    private var _usdThisRun = 0.0
    private var _tokensThisRun = 0
    private var _cacheHitsThisRun = 0
    private var _fallbackThisRun = ""
    private var _lastReply: (text: String, from: String)?
    /// Most tokens one run (a Find Jobs, one tailored resume) may use; nil = no limit.
    public var budget: Int?

    public init(client: any LLMClient, store: Store?, budget: Int? = nil) { self.client = client; self.store = store; self.budget = budget }

    /// The same client and meter with its own run counters and limit (e.g. one budget per tailored resume).
    public func scoped(budget: Int?) -> AI { AI(client: client, store: store, budget: budget) }

    public var callsThisRun: Int { lock.withLock { _callsThisRun } }
    public var usdThisRun: Double { lock.withLock { _usdThisRun } }
    /// Budget tokens used this run: input + output + cache writes, with cache reads at a tenth (what they cost).
    public var tokensThisRun: Int { lock.withLock { _tokensThisRun } }
    public var cacheHitsThisRun: Int { lock.withLock { _cacheHitsThisRun } }
    /// The fallback AI that answered the last call that needed one this run; empty when the primary handled everything.
    public var fallbackThisRun: String { lock.withLock { _fallbackThisRun } }
    /// The last raw reply and which AI sent it, for the Diagnostics view. Memory only: it can hold resume text, so it's never logged or saved.
    public var lastReply: (text: String, from: String)? { lock.withLock { _lastReply } }
    public func resetRunCounters() { lock.withLock { _callsThisRun = 0; _usdThisRun = 0; _tokensThisRun = 0; _cacheHitsThisRun = 0; _fallbackThisRun = "" } }
    func noteCacheHit(_ n: Int = 1) { lock.withLock { _cacheHitsThisRun += n } }

    /// Rough size of a request before it's sent (about 4 characters per token, plus the reply allowance).
    public static func estimate(_ r: LLMRequest) -> Int { (r.prompt.count + r.system.count + r.cache.count) / 4 + r.maxTokens }

    public func chat(_ r: LLMRequest) async throws -> String {
        try Task.checkCancellation()
        if let budget {
            let used = tokensThisRun, next = Self.estimate(r)
            if used + next > budget { throw LLMError.budget(used: used, limit: budget) }
        }
        let res = try await client.complete(r)
        let u = res.usage
        let spent = u.input + u.output + u.cacheWrite + u.cacheRead / 10
        let counted = spent > 0 ? spent : Self.estimate(r)   // the CLI and some local models don't report usage
        lock.withLock { _callsThisRun += 1; _usdThisRun += res.usd; _tokensThisRun += counted; if !res.source.isEmpty { _fallbackThisRun = res.source }
                        _lastReply = (res.text, res.source.isEmpty ? client.displayName : res.source) }
        try? store?.meter(input: res.usage.input + res.usage.cacheWrite, output: res.usage.output, cached: res.usage.cacheRead, usd: res.usd)
        Log.info("llm \(client.displayName) in=\(res.usage.input) out=\(res.usage.output) cached=\(res.usage.cacheRead)")
        return res.text
    }

    /// `json`, but answered from the local cache when the exact same question was asked before.
    /// `key` must cover everything that changes the answer (content hashes, model, prompt version).
    /// The reply text is cached, so any Decodable type works.
    public func cachedJSON<T: Decodable>(_ r: LLMRequest, key: String, kind: String, as type: T.Type = T.self) async throws -> T {
        if let data = try? store?.cached(key), let v = try? Self.decode(String(decoding: data, as: UTF8.self), as: T.self) { noteCacheHit(); return v }
        let (v, text): (T, String) = try await jsonWithText(r)
        try? store?.cache(key, kind: kind, value: Data(text.utf8))
        return v
    }

    /// A stable key for `cachedJSON`: SHA-256 over the parts, plus the model in use.
    public func cacheKey(_ kind: String, _ parts: [String], smart: Bool = false) -> String {
        Hash.sha256(([kind, client.displayName, smart ? "smart" : "fast"] + parts).joined(separator: "\u{1F}"))
    }

    /// Ask for JSON and decode it as `T`. On a parse/decode failure, ask once more with a stricter instruction.
    public func json<T: Decodable>(_ r: LLMRequest, as type: T.Type = T.self) async throws -> T { try await jsonWithText(r).0 }

    /// The repair retry sends only the broken reply (not the whole original prompt again), on the fast model.
    func jsonWithText<T: Decodable>(_ r: LLMRequest) async throws -> (T, String) {
        let first = try await chat(r)
        if let v = try? Self.decode(first, as: T.self) { return (v, first) }
        Log.info("JSON repair retry")
        let repair = LLMRequest(prompt: Self.repairPrompt + String(first.prefix(24_000)), system: r.system, smart: false,
                                maxTokens: min(r.maxTokens, max(400, first.count / 3 + 200)))
        let second = try await chat(repair)
        do { return (try Self.decode(second, as: T.self), second) } catch { throw LLMError.badJSON(second) }
    }

    static let repairPrompt = "Fix this into valid JSON. Keep every value; drop any prose or code fences. Reply with the JSON only.\n\n"

    /// Strips code fences, then tries the whole text, the outermost {...}, and the outermost [...].
    public static func decode<T: Decodable>(_ text: String, as: T.Type) throws -> T {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        t = Re.sub("^```(?:json)?|```$", "", t, [.anchorsMatchLines]).trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [t]
        if let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"), a < b { candidates.append(String(t[a...b])) }
        // Reasoning before the answer may contain braces itself: also try each later "{" up to the last "}".
        if let b = t.lastIndex(of: "}") {
            candidates += t.indices.filter { t[$0] == "{" }.dropFirst().prefix(20).filter { $0 < b }.map { String(t[$0...b]) }
        }
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
