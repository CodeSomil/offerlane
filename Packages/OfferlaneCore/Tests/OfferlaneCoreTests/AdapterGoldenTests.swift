import XCTest
@testable import OfferlaneCore

/// Every ATS parser's full output for the recorded responses, pinned in Fixtures/ats_expected.json.
/// apps/api/test/ats.test.ts checks the TypeScript port against the same file.
/// Regenerate with `OFFERLANE_WRITE_GOLDEN=1 swift test --filter AdapterGoldenTests`.
final class AdapterGoldenTests: XCTestCase {
    func j(_ name: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Fixture.data("ats/\(name).json")) }

    func row(_ p: Posting) -> [String: Any] {
        ["title": p.title, "location": p.location, "url": p.url, "applyUrl": p.applyUrl,
         "posted": p.posted ?? NSNull(), "description": p.description, "detail": p.detail?.absoluteString ?? NSNull()]
    }

    func testParsersMatchGolden() throws {
        // The golden is in UTC (what the server uses); the app formats epoch dates in local time.
        let tz = Dates.isoDay.timeZone
        Dates.isoDay.timeZone = TimeZone(identifier: "UTC")
        defer { Dates.isoDay.timeZone = tz }

        let site = "https://nvidia.wd5.myworkdayjobs.com/en-US/NVIDIAExternalCareerSite"
        let api = try XCTUnwrap(ATS.workdayAPI(site))
        let edge = j("synthetic_edge")
        let out: [String: Any] = [
            "greenhouse_scaleai": ATS.greenhouse(j("greenhouse_scaleai")).map(row),
            "lever_spotify": ATS.lever(j("lever_spotify")).map(row),
            "ashby_perplexity": ATS.ashby(j("ashby_perplexity")).map(row),
            "workable_huggingface": ATS.workable(j("workable_huggingface")).map(row),
            "smartrecruiters_bosch": ATS.smartrecruiters(j("smartrecruiters_bosch"), slug: "BoschGroup").map(row),
            "workday_nvidia": ATS.workday(j("workday_nvidia"), siteURL: site, api: api, now: Dates.day("2026-10-31")!).map(row),
            "workdayAPI": api.absoluteString,
            "synthetic_edge": [
                "greenhouse": ATS.greenhouse(edge["greenhouse"]!).map(row),
                "lever": ATS.lever(edge["lever"]!).map(row),
                "ashby": ATS.ashby(edge["ashby"]!).map(row),
                "smartrecruiters": ATS.smartrecruiters(edge["smartrecruiters"]!, slug: "Edge").map(row),
                "workday": ATS.workday(edge["workday"]!, siteURL: site, api: api, now: Dates.day("2026-10-31")!).map(row),
                "strip": (edge["strip"]?.array ?? []).map { Text.stripHTML($0.string) },
            ] as [String: Any],
            "detailText": ["smartrecruiters_bosch_detail": ATS.detailText(j("smartrecruiters_bosch_detail")),
                           "workday_nvidia_detail": ATS.detailText(j("workday_nvidia_detail"))],
        ]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let got = String(decoding: data, as: UTF8.self) + "\n"
        if ProcessInfo.processInfo.environment["OFFERLANE_WRITE_GOLDEN"] == "1" {
            let dst = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ats_expected.json")
            try got.write(to: dst, atomically: true, encoding: .utf8)
            return
        }
        XCTAssertEqual(got, String(decoding: Fixture.data("ats_expected.json"), as: UTF8.self))
    }

    func testStripHTMLIsLinearOnUnclosedTags() {
        let t = Date()
        XCTAssertEqual(Text.stripHTML(String(repeating: "<", count: 200_000) + "a").count, 200_001)
        XCTAssertLessThan(Date().timeIntervalSince(t), 2, "the old regex took minutes on this")
    }
}
