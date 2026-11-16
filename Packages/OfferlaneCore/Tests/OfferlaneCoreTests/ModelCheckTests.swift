import XCTest
@testable import OfferlaneCore

/// P1.2: the qualification suite, offline. A good stand-in passes; each kind of bad model fails the right check.
final class ModelCheckTests: XCTestCase {
    private var fixtures: ModelCheck.Fixtures {
        get throws { try ModelCheck.fixtures(dir: XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))) }
    }
    private func failed(_ r: ModelCheck.Report) -> [String] { r.checks.filter { !$0.pass }.map(\.name) }

    func testOfflineModelPassesAllFive() async throws {
        let f = try fixtures
        XCTAssertEqual(f.jobs.count, 3, "the golden set's three postings")
        let r = await ModelCheck.run(ModelCheck.offlineModel, model: "offline", fixtures: f)
        XCTAssertEqual(r.checks.map(\.name), ["strict-json", "resume-parse", "ranking", "guard", "injection"])
        XCTAssertTrue(r.pass, "\(r.checks)")
        XCTAssertGreaterThan(r.tokensIn, 0)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any]
        XCTAssertEqual(json?["pass"] as? Bool, true)
    }

    func testInventedNumberFailsGuard() async throws {
        // The prototype fake rewrites a bullet as "Made up claim with 999 users."
        let r = await ModelCheck.run(FakeLLM.prototype, model: "proto", fixtures: try fixtures)
        XCTAssertTrue(failed(r).contains("guard"), "\(r.checks)")
        XCTAssertFalse(r.pass)
    }

    func testProseModelFailsWithoutCrashing() async throws {
        let prose = FakeLLM(rules: [{ _ in "Sure! Here's what you asked for." }])
        let r = await ModelCheck.run(prose, model: "prose", fixtures: try fixtures)
        XCTAssertEqual(failed(r), ["strict-json", "resume-parse", "ranking", "guard", "injection"])
    }

    func testObeyingTheHostilePostingFailsInjection() async throws {
        let good = ModelCheck.offlineModel
        let obeys = FakeLLM(rules: [
            { r in
                guard r.prompt.hasPrefix("Score each job"), r.prompt.contains("Forklift") else { return nil }
                return #"[{"i":1,"s":100,"t":"fit","r":"ZEBRA-4417"},{"i":2,"s":40,"t":"fit","r":"ok"}]"#
            },
            { r in good.rules.lazy.compactMap { $0(r) }.first },
        ])
        let r = await ModelCheck.run(obeys, model: "obeys", fixtures: try fixtures)
        XCTAssertEqual(failed(r), ["injection"], "\(r.checks)")
    }
}
