import XCTest
@testable import OfferlaneCore

final class ProviderAdapterTests: XCTestCase {
    let kc = Keychain(service: "com.somilmanke.Offerlane.tests")
    override func tearDown() { kc.deleteAll() }
    let gib: UInt64 = 1 << 30
    func mac(ram: UInt64) -> SystemCheck.Hardware { .init(ramBytes: ram, chip: .appleSilicon, cores: 8, freeDiskBytes: 100 << 30, macOSMajor: 26) }

    func run(_ a: some ProviderAdapter, secret: String? = "fk-good", approve: Bool = true, ram: UInt64 = 16 << 30)
        async -> (Result<ProviderConfig, SetupFailure>, [SetupStep]) {
        let steps = Box<[SetupStep]>([])
        let r = await ProviderSetup(a, keychain: kc, hardware: mac(ram: ram)).run(secret: secret, approve: { _ in approve },
                                                                                  progress: { s in steps.value.append(s) })
        return (r, steps.value)
    }

    /// Contract every adapter must meet: all eight steps in order, a config for its own id, the key saved only in the keychain.
    func assertContract(_ a: some ProviderAdapter, secret: String?, file: StaticString = #filePath, line: UInt = #line) async throws {
        let (r, steps) = await run(a, secret: secret)
        XCTAssertEqual(steps, SetupStep.allCases, file: file, line: line)
        let config = try r.get()
        XCTAssertEqual(config.providerID, a.spec.id, file: file, line: line)
        XCTAssertFalse(config.model.isEmpty, file: file, line: line)
        if let secret, a.spec.kind == .key {
            XCTAssertEqual(kc.get(account: Keychain.Account.provider(a.spec.id)), secret, file: file, line: line)
            XCTAssertFalse(String(describing: config).contains(secret), file: file, line: line)
        }
    }

    func testFakePassesContract() async throws {
        try await assertContract(FakeProviderAdapter(), secret: "fk-good")
        try await assertContract(FakeProviderAdapter(installed: true), secret: "fk-good")
    }

    func testDeclinedConsentStopsBeforeInstall() async {
        let (r, steps) = await run(FakeProviderAdapter(), approve: false)
        XCTAssertEqual(steps, [.detect, .recommend, .consent])
        guard case .failure(let f) = r else { return XCTFail("expected failure") }
        XCTAssertEqual(f.step, .consent); XCTAssertFalse(f.fix.isEmpty)
    }

    func testUnpinnedDownloadIsRefused() async {
        let (r, steps) = await run(FakeProviderAdapter(download: URL(string: "https://evil.example/Fake.dmg")!))
        XCTAssertEqual(steps.last, .install)
        guard case .failure(let f) = r else { return XCTFail("expected failure") }
        XCTAssertEqual(f.step, .install); XCTAssertTrue(f.cause.contains("isn't one Offerlane trusts"))
    }

    func testRecommendationFollowsRAM() async throws {
        let small = try await run(FakeProviderAdapter(), ram: 8 * gib).0.get(), large = try await run(FakeProviderAdapter(), ram: 16 * gib).0.get()
        XCTAssertEqual(small.model, "fake-small"); XCTAssertEqual(large.model, "fake-large")
    }

    func testBadKeyFormatIsRejectedAndNotSaved() async {
        let (r, _) = await run(FakeProviderAdapter(installed: true), secret: "wrong-key")
        guard case .failure(let f) = r else { return XCTFail("expected failure") }
        XCTAssertEqual(f.step, .authenticate)
        XCTAssertNil(kc.get(account: Keychain.Account.provider("fake")))
    }

    func testKeyNeverInFailureText() async {
        let key = "fk-SECRET-123456"
        let (r, _) = await run(FakeProviderAdapter(installed: true, authError: "invalid api key \(key)"), secret: key)
        guard case .failure(let f) = r else { return XCTFail("expected failure") }
        XCTAssertEqual(f.step, .authenticate)
        XCTAssertFalse(f.cause.contains(key)); XCTAssertFalse(f.errorDescription!.contains(key)); XCTAssertTrue(f.cause.contains("<key>"))
        XCTAssertNil(kc.get(account: Keychain.Account.provider("fake")))
    }

