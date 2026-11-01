import XCTest
@testable import OfferlaneCore

/// Calls the real provider configured on this Mac. Off by default; run with OFFERLANE_LIVE=1.
final class LiveProviderTests: XCTestCase {
    struct OK: Decodable { var ok: Bool }

    func testClaudeCLIJSONRoundTrip() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OFFERLANE_LIVE"] == "1", "set OFFERLANE_LIVE=1")
        let exe = try XCTUnwrap(ClaudeCLIClient.locate(), "claude CLI not found")
        let ai = AI(client: ClaudeCLIClient(executable: exe), store: nil)
        let t0 = Date()
        let r: OK = try await ai.json(LLMRequest(prompt: "Reply with exactly {\"ok\": true}", system: "Reply with JSON only.",
                                                 cache: "Static context block used to check that the system prompt file is read.", maxTokens: 20))
        XCTAssertTrue(r.ok)
        print("LIVE claude-cli latency: \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    }
}

/// Find Jobs against the real public career sites, using an imported v2 search. Opt-in.
final class LiveFindJobsTests: XCTestCase {
    func testFindJobsLive() async throws {
        _ = Fixture.useVendoredTectonic
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OFFERLANE_LIVE"] == "1", "set OFFERLANE_LIVE=1")
        try XCTSkipUnless(Fixture.hasLegacy, "set OFFERLANE_LEGACY_DIR to a previous-version (v2) data folder")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        let store = try Store()
        _ = try LegacyImporter(store: store, destination: dest).run(from: Fixture.legacy)
        // Start from a clean slate of roles so "new" counts are meaningful, keeping declined fingerprints.
        try await store.db.write { try $0.execute(sql: "DELETE FROM job WHERE status != 'declined'") }
        let exe = try XCTUnwrap(ClaudeCLIClient.locate())
        let ai = AI(client: ClaudeCLIClient(executable: exe), store: store)
        let t0 = Date(), log = LockedLog()
        let s = try await FindJobs(store: store, ai: ai).run { log.add($0.message) }
        let secs = Date().timeIntervalSince(t0)
        print("LIVE find: \(String(format: "%.0f", secs))s checked=\(s.discovery.checked) matching=\(s.discovery.matching) new=\(s.discovery.new) "
              + "unreachable=\(s.discovery.unreachable.count) noBoard=\(s.discovery.noBoard.count) scored=\(s.ranking.scored) good=\(s.ranking.good) aiCalls=\(s.aiCalls) errors=\(s.errors)")
        print("LIVE progress tail: " + log.lines.suffix(3).joined(separator: " | "))
        let top = try store.jobs([.found]).filter { $0.llmScore != nil }.sorted { ($0.llmScore ?? 0) > ($1.llmScore ?? 0) }.prefix(5)
        for j in top { print("LIVE top: \(j.llmScore!) \(j.company) — \(j.title) [\(j.location)] \(j.visa) · \(j.llmReason)") }
        XCTAssertGreaterThan(s.discovery.matching, 20)
        XCTAssertEqual(s.aiCalls, 1)
        XCTAssertTrue(s.errors.isEmpty)
    }
}
