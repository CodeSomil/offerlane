import XCTest
@testable import OfferlaneCore

/// D6: curated OpenRouter picks, the privacy block on every request, live prices with a 24 h cache.
final class OpenRouterTests: XCTestCase {
    private func body(_ c: OpenAICompatibleClient, smart: Bool = true) throws -> [String: Any] {
        let req = try c.request(LLMRequest(prompt: "p", smart: smart))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
    }

    func testEveryOpenRouterRequestCarriesPrivacyBlock() throws {
        // Any route to openrouter.ai gets the block: registry adapter, settings factory, or a custom endpoint typed by hand.
        for base in ["https://openrouter.ai/api/v1", "https://OpenRouter.ai/api/v1/", "https://eu.openrouter.ai/api/v1"] {
            let c = OpenAICompatibleClient(baseURL: URL(string: base)!, modelFast: "a/fast", modelSmart: "a/smart", apiKey: "k", name: "x")
            for smart in [true, false] {
                let p = try XCTUnwrap(try body(c, smart: smart)["provider"] as? [String: Any], base)
                XCTAssertEqual(p["data_collection"] as? String, "deny")
                XCTAssertEqual(p["zdr"] as? Bool, true)
                XCTAssertEqual(p["require_parameters"] as? Bool, true)
            }
        }
        XCTAssertTrue(OpenAICompatibleClient.isOpenRouter(URL(string: "https://openrouter.ai./api/v1")!))
        let other = OpenAICompatibleClient(baseURL: URL(string: "https://openrouter.ai.evil.example/v1")!, modelFast: "m", modelSmart: "m")
        XCTAssertNil(try body(other)["provider"], "only OpenRouter's own hosts get the OpenRouter block")
    }

    func testFreeModelsRefusedForOpenRouter() {
        let c = OpenAICompatibleClient(baseURL: URL(string: "https://openrouter.ai/api/v1")!, modelFast: "x/m:free", modelSmart: "a/paid", apiKey: "k")
        XCTAssertThrowsError(try c.request(LLMRequest(prompt: "p", smart: false)))
        XCTAssertNoThrow(try c.request(LLMRequest(prompt: "p", smart: true)))
    }

    func testBundledPicksAreThreeTiersAndRemoteCannotQualify() throws {
        let or = try XCTUnwrap(ProviderRegistry.load(refreshed: nil).first { $0.id == "openrouter" })
        XCTAssertEqual(or.picks?.map(\.tier), [.recommended, .cheaper, .advanced])
        XCTAssertTrue(or.picks?.allSatisfy { !$0.id.hasSuffix(":free") && !($0.fast ?? "").hasSuffix(":free") && !$0.privacy.isEmpty } ?? false)
        var remote = or; remote.picks = or.picks?.map { var p = $0; p.qualified = true; return p }
        remote.picks?.append(.init(id: "evil/model", tier: .recommended, qualified: true, use: "x", privacy: "x"))
        XCTAssertEqual(ProviderRegistry.merge([or], [remote])[0].picks, or.picks, "picks and qualification stay bundled")
    }

    func testCatalogPricesAndCache() async throws {
        let base = URL(string: "https://openrouter.ai/api/v1")!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("openrouter-models.json")
        MockReleaseServer.reset()
        MockReleaseServer.route(base.appendingPathComponent("models").absoluteString, .file(Data(#"""
        {"data":[{"id":"b/paid","pricing":{"prompt":"0.000003","completion":"0.000015"}},{"id":"a/m:free","pricing":{"prompt":"0","completion":"0"}},
                 {"id":"c/odd","pricing":{"prompt":"n/a"}},{"id":"d/none"}]}
        """#.utf8)))
        let s = URLSession(configuration: MockReleaseServer.config())
        let now = Date()
        let list = await OpenRouterCatalog.models(baseURL: base, cache: cache, now: now, session: s)
        XCTAssertEqual(list.map(\.id), ["b/paid", "c/odd", "d/none"], ":free models never listed")
        XCTAssertEqual(list[0].priceText, "$3.00 in · $15.00 out per million tokens")
        XCTAssertEqual(list[1].priceText, "price unavailable")
        XCTAssertEqual(list[2].priceText, "price unavailable")

        MockReleaseServer.reset() // server gone: a fresh cache still answers, an old one doesn't
        let cached = await OpenRouterCatalog.models(baseURL: base, cache: cache, now: now.addingTimeInterval(23 * 3600), session: s)
        XCTAssertEqual(cached, list)
        let stale = await OpenRouterCatalog.models(baseURL: base, cache: cache, now: now.addingTimeInterval(25 * 3600), session: s)
        XCTAssertEqual(stale, [])
    }
}