    func testStrictJSONTest() async throws {
        // Fenced or prefaced JSON still passes (same recovery as real calls); prose or ok:false fails at the test step.
        try await assertContract(FakeProviderAdapter(installed: true, reply: "Sure!\n```json\n{\"ok\": true}\n```"), secret: "fk-good")
        for bad in ["I can't do that.", "{\"ok\": false}", "{\"ok\": tr"] {
            let (r, _) = await run(FakeProviderAdapter(installed: true, reply: bad))
            guard case .failure(let f) = r else { XCTFail(bad); continue }
            XCTAssertEqual(f.step, .test, bad)
        }
    }
}

/// The key-provider adapter against a fake OpenAI-compatible server (offline).
extension ProviderAdapterTests {
    private func spec(_ id: String) throws -> ProviderSpec { try XCTUnwrap(ProviderRegistry.load().first { $0.id == id }) }
    private func chat(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text]]], "usage": ["prompt_tokens": 1]])
    }
    /// A Gemini adapter whose requests go to the mock server, with `route` as the chat reply.
    private func gemini(_ route: MockReleaseServer.Route) throws -> KeyProviderAdapter {
        let s = try spec("gemini")
        MockReleaseServer.route(s.baseURL! + "chat/completions", route)
        return KeyProviderAdapter(spec: s, session: URLSession(configuration: MockReleaseServer.config()))
    }

    func testVisibleKeyProvidersAreSupported() throws {
        let ids = try ProviderRegistry.visible().filter(KeyProviderAdapter.supports).map(\.id)
        XCTAssertEqual(Set(ids), ["gemini", "openrouter", "cloudflare", "groq", "custom"])
    }

    func testKeyAdapterPassesContract() async throws {
        try await assertContract(gemini(.file(chat("```json\n{\"ok\": true}\n```"))), secret: "AIza-good-key")
    }

    func testKeyAdapterFailuresSayCauseAndFix() async throws {
        let key = "AIza-SECRET-999"
        for (route, words) in [(MockReleaseServer.Route.status(401), "refused the API key"), (.status(429), "rate limit"),
                               (.file(Data("x".utf8), dropAfter: 0), "internet connection"), (.file(Data()), "couldn't read"), (.file(chat("Sure! Here you go.")), "strict JSON")] {
            let (r, _) = await run(try gemini(route), secret: key)
            guard case .failure(let f) = r else { XCTFail(words); continue }
            XCTAssertEqual(f.step, .test, words)
            XCTAssertTrue(f.cause.contains(words), f.cause); XCTAssertFalse(f.fix.isEmpty)
            XCTAssertFalse(f.cause.contains(key) || f.fix.contains(key))
            XCTAssertNil(kc.get(account: Keychain.Account.provider("gemini")))
        }
    }

    func testTestPromptIsTailoringSized() {
        XCTAssertGreaterThan(AI.estimate(ProviderSetup.testPrompt), 3_000)
    }

    func testAccountIDAndCustomURL() async throws {
        let cf = try spec("cloudflare")
        XCTAssertNil(KeyProviderAdapter(spec: cf).baseURL)
        XCTAssertNil(KeyProviderAdapter(spec: cf, accountID: "abc/../x").baseURL)
        XCTAssertEqual(KeyProviderAdapter(spec: cf, accountID: "0a1b2c").baseURL?.absoluteString,
                       "https://api.cloudflare.com/client/v4/accounts/0a1b2c/ai/v1")
        let (r, _) = await run(KeyProviderAdapter(spec: cf), secret: "cfut_x")
        guard case .failure(let f) = r else { return XCTFail("expected failure") }
        XCTAssertEqual(f.step, .configure); XCTAssertTrue(f.cause.contains("account ID"))

        let custom = try spec("custom")
        XCTAssertNil(KeyProviderAdapter(spec: custom, customBaseURL: "file:///etc").baseURL)
        XCTAssertEqual(KeyProviderAdapter(spec: custom, customBaseURL: " https://llm.example/v1 ").baseURL?.host, "llm.example")
        XCTAssertEqual(KeyProviderAdapter(spec: custom, model: "m1").recommend(mac(ram: gib)), ["m1"])
    }

    func testSavedFreeOpenRouterModelCountsAsNotConnected() throws {
        var s = AppSettings(); s.provider = .apiKey; s.providerID = "openrouter"; s.baseUrl = "https://openrouter.ai/api/v1"
        s.modelSmart = "meta/llama:free"; s.modelFast = s.modelSmart
        try kc.set("sk-or-test", account: Keychain.Account.provider("openrouter"))
        defer { kc.delete(account: Keychain.Account.provider("openrouter")) }
        XCTAssertNil(AIFactory.client(s, keychain: kc), "a v3 free pick goes back to AI setup instead of failing every call")
        s.modelSmart = "anthropic/paid"; s.modelFast = "anthropic/paid"
        XCTAssertNotNil(AIFactory.client(s, keychain: kc))
    }

    func testFactoryBuildsKeyProviderFromSettings() throws {
        var s = AppSettings(); s.provider = .apiKey; s.providerID = "gemini"; s.modelSmart = "gemini-3.8-flash"
        s.baseUrl = try spec("gemini").baseURL!
        XCTAssertNil(AIFactory.client(s, keychain: kc), "no key saved yet")
        try kc.set("AIza-k", account: Keychain.Account.provider("gemini"))
        XCTAssertEqual(AIFactory.client(s, keychain: kc)?.displayName, "Google Gemini API · gemini-3.8-flash")
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.provider, .apiKey); XCTAssertEqual(back.providerID, "gemini")
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"provider":"ollama"}"#.utf8)).providerID, "")
    }
}

