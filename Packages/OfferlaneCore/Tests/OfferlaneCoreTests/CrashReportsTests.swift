import XCTest
@testable import OfferlaneCore

final class CrashReportsTests: XCTestCase {
    /// Strings planted all over a synthetic macOS crash file; none may reach the report.
    let planted = [
        "Jane Q Applicant", "jane.applicant@example.com", "+1 415 555 0134", "/Users/janeq", "janeq",
        "sk-ant-api03-AbCdEfPLANTEDsecretPLANTEDsecret0123456789", "ya29.PLANTEDoauthTOKEN0123456789abcdef",
        "Led a team of 12 engineers at Initech", "Senior Widget Engineer at Globex", "Your application to Globex",
        "Initech", "Globex", "hunter2-password",
    ]

    func ips(appName: String = "Offerlane") -> String {
        let header = #"{"app_name":"\#(appName)","app_version":"0.3.0","build_version":"3","bug_type":"309","os_version":"macOS 26.1 (25B78)","incident_id":"ABC","name":"\#(appName)"}"#
        let body: [String: Any] = [
            "procPath": "/Users/janeq/Applications/Offerlane.app/Contents/MacOS/Offerlane",
            "cpuType": "ARM-64",
            "exception": ["type": "EXC_BREAKPOINT", "signal": "SIGTRAP", "codes": "0x1"],
            "asi": ["libswiftCore.dylib": ["Fatal error: Led a team of 12 engineers at Initech jane.applicant@example.com"]],
            "termination": ["indicator": "Trace/BPT trap: 5", "reasons": ["Senior Widget Engineer at Globex"]],
            "faultingThread": 1,
            "threads": [
                ["frames": [["imageIndex": 1, "imageOffset": 10, "symbol": "mach_msg2_trap"]]],
                ["triggered": true, "name": "Your application to Globex", "queue": "hunter2-password",
                 "frames": [
                    ["imageIndex": 0, "imageOffset": 4242, "symbol": "Tailor.run(resume:) + 120", "sourceFile": "/Users/janeq/src/Tailor.swift"],
                    ["imageIndex": 1, "imageOffset": 77],
                 ]],
            ],
            "usedImages": [
                ["name": "Offerlane", "path": "/Users/janeq/Applications/Offerlane.app/Contents/MacOS/Offerlane"],
                ["name": "libswiftCore.dylib", "path": "/usr/lib/swift/libswiftCore.dylib"],
            ],
            "vmSummary": "sk-ant-api03-AbCdEfPLANTEDsecretPLANTEDsecret0123456789 ya29.PLANTEDoauthTOKEN0123456789abcdef +1 415 555 0134",
            "environment": ["OFFERLANE_KEY=sk-ant-api03-AbCdEfPLANTEDsecretPLANTEDsecret0123456789"],
        ]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        return header + "\n" + json
    }

    func testSummaryKeepsOnlyTechnicalFields() throws {
        let r = try XCTUnwrap(CrashReports.summarize(ips: ips(), known: ["Jane Q Applicant"]))
        for p in planted { XCTAssertFalse(r.localizedCaseInsensitiveContains(p), "leaked: \(p)\n\(r)") }
        XCTAssertTrue(r.contains("0.3.0"))
        XCTAssertTrue(r.contains("EXC_BREAKPOINT (SIGTRAP)"))
        XCTAssertTrue(r.contains("Offerlane  Tailor.run(resume:) + 120"), r)
        XCTAssertTrue(r.contains("libswiftCore.dylib  +77"), r)
        XCTAssertFalse(r.contains("mach_msg2_trap"), "only the crashed thread")
    }

    func testOtherAppsAndJunkAreIgnored() {
        XCTAssertNil(CrashReports.summarize(ips: ips(appName: "Safari")))
        XCTAssertNil(CrashReports.summarize(ips: "not a crash file"))
    }

    func testCollectRespectsConsentDateAndRunsOnce() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sys = tmp.appendingPathComponent("DiagnosticReports"), out = tmp.appendingPathComponent("outbox")
        try FileManager.default.createDirectory(at: sys, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let old = sys.appendingPathComponent("Offerlane-2026-01-01-000000.ips"), new = sys.appendingPathComponent("Offerlane-2026-11-11-120000.ips")
        try ips().write(to: old, atomically: true, encoding: .utf8)
        try ips().write(to: new, atomically: true, encoding: .utf8)
        try ips(appName: "Safari").write(to: sys.appendingPathComponent("Safari-2026-11-11-120000.ips"), atomically: true, encoding: .utf8)
        let consent = Date()
        try FileManager.default.setAttributes([.modificationDate: consent.addingTimeInterval(-3600)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: consent.addingTimeInterval(60)], ofItemAtPath: new.path)

        let first = CrashReports.collect(since: consent, from: sys, into: out)
        XCTAssertEqual(first.map(\.lastPathComponent), ["Offerlane-2026-11-11-120000.txt"], "crashes before consent stay out")
        let perms = try FileManager.default.attributesOfItem(atPath: first[0].path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertEqual(CrashReports.collect(since: consent, from: sys, into: out), [], "already collected")
    }
}
