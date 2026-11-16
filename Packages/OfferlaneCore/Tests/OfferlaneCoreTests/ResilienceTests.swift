import XCTest
@testable import OfferlaneCore

/// A client that fails with the queued errors, then answers; counts its calls.
final class ScriptedClient: LLMClient, @unchecked Sendable {
    let displayName: String
    var billed: Bool { false }
    private var errors: [LLMError]
    private(set) var calls = 0
    init(_ name: String, errors: [LLMError] = []) { displayName = name; self.errors = errors }
    func complete(_ r: LLMRequest) async throws -> LLMResponse {
        calls += 1
        if !errors.isEmpty { throw errors.removeFirst() }
        return LLMResponse(text: "{\"ok\":true}", model: displayName)
    }
}

final class ResilienceTests: XCTestCase {
    let noSleep: @Sendable (Double) async throws -> Void = { _ in }
    let limited = LLMError.rateLimited("rate limit", retryAfter: nil)

    func testRateLimitedPrimaryFallsBackToSecondary() async throws {
        let a = ScriptedClient("A", errors: [limited, limited, limited]), b = ScriptedClient("B")
        let res = try await ResilientClient(chain: [a, b], sleep: noSleep).complete(LLMRequest(prompt: "p"))
        XCTAssertEqual(a.calls, 3, "first try plus two retries"); XCTAssertEqual(b.calls, 1)
        XCTAssertEqual(res.source, "B")
    }

    func testRetryRecoversWithoutFallback() async throws {
        let a = ScriptedClient("A", errors: [.http(503, "busy")]), b = ScriptedClient("B")
        let res = try await ResilientClient(chain: [a, b], sleep: noSleep).complete(LLMRequest(prompt: "p"))
        XCTAssertEqual(a.calls, 2); XCTAssertEqual(b.calls, 0); XCTAssertEqual(res.source, "")
    }

    func testBadKeyStopsAtOnce() async {
        let a = ScriptedClient("A", errors: [.notSignedIn("bad key")]), b = ScriptedClient("B")
        do { _ = try await ResilientClient(chain: [a, b], sleep: noSleep).complete(LLMRequest(prompt: "p")); XCTFail() }
        catch { XCTAssertEqual(error as? LLMError, .notSignedIn("bad key")) }
        XCTAssertEqual(a.calls, 1); XCTAssertEqual(b.calls, 0)
    }

    func testUsedUpPlanFallsBackWithoutRetry() async throws {
        let a = ScriptedClient("A", errors: [.usageLimit("x")]), b = ScriptedClient("B")
        _ = try await ResilientClient(chain: [a, b], sleep: noSleep).complete(LLMRequest(prompt: "p"))
        XCTAssertEqual(a.calls, 1); XCTAssertEqual(b.calls, 1)
    }

    func testAllFailThrowsLastCause() async {
        let a = ScriptedClient("A", errors: [.unreachable("off")]), b = ScriptedClient("B", errors: [limited])
        do { _ = try await ResilientClient(chain: [a, b], retries: 0, sleep: noSleep).complete(LLMRequest(prompt: "p")); XCTFail() }
        catch { XCTAssertEqual(error as? LLMError, limited); XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testBackoffHonoursRetryAfterAndCaps() {
        XCTAssertEqual(ResilientClient.delay(.rateLimited("", retryAfter: 7), attempt: 1), 7)
        XCTAssertEqual(ResilientClient.delay(.rateLimited("", retryAfter: 900), attempt: 1), 60)
        XCTAssertEqual(ResilientClient.delay(.timedOut, attempt: 2), 4)
    }

    func testOldSettingsDecodeWithoutFallbacks() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"provider":"ollama","modelSmart":"qwen3.5:9b"}"#.utf8))
        XCTAssertEqual(s.fallbacks, []); XCTAssertEqual(s.connection.modelSmart, "qwen3.5:9b")
        var t = s; t.fallbacks = [.init(provider: .apiKey, providerID: "gemini", modelSmart: "g")]
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(t)), t)
    }

    func testFactoryChainsFallbacksAndSkipsUnbuildable() throws {
        let kc = Keychain(service: "com.somilmanke.Offerlane.tests.\(UUID().uuidString)"); defer { kc.deleteAll() }
        var s = AppSettings(); s.provider = .ollama; s.modelSmart = "qwen3.5:9b"
        s.fallbacks = [.init(provider: .anthropic),                                   // no key saved: skipped
                       .init(provider: .ollama, modelSmart: "qwen3.5:4b")]
        let c = try XCTUnwrap(AIFactory.client(s, keychain: kc) as? ResilientClient)
        XCTAssertEqual(c.chain.map(\.displayName), ["Ollama · qwen3.5:9b", "Ollama · qwen3.5:4b"])
    }

    func testMeterRecordsFallback() async throws {
        let ai = AI(client: ResilientClient(chain: [ScriptedClient("A", errors: [limited]), ScriptedClient("B")], retries: 0, sleep: noSleep), store: nil)
        _ = try await ai.chat(LLMRequest(prompt: "p"))
        XCTAssertEqual(ai.fallbackThisRun, "B"); ai.resetRunCounters(); XCTAssertEqual(ai.fallbackThisRun, "")
    }

    func testChunksFitTheLimit() {
        let jobs = Array(1...25), size = { (p: ArraySlice<Int>) in 100 + 50 * p.count }
        XCTAssertEqual(Ranking.chunks(jobs, limit: nil, size: size).count, 1)
        let parts = Ranking.chunks(jobs, limit: 600, size: size)
        XCTAssertEqual(parts.map(\.count), [10, 10, 5]); XCTAssertEqual(parts.flatMap { $0 }, jobs)
        XCTAssertEqual(Ranking.chunks(jobs, limit: 10, size: size).count, 25, "an item over the limit alone still goes")
        XCTAssertEqual(Ranking.chunks([Int](), limit: 600, size: size).count, 0)
    }

    func testChainUsesSmallestRequestLimit() {
        let a = OllamaClient(modelFast: "m", modelSmart: "m", contextLength: 8192)
        let b = OpenAICompatibleClient(modelFast: "m", modelSmart: "m", maxRequestTokens: 30_000)
        XCTAssertEqual(ResilientClient(chain: [b, a]).maxRequestTokens, 8192)
        XCTAssertNil(ResilientClient(chain: [ScriptedClient("A")]).maxRequestTokens)
    }
}