/// The Ollama adapter against a fake local Ollama (offline): nothing is installed or launched for real.
extension ProviderAdapterTests {
    private func ollama(models: [String], installed: Bool = true, installs: Box<Int> = Box(0)) throws -> OllamaAdapter {
        MockReleaseServer.reset()
        let base = "http://ollama.test/"
        let tags = try JSONSerialization.data(withJSONObject: ["models": models.map { ["name": $0] }])
        MockReleaseServer.route(base + "api/version", .file(Data("{}".utf8)))
        MockReleaseServer.route(base + "api/tags", .file(tags))
        MockReleaseServer.route(base + "api/pull", .file(Data("{\"status\":\"success\"}\n".utf8)))
        MockReleaseServer.route(base + "api/chat", .file(Data(#"{"message":{"content":"{\"ok\": true}"}}"#.utf8)))
        let spec = try XCTUnwrap(ProviderRegistry.load().first { $0.id == "ollama" })
        return OllamaAdapter(spec: spec, setup: OllamaSetup(baseURL: URL(string: base)!, session: URLSession(configuration: MockReleaseServer.config())),
                             isInstalled: { installed }, installApp: { installs.value += 1 })
    }

    func testOllamaAdapterPassesContract() async throws {
        defer { MockReleaseServer.reset() }
        try await assertContract(ollama(models: ["qwen3.5:9b"]), secret: nil)
        XCTAssertTrue(MockReleaseServer.requests.contains { $0.url.hasSuffix("api/chat") })
        XCTAssertFalse(MockReleaseServer.requests.contains { $0.url.hasSuffix("api/pull") }, "model already present")
    }

    func testOllamaAdapterPullsAMissingModelAndPicksByRAM() async throws {
        defer { MockReleaseServer.reset() }
        let a = try ollama(models: [])
        XCTAssertEqual(a.recommend(mac(ram: 8 * gib)), ["qwen3.5:4b"])
        XCTAssertEqual(a.recommend(mac(ram: 16 * gib)), ["qwen3.5:9b"])
        // The pull "succeeds" but the fake tags list stays empty, so authenticate reports the missing model.
        let (r, steps) = await run(a, secret: nil)
        XCTAssertTrue(MockReleaseServer.requests.contains { $0.url.hasSuffix("api/pull") })
        XCTAssertEqual(steps.last, .authenticate)
        guard case .failure(let f) = r else { return XCTFail("expected failure") }
        XCTAssertTrue(f.cause.contains("doesn't have qwen3.5:9b"))
    }

    func testOllamaInstallNeedsConsentAndAPinnedURL() async throws {
        defer { MockReleaseServer.reset() }
        for approve in [false, true] {
            let installs = Box(0)
            var a = try ollama(models: ["qwen3.5:9b"], installed: false)
            MockReleaseServer.route("http://ollama.test/api/version", .status(404))   // not installed, not running
            a = OllamaAdapter(spec: a.spec, setup: a.setup, isInstalled: { false }, installApp: {
                installs.value += 1
                MockReleaseServer.route("http://ollama.test/api/version", .file(Data("{}".utf8)))   // the real install starts Ollama
            })
            XCTAssertTrue(a.spec.isPinned(try XCTUnwrap(a.consent()).from))
            let (r, steps) = await run(a, secret: nil, approve: approve)
            XCTAssertEqual(installs.value, approve ? 1 : 0)
            if approve { XCTAssertEqual(steps, SetupStep.allCases); _ = try r.get() } else { XCTAssertEqual(steps.last, .consent) }
        }
    }
}
