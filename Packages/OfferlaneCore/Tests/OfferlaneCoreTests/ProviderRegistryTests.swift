import XCTest
@testable import OfferlaneCore

/// Schema checks for the bundled provider registry (Resources/providers.json, see docs/PROVIDERS.md).
final class ProviderRegistryTests: XCTestCase {
    private func providers() throws -> [[String: Any]] {
        let url = try XCTUnwrap(ProviderRegistry.bundledURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 1)
        XCTAssertNotNil(root["checkedAt"] as? String)
        return try XCTUnwrap(root["providers"] as? [[String: Any]])
    }

    func testSchema() throws {
        let list = try providers()
        let ids = list.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids.count, list.count)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate provider id")
        for p in list {
            let id = p["id"] as! String
            let status = try XCTUnwrap(p["status"] as? String, id)
            XCTAssertTrue(["verified", "unverified", "retired", "dropped"].contains(status), id)
            XCTAssertTrue(["cli", "key", "local"].contains(p["kind"] as? String ?? ""), id)
            if status == "verified" {
                XCTAssertFalse((p["privacyNote"] as? String ?? "").isEmpty, "\(id) needs a privacy note")
                XCTAssertFalse((p["steps"] as? [String] ?? []).isEmpty, "\(id) needs steps")
            } else {
                XCTAssertFalse((p["statusReason"] as? String ?? "").isEmpty, "\(id) must say why it is hidden")
            }
            if let pattern = p["keyFormat"] as? String {
                XCTAssertNoThrow(try NSRegularExpression(pattern: pattern), id)
            }
            var urls = (p["docs"] as? [String] ?? []) + [p["keyPageURL"] as? String].compactMap { $0 }
            if p["kind"] as? String != "local", let base = p["baseURL"] as? String { urls.append(base) }
            for s in urls {
                XCTAssertEqual(URL(string: s.replacingOccurrences(of: "{account_id}", with: "x"))?.scheme, "https", "\(id): \(s)")
            }
        }
    }

    /// Installers may only come from official hosts, and the Claude pin must match the installer's.
    func testPinsAreOfficial() throws {
        let allowed = ["downloads.claude.ai", "api.github.com"]
        for p in try providers() {
            for pin in p["pins"] as? [[String: Any]] ?? [] {
                let url = try XCTUnwrap(URL(string: pin["url"] as? String ?? ""))
                XCTAssertEqual(url.scheme, "https")
                XCTAssertTrue(allowed.contains(url.host ?? ""), "unpinned host \(url)")
                XCTAssertFalse((pin["verify"] as? String ?? "").isEmpty)
            }
        }
        let claude = try XCTUnwrap(try providers().first { $0["id"] as? String == "claude_cli" })
        let pin = try XCTUnwrap((claude["pins"] as? [[String: Any]])?.first?["url"] as? String)
        XCTAssertEqual(pin, ClaudeSetup.releasesURL.absoluteString)
        let ollama = try XCTUnwrap(try ProviderRegistry.load().first { $0.id == "ollama" })
        XCTAssertEqual(ollama.pins.map(\.url), [OllamaSetup.latestReleaseAPI])
        XCTAssertEqual(ollama.models, OllamaSetup.choices.map(\.name))
    }

    /// The typed model decodes every entry, and only verified providers are offered.
    func testTypedLoadAndVisibility() throws {
        let all = try ProviderRegistry.load()
        XCTAssertEqual(all.count, try providers().count)
        let visible = try ProviderRegistry.visible()
        XCTAssertFalse(visible.isEmpty)
        XCTAssertTrue(visible.allSatisfy { $0.status == .verified })
        XCTAssertEqual(visible.filter { $0.privacyNote.isEmpty }.map(\.id), [], "every offered AI says what it does with resume text")
        XCTAssertFalse(visible.contains { $0.id == "github_models" || $0.id == "claude_cli" })
        let cf = try XCTUnwrap(all.first { $0.id == "cloudflare" })
        XCTAssertTrue(cf.keyLooksValid("cfut_abc")); XCTAssertFalse(cf.keyLooksValid("abc")); XCTAssertFalse(cf.keyLooksValid("  "))
        let ollama = try XCTUnwrap(all.first { $0.id == "ollama" })
        XCTAssertTrue(ollama.isPinned(OllamaSetup.latestReleaseAPI))
        XCTAssertFalse(ollama.isPinned(URL(string: "https://evil.example/Ollama.dmg")!))
    }
}
