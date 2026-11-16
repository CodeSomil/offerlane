import XCTest
@testable import OfferlaneCore

final class FirstRunRecommendationTests: XCTestCase {
    private let gb: UInt64 = 1 << 30
    private func mac(_ ram: UInt64, _ chip: SystemCheck.Chip = .appleSilicon, disk: Int64 = 200_000_000_000) -> SystemCheck.Hardware {
        SystemCheck.Hardware(ramBytes: ram, chip: chip, cores: 8, freeDiskBytes: disk, macOSMajor: 26)
    }
    private func ids(_ hw: SystemCheck.Hardware, _ specs: [ProviderSpec]? = nil) throws -> [String] {
        let r = FirstRun.recommend(hw, specs: try specs ?? ProviderRegistry.load())
        XCTAssertEqual(r.count, 3); XCTAssertEqual(Set(r.map(\.providerID)).count, 3)
        XCTAssertFalse(r.contains { $0.reason.isEmpty })
        return r.map(\.providerID)
    }

    func testStrongMacLeadsWithSignInThenLocal() throws {
        XCTAssertEqual(try ids(mac(16 * gb)), ["openrouter", "ollama", "gemini"])
        let r = FirstRun.recommend(mac(16 * gb), specs: try ProviderRegistry.load())
        XCTAssertTrue(r[0].reason.hasPrefix("Sign in, no key to copy."))
        XCTAssertTrue(r[1].reason.contains("16 GB RAM"))
    }

    func testWeakOrIntelOrLowDiskLeadsWithSignInThenFreeKeys() throws {
        XCTAssertEqual(try ids(mac(8 * gb)), ["openrouter", "gemini", "anthropic"])
        XCTAssertEqual(try ids(mac(32 * gb, .intel)), ["openrouter", "gemini", "anthropic"])
        XCTAssertEqual(try ids(mac(16 * gb, disk: 2_000_000_000)), ["openrouter", "gemini", "anthropic"])
    }

    func testOptionsListEveryVisibleProviderOnce() throws {
        let specs = try ProviderRegistry.load()
        let all = FirstRun.options(mac(8 * gb), specs: specs).map(\.providerID)
        XCTAssertEqual(all, ["openrouter", "gemini", "anthropic", "groq", "cloudflare", "ollama", "custom"])
        XCTAssertEqual(Set(all), Set(specs.filter(\.isVisible).map(\.id)))
        XCTAssertEqual(Array(all.prefix(3)), try ids(mac(8 * gb)))
    }

    /// A key pasted on the wrong card is recognised only by a published prefix; formatless providers never claim a key.
    func testKeyOwnerUsesPublishedFormatsOnly() throws {
        let specs = try ProviderRegistry.visible()
        XCTAssertEqual(ProviderSpec.keyOwner("sk-ant-api03-abc", among: specs)?.id, "anthropic")
        XCTAssertEqual(ProviderSpec.keyOwner("cfut_abc123", among: specs)?.id, "cloudflare")
        XCTAssertNil(ProviderSpec.keyOwner("AIzaSyExample", among: specs))
        XCTAssertNil(ProviderSpec.keyOwner("  ", among: specs))
    }

    /// A registry logo must exist in the app's asset catalog (and only brands whose rules allow it have one: docs/PROVIDERS.md).
    func testLogosExistInAssets() throws {
        let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../App/Resources/Assets.xcassets")
        let logos = try ProviderRegistry.load().compactMap(\.logo)
        XCTAssertEqual(logos, ["provider.openrouter"])
        for l in logos { XCTAssertTrue(FileManager.default.fileExists(atPath: assets.appendingPathComponent("\(l).imageset/Contents.json").path), l) }
    }

    func testOnlyVisibleProviders() throws {
        let specs = try ProviderRegistry.load().map { s -> ProviderSpec in
            var s = s; if s.id == "gemini" { s.status = .unverified }; return s
        }
        XCTAssertEqual(try ids(mac(8 * gb), specs), ["openrouter", "anthropic", "groq"])
        XCTAssertFalse(try ids(mac(16 * gb), specs).contains("claude_cli"))
    }
}
