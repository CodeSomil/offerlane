import XCTest
@testable import OfferlaneCore

final class DiagnosticsTests: XCTestCase {
    func testRedactsPersonalDetailsSecretsAndPaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let raw = """
        INFO applied for Jane Q Example at https://boards.greenhouse.io/acme/jobs/123?gh_src=abc&email=jane@example.com
        ERROR imap login failed for jane.example@gmail.com password=hunter2!x phone +1 (415) 555-0123
        INFO key sk-ant-api03-AbCdEf_123 bearer ya29.a0AfH6SMBxyz Authorization: Bearer abcdefghijklmnop
        INFO refresh 1//0gAbCdEfGhIjKlMnOp token: "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjMifQ.sig"
        INFO wrote \(home)/Library/Application Support/Offerlane/Applications/Acme/resume.pdf and /Users/someone/x
        INFO session 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
        INFO api_key: "abc123" secret=xyz
        """
        let out = Diagnostics.redact(raw, known: ["Jane Q Example", "Jane"])
        for leaked in ["Jane", "jane", "example.com", "hunter2", "555-0123", "sk-ant", "ya29", "abcdefghijklmnop", "1//0g", "eyJhbGci",
                       home, "/Users/someone", "9f86d081884c", "acme/jobs", "gh_src", "abc123", "xyz"] {
            XCTAssertFalse(out.contains(leaked), "leaked \(leaked):\n\(out)")
        }
        XCTAssertTrue(out.contains("https://boards.greenhouse.io/…"), "the site is kept: \(out)")
        XCTAssertTrue(out.contains("~/Library/Application Support/Offerlane"))
        XCTAssertTrue(out.contains("imap login failed"), "the useful part stays")
        let stamped = Diagnostics.redact("2026-11-01T23:06:13 INFO call +44 7700 900123 on 2026-11-02 09:15")
        XCTAssertTrue(stamped.hasPrefix("2026-11-01T23:06:13"), "timestamps survive: \(stamped)")
        XCTAssertTrue(stamped.contains("on 2026-11-02 09:15") && stamped.contains("<phone>") && !stamped.contains("900123"), stamped)
    }

    func testReportHasSystemFactsAndNoContent() {
        var i = Diagnostics.Info()
        i.appVersion = "0.2.0"; i.macOS = "Version 15.0"; i.provider = "ollama"; i.model = "qwen3.5:9b"; i.signIn = "password"; i.emailTracking = "off"
        i.counts = ["roles": 12, "applications": 3]
        i.health = [Health.Item(id: "internet", title: "Internet", status: .ok, message: "Connected.", fix: nil)]
        let log = (1...500).map { "line \($0) for test@example.org" }.joined(separator: "\n")
        let r = Diagnostics.report(i, log: log, known: ["Test Person"], now: "2026-11-01T00:00:00Z")
        XCTAssertTrue(r.contains("App: 0.2.0"))
        XCTAssertTrue(r.contains("AI: ollama · qwen3.5:9b"))
        XCTAssertTrue(r.contains("Counts: applications 3, roles 12"))
        XCTAssertTrue(r.contains("- Internet: ok · Connected."))
        XCTAssertTrue(r.contains("line 500 for <email>")); XCTAssertFalse(r.contains("line 300 "), "only the last 200 log lines")
        XCTAssertFalse(r.contains("example.org"))
    }
}
