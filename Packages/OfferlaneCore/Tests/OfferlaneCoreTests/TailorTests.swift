import XCTest
import PDFKit
@testable import OfferlaneCore

final class GuardTests: XCTestCase {
    func testGuard() {
        let src = "Built a demand forecasting system covering 1,200 products, cutting error by 30%. Python, SQL."
        XCTAssertFalse(Guard.check("Made up claim with 999 users.", source: src).ok, "guard rejects 999")
        XCTAssertEqual(Guard.check("Made up claim with 999 users.", source: src).warnings, ["numbers not in your resume: [\"999\"]"])
        XCTAssertTrue(Guard.check("Forecasting for 1200 products cut error 30%", source: src).ok, "numbers already present (comma-insensitive)")
        let (ok, w) = Guard.check("Built forecasting in Python with Kubernetes and Terraform", source: src)
        XCTAssertTrue(ok); XCTAssertEqual(w, ["new terms, check they are true: [\"Kubernetes\", \"Terraform\"]"], "new tools flagged, sentence start skipped")
        XCTAssertFalse(Guard.check("Used GPT4 for forecasting", source: src).ok, "digits inside a new term count as a new number, as in the prototype")
    }
}

final class TailorTests: XCTestCase {
    var home: URL!
    override func setUp() {
        _ = Fixture.useVendoredTectonic
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tailor-\(UUID().uuidString)")
        setenv("OFFERLANE_HOME", home.path, 1)
    }
    override func tearDown() { unsetenv("OFFERLANE_HOME"); try? FileManager.default.removeItem(at: home) }

    func makeStore() async throws -> (Store, AI) {
        let store = try Store(), ai = AI(client: FakeLLM.prototype, store: store)
        let p = ResumeParser(ai: ai)
        try store.saveResume(try await p.parse(filename: "cv.pdf", data: Fixture.pdf(lines: Fixture.resumeLines), name: "main", label: "Main"))
        try store.saveResume(try await p.parse(filename: "cv.tex", data: Fixture.data("sample_resume.tex"), name: "latex", label: "LaTeX"))
        var prof = Profile(); prof.personal.firstName = "Test"; prof.personal.lastName = "Person"; prof.personal.email = "test@example.com"
        try store.set(.profile, prof)
        return (store, ai)
    }

    func approved(_ store: Store, variant: String) throws -> Job {
        var j = Job(company: "Globex", title: "Senior Data Scientist", location: "London, UK", url: "https://x/\(variant)")
        j.description = "You will build forecasting models. Requirements: Python, SQL and machine learning. Experience with demand planning."
        try store.upsert(j); try store.update(j.id) { $0.variant = variant }
        return try store.transition(j.id, to: .tailoring, by: "you")
    }

    func testTailorGuardDiffEditRedo() async throws {
        let (store, ai) = try await makeStore()
        let j = try approved(store, variant: "main")
        let made = await { let q = TailorQueue(store: store); await q.configure(ai: ai) { _ in }; return await q.kick() }()
        XCTAssertEqual(made, 1)
        let job = try XCTUnwrap(store.job(j.id))
        XCTAssertEqual(job.status, .review, "approved role tailored and waiting for review")
        let t = Tailor(store: store, ai: ai), r = try t.review(job)
        XCTAssertTrue(r.warnings.contains { $0.contains("REJECTED") }, "guard rejected an invented number")
        XCTAssertTrue(r.groups.flatMap(\.bullets).contains { $0.text.hasPrefix("Reworded") && !$0.original.hasPrefix("Reworded") }, "reworded bullet shown with original")
        XCTAssertFalse(r.groups[0].moved.isEmpty, "reordered bullets are marked moved")
        XCTAssertFalse(r.unused.isEmpty, "left-out bullets listed")
        let answers = try String(contentsOf: Tailor.dir(job).appendingPathComponent("answers.md"), encoding: .utf8)
        XCTAssertTrue(answers.contains("Hello from the cover letter") && answers.contains("Why do you want to work here?"), "cover letter + screening answers drafted")
        let ch = try XCTUnwrap(t.changes(job)); XCTAssertEqual(ch.pages, 1); XCTAssertTrue(ch.ats.hasPrefix("PASS"), ch.ats)
        XCTAssertNotNil(t.pdfURL(job)); XCTAssertEqual(t.pdfURL(job)?.lastPathComponent, "Test_Person_Resume.pdf")

        var edit = r; edit.groups[0].bullets.removeLast(); edit.groups[0].bullets[0].text = "Edited by hand."
        let rb = try await t.rebuild(j.id, edit: edit)
        XCTAssertGreaterThanOrEqual(rb.pages, 1)
        XCTAssertEqual(try t.review(job).groups[0].bullets.first?.text, "Edited by hand.", "edit + rebuild")

        try t.requeue(j.id, note: "more forecasting")
        XCTAssertEqual(try store.job(j.id)?.tailorNote, "more forecasting")
        let again = await { let q = TailorQueue(store: store); await q.configure(ai: ai) { _ in }; return await q.kick() }()
        XCTAssertEqual(again, 1); XCTAssertEqual(try store.job(j.id)?.status, .review, "redo with a note re-tailors")

        try t.requeue(j.id, quick: true)
        try await t.run(j.id)
        XCTAssertEqual(try store.job(j.id)?.changesSummary, "Your resume as-is.")
        XCTAssertTrue(try t.review(XCTUnwrap(store.job(j.id))).warnings.allSatisfy { !$0.contains("REJECTED") })
    }