final class ConnectionsTests: XCTestCase {
    let ollama = AppSettings.Connection(provider: .ollama, modelSmart: "qwen3.5:9b")
    let gemini = AppSettings.Connection(provider: .apiKey, providerID: "gemini", modelSmart: "g")

    func testAddReorderRemove() {
        var s = AppSettings(); s.connection = ollama
        s.addBackup(gemini); s.addBackup(gemini)
        XCTAssertEqual(s.connections, [ollama, gemini], "no duplicate")
        s.connections = [gemini, ollama]
        XCTAssertEqual(s.provider, .apiKey); XCTAssertEqual(s.fallbacks, [ollama])
        XCTAssertEqual(s.removeConnection(at: 0), Keychain.Account.provider("gemini"))
        XCTAssertEqual(s.connections, [ollama])
        XCTAssertNil(s.removeConnection(at: 0), "Ollama has no key")
        XCTAssertEqual(s.provider, .none); XCTAssertEqual(s.connections, [])
    }

    func testSharedKeyIsKeptWhileStillUsed() {
        var s = AppSettings(); s.connection = gemini
        var g2 = gemini; g2.modelSmart = "other"; s.addBackup(g2)
        XCTAssertNil(s.removeConnection(at: 0))
    }

    func testRetestPassesAndReportsBadJSON() async {
        let passed = await ProviderSetup.retest(FakeLLM.prototype)
        XCTAssertNil(passed)
        let bad = await ProviderSetup.retest(FakeLLM(rules: [{ _ in "Sure!" }]))
        XCTAssertTrue(bad?.contains("strict JSON") == true)
    }
}

final class LastReplyTests: XCTestCase {
    func testLastReplyIsKeptInMemoryWithItsSource() async throws {
        let ai = AI(client: FakeLLM(rules: [{ _ in "Sure! {\"ok\": true}" }]), store: nil)
        XCTAssertNil(ai.lastReply)
        _ = try await ai.chat(LLMRequest(prompt: "p"))
        XCTAssertEqual(ai.lastReply?.text, "Sure! {\"ok\": true}"); XCTAssertEqual(ai.lastReply?.from, "Fake AI")
    }
}

final class RegistryRefreshTests: XCTestCase {
    /// The bundled registry with `edit` applied to each provider dictionary, written to a temp file.
    func remote(_ edit: (inout [String: Any]) -> Void) throws -> URL {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(ProviderRegistry.bundledURL))) as? [String: Any])
        var list = try XCTUnwrap(root["providers"] as? [[String: Any]])
        for i in list.indices { edit(&list[i]) }
        list.append(["id": "evil", "name": "Evil", "kind": "key", "status": "verified", "free": true, "openAICompatible": true,
                     "models": [], "limits": "", "steps": [], "privacyNote": "", "pins": []])
        root["providers"] = list
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("providers-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: root).write(to: url); return url
    }

    func testRefreshUpdatesFactsButNeverPinsOrPromotions() throws {
        let bundled = try ProviderRegistry.load(refreshed: nil)
        let url = try remote { p in
            p["limits"] = "NEW LIMITS"; p["status"] = "verified"; p["free"] = true; p["trainsOnData"] = false
            p["baseURL"] = "https://attacker.example/v1"; p["pins"] = [["url": "https://attacker.example/x.zip", "verify": "none"]]
            if p["id"] as? String == "gemini" { p["status"] = "retired"; p["models"] = ["gemini-new"] }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let merged = try ProviderRegistry.load(refreshed: url)
        XCTAssertEqual(merged.map(\.id), bundled.map(\.id), "unknown providers are ignored")
        for (b, m) in zip(bundled, merged) {
            XCTAssertEqual(m.limits, "NEW LIMITS")
            XCTAssertEqual(m.pins, b.pins); XCTAssertEqual(m.baseURL, b.baseURL)
            XCTAssertEqual(m.free, b.free, "free can't be granted remotely")
            XCTAssertEqual(m.trainsOnData, b.trainsOnData, "can't be marked private remotely")
            if b.id != "gemini" { XCTAssertEqual(m.status, b.status, "can't be promoted remotely") }
        }
        let g = try XCTUnwrap(merged.first { $0.id == "gemini" })
        XCTAssertEqual(g.status, .retired); XCTAssertFalse(g.isVisible); XCTAssertEqual(g.models, ["gemini-new"])
    }

    func testBrokenRefreshFallsBackToBundled() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("providers-bad.json")
        try Data("{nope".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try ProviderRegistry.load(refreshed: url), try ProviderRegistry.load(refreshed: nil))
    }

    func testRefreshRefusesPlainHTTP() async {
        do { try await ProviderRegistry.refresh(from: URL(string: "http://example.com/providers.json")!, to: URL(fileURLWithPath: "/dev/null")); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("secure")) }
    }
}
