import XCTest
@testable import OfferlaneCore

/// Regression tests for the v0.2 security review (docs/SECURITY_REVIEW.md).
final class SecurityTests: XCTestCase {
    // MARK: F5 — AI text can't become LaTeX commands

    func testEscapeNeutralisesTeXCommands() {
        let attacks = ["^^5cinput{/etc/hosts}", "\\input{/etc/hosts}", "{\\catcode`\\^=7 x}", "\\write18{rm -rf ~}", "a}\\end{itemize}\\input{x}{"]
        for a in attacks {
            let e = LaTeX.esc(a)
            XCTAssertFalse(e.contains("^^"), e)
            XCTAssertNil(e.range(of: #"(?<!\\)\\(input|write|catcode|end|include|openin|read)"#, options: .regularExpression), "command survived: \(e)")
            let bare = ["\\textasciicircum{}", "\\textasciitilde{}", "\\textperiodcentered{}"].reduce(e) { $0.replacingOccurrences(of: $1, with: "") }
            XCTAssertNil(bare.range(of: #"(?<!\\)[{}]"#, options: .regularExpression), "unescaped brace: \(e)")
        }
        XCTAssertEqual(LaTeX.esc("Cut cost 30% & grew **revenue**"), "Cut cost 30\\% \\& grew \\textbf{revenue}")
    }

    /// The real engine: an injected `^^5cinput` must not pull a local file into the resume.
    func testTectonicNeverReadsAFileFromAIText() async throws {
        let vendor = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../Vendor/tectonic").standardized
        let exe = vendor.appendingPathComponent("bin/tectonic")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { throw XCTSkip("tectonic not vendored (scripts/fetch-tectonic.sh)") }
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("secret-\(UUID().uuidString).txt")
        try "MARKER-SECRET-4242".write(to: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secret) }
        let payload = "Led growth ^^5cinput{\(secret.path)} end"
        let tex = "\\documentclass{article}\\begin{document}\(LaTeX.esc(payload))\\end{document}"
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("sec-tex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try tex.write(to: work.appendingPathComponent("r.tex"), atomically: true, encoding: .utf8)
        let out = try await ProcessRunner.run(exe, ["--untrusted", "r.tex"], cwd: work, env: ["TECTONIC_CACHE_DIR": vendor.appendingPathComponent("cache").path], timeout: 120)
        let pdf = work.appendingPathComponent("r.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path), "the escaped text compiles: \(out.stderr.suffix(300))")
        let text = try Extract.pdf(Data(contentsOf: pdf))
        XCTAssertFalse(text.contains("MARKER-SECRET"), "a local file was typeset into the resume")
        XCTAssertTrue(text.contains("Led growth"))
    }

    // MARK: F2 — email links

    func mail(from: String, subject: String, body: String) -> MailMessage {
        MailMessage.parse(seq: 1, header: Data("From: \(from)\r\nSubject: \(subject)\r\n\r\n".utf8), body: Data(body.utf8))
    }

    func testVerificationLinksMustBeOnTheApplicationSite() {
        let site = "acme.wd5.myworkdayjobs.com"
        let evil = mail(from: "Workday <alerts@evil.example>", subject: "Workday: verify your Acme account", body: "Verify: https://evil.example/verify?x=1")
        let mixed = mail(from: "Acme <noreply@myworkday.com>", subject: "Verify your account", body: "https://evil.example/verify https://acme.wd5.myworkdayjobs.com/verify?t=abc")
        let plain = mail(from: "Acme <noreply@myworkday.com>", subject: "Verify your account", body: "http://acme.wd5.myworkdayjobs.com/verify?t=abc")
        XCTAssertNil(Tracking.verification(in: [evil], hint: "acme", site: site), "a sender off the site is ignored")
        XCTAssertEqual(Tracking.verification(in: [mixed], hint: "acme", site: site)?.link, "https://acme.wd5.myworkdayjobs.com/verify?t=abc", "only the on-site link is used")
        XCTAssertNil(Tracking.verification(in: [plain], hint: "acme", site: site)?.link, "plain http is refused")
        // Newest first: a planted older message never wins over the real one.
        let older = mail(from: "Acme <noreply@myworkday.com>", subject: "Verify", body: "https://acme.wd5.myworkdayjobs.com/verify?t=OLD")
        let newer = mail(from: "Acme <noreply@myworkday.com>", subject: "Verify", body: "https://acme.wd5.myworkdayjobs.com/verify?t=NEW")
        XCTAssertEqual(Tracking.verification(in: [older, newer], hint: "acme", site: site)?.link?.hasSuffix("NEW"), true)
        XCTAssertEqual(Tracking.siteDomain("jobs.acme.co.uk"), "acme.co.uk")
        XCTAssertEqual(Tracking.siteDomain("boards.greenhouse.io"), "greenhouse.io")
        XCTAssertTrue(Tracking.trustedLink("https://careers.acme.com/confirm", site: "jobs.acme.com:443"))
        XCTAssertFalse(Tracking.trustedLink("https://acme.com.evil.example/confirm", site: "jobs.acme.com"))
    }

    // MARK: F13 / F14 — outside links and typed settings

    func testOnlyWebLinksAreOpened() {
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "x-apple-systempreferences:", "ssh://host", "/relative", ""] { XCTAssertNil(URL.web(bad), bad) }
        XCTAssertNotNil(URL.web(" https://jobs.lever.co/acme/1 "))
    }

    func testTypedSettingsNeverCrash() {
        var s = AppSettings(); s.provider = .ollama; s.modelSmart = "m"; s.baseUrl = "ht tp://bad url ✗"
        XCTAssertNotNil(AIFactory.client(s, keychain: Keychain(service: "test.\(UUID().uuidString)")), "a bad address falls back instead of crashing")
        XCTAssertEqual(Ntfy.url(topic: "my topic/../x?y=1").absoluteString, "https://ntfy.sh/mytopicxy1")
        XCTAssertEqual(Ntfy.url(topic: "").absoluteString, "https://ntfy.sh/offerlane")
    }

    // MARK: F9 — private details stay out of employer-facing prompts

    func testTailoringBriefLeavesOutPayAndNotes() {
        var p = Profile(); p.work.currentSalary = "£91,234"; p.work.expectedSalary = "£120k"; p.prefs.notes = "secret note"
        let r = ResumeContent()
        let full = Brief.candidate(resume: r, versions: [], profile: p, search: SearchConfig())
        let tailoring = Brief.candidate(resume: r, versions: [], profile: p, search: SearchConfig(), includePrivate: false)
        XCTAssertTrue(full.contains("£91,234") && full.contains("secret note"), "scoring still weighs pay")
        XCTAssertFalse(tailoring.contains("£91,234") || tailoring.contains("£120k") || tailoring.contains("secret note"))
    }

    // MARK: F4 — the Touch ID requirement lives in Keychain

    func testSessionCarriesTouchIDAndOldSessionsStillOpen() throws {
        let old = try JSONDecoder().decode(Session.self, from: Data(#"{"accountID":"a1","since":"2026-10-01T00:00:00Z"}"#.utf8))
        XCTAssertFalse(old.touchID, "a v0.2-beta session without the field still decodes")
        let s = Session(accountID: "a1", since: "x", touchID: true)
        XCTAssertEqual(try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(s)), s)
    }

    func testTestSwitchesAreOnlyOfferlaneKeys() {
        XCTAssertTrue(TestHooks.env.keys.allSatisfy { $0.hasPrefix("OFFERLANE_") })
        XCTAssertNil(TestHooks.env["PATH"])
    }

    // MARK: F6 / F10

    func testBackupsExpireAndAIRepliesStayOutOfErrors() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        for n in ["v0.1-old", "v0.1-new", "keep-me"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent("Backups/\(n)"), withIntermediateDirectories: true)
        }
        // The v0.1 copies are unencrypted, so they go after a week (human decision, P1.10).
        XCTAssertEqual(LegacyData.keepDays, 7)
        XCTAssertEqual(LegacyData.removeBackups(base: base, now: Date().addingTimeInterval(6 * 86_400)), 0, "recent backups are kept")
        XCTAssertEqual(LegacyData.removeBackups(base: base, now: Date().addingTimeInterval(8 * 86_400)), 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("Backups/keep-me").path), "only v0.1 backups are touched")
        XCTAssertFalse(LLMError.badJSON("Jane Doe, 12 Acacia Ave").localizedDescription.contains("Jane"))
    }
}