    func testLaTeXVersionBuilds() async throws {
        try XCTSkipUnless(LaTeXRender.tectonic != nil, "run scripts/fetch-tectonic.sh")
        let (store, ai) = try await makeStore()
        let j = try approved(store, variant: "latex")
        try await Tailor(store: store, ai: ai).run(j.id)
        let job = try XCTUnwrap(store.job(j.id)), ch = try XCTUnwrap(Tailor(store: store, ai: ai).changes(job))
        XCTAssertNil(ch.note, "built with LaTeX, no fallback")
        XCTAssertEqual(ch.pages, 1); XCTAssertTrue(ch.ats.hasPrefix("PASS"), "LaTeX PDF built (\(ch.ats))")
        let text = ResumePDF.text(try Data(contentsOf: XCTUnwrap(Tailor(store: store, ai: ai).pdfURL(job))))
        XCTAssertTrue(text.contains("Reworded"), "rewritten bullet compiled into the user's design")
        XCTAssertFalse(text.contains("999"))
    }

    func testFallbackToStandardTemplateWhenLaTeXBreaks() async throws {
        let (store, _) = try await makeStore()
        var v = try XCTUnwrap(store.resume("latex"))
        v.templateTex = v.templateTex!.replacingOccurrences(of: "\\begin{document}", with: "\\begin{document}\\undefinedcommandxyz")
        let out = try await Builder.render(v.content, version: v, paper: "A4")
        XCTAssertNotNil(out.note, "says so when falling back"); XCTAssertEqual(out.pages, 1)
        var w = try XCTUnwrap(store.resume("latex")); w.templateTex = "\\documentclass{article}"
        let out2 = try await Builder.render(w.content, version: w, paper: "A4")
        XCTAssertTrue(out2.note?.contains("no longer matches") ?? false, "a changed template falls back instead of crashing")
    }

    func testPageFitShrinksThenTrims() async throws {
        var c = ResumeContent(); c.name = "Test Person"; c.email = "t@x.com"; c.yearsExperience = "4"
        c.experience = (1...4).map { s in .init(id: "e\(s)", title: "Data Scientist", company: "Co \(s)", dates: "20\(10 + s)",
                                               bullets: (1...9).map { .init(id: "e\(s).\($0)", text: String(repeating: "Delivered forecasting work for many teams. ", count: 3)) }) }
        let v = ResumeVersion(name: "m", label: "M", content: c, sourceText: "", sourceFile: "x")
        XCTAssertGreaterThan(ResumePDF.render(c).1, 1, "starts over budget")
        let out = try await Builder.render(c, version: v, paper: "A4")
        XCTAssertEqual(out.pages, 1); XCTAssertFalse(out.trimmed.isEmpty)
        XCTAssertEqual(out.trimmed.first, "e4.9", "weakest trailing bullet goes first")
        XCTAssertTrue(ResumePDF.text(out.pdf).contains("Test Person"))
    }

    /// §11: a v2 folder's tailored LaTeX applications re-render to the same text as the PDFs the prototype produced.
    func testLegacyApplicationsRenderIdentically() async throws {
        try XCTSkipUnless(Fixture.hasLegacy && LaTeXRender.tectonic != nil, "set OFFERLANE_LEGACY_DIR and run scripts/fetch-tectonic.sh")
        let store = try Store()
        _ = try await Task { try LegacyImporter(store: store, destination: self.home).run(from: Fixture.legacy) }.value
        let apps = Fixture.legacy.appendingPathComponent("applications")
        var compared = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: apps.path).sorted() {
            let dir = apps.appendingPathComponent(name)
            guard let pd = try? Data(contentsOf: dir.appendingPathComponent("plan.json")),
                  let pdf = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "pdf" }) else { continue }
            let plan = try JSONCoding.decoder.decode(TailorPlan.self, from: pd)
            let v = try XCTUnwrap(store.resume(plan.variant))
            let (content, _) = PlanApplier.apply(plan, to: v)
            let out = try await Builder.render(content, version: v, paper: "A4")
            func norm(_ s: String) -> String { Text.collapse(s) }
            let mine = norm(ResumePDF.text(out.pdf)), theirs = norm(ResumePDF.text(try Data(contentsOf: pdf)))
            XCTAssertNil(out.note, name)
            XCTAssertEqual(out.pages, ResumePDF.pages(try Data(contentsOf: pdf)), "\(name): page count")
            if mine != theirs {
                let a = Array(mine), b = Array(theirs); let i = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
                XCTFail("\(name) differs at \(i): …\(String(a[max(0, i - 60)..<min(a.count, i + 60)]))… vs …\(String(b[max(0, i - 60)..<min(b.count, i + 60)]))…")
            }
            compared += 1
        }
        XCTAssertGreaterThan(compared, 0)
    }
}
