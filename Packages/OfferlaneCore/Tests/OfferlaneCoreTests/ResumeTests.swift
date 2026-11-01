import XCTest
@testable import OfferlaneCore

final class ResumeTests: XCTestCase {
    func testHumanAndEscMatchPython() {
        // Expected values printed by the prototype's resume.human / resume.esc.
        XCTAssertEqual(LaTeX.human("Built \\textbf{X} at 30\\% \\& more -- fast"), "Built X at 30% & more – fast")
        XCTAssertEqual(LaTeX.human("\\href{https://a.b}{link} \\textasciitilde{}5"), "link ~5")
        XCTAssertEqual(LaTeX.human("\\small{Hello} \\textit{world}"), "Hello world")
        XCTAssertEqual(LaTeX.esc("30% & a_b – c · ~5 **bold**"), "30\\% \\& a\\_b -- c \\textperiodcentered{} \\textasciitilde{}5 \\textbf{bold}")
    }

    func testSampleTexKeepsExactBullets() {
        let tpl = LaTeX.parse(String(decoding: Fixture.data("sample_resume.tex"), as: UTF8.self))
        XCTAssertEqual(tpl.sections.count, 2)
        XCTAssertEqual(tpl.sections[0].title, "Senior Data Scientist, Acme")
        XCTAssertEqual(tpl.sections[0].bullets.map(\.id), ["1.1", "1.2", "1.3"])
        XCTAssertEqual(tpl.sections[1].bullets[0].raw, "Designed churn models with \\textbf{gradient boosting}, improving retention by 8\\%.")
        XCTAssertEqual(tpl.sections[1].bullets[0].text, "Designed churn models with gradient boosting, improving retention by 8%.")
        XCTAssertNotNil(tpl.summaryLine); XCTAssertNotNil(tpl.headlineLine)
    }

    /// A v2 folder's LaTeX versions parse exactly as the Python prototype parsed them (its template.json).
    func testLegacyTemplatesMatchPrototype() throws {
        try XCTSkipUnless(Fixture.hasLegacy, "set OFFERLANE_LEGACY_DIR to a previous-version (v2) data folder")
        let versions = try FileManager.default.contentsOfDirectory(atPath: Fixture.legacy.appendingPathComponent("resumes").path)
            .filter { FileManager.default.fileExists(atPath: Fixture.legacy.appendingPathComponent("resumes/\($0)/template.tex").path) }
        XCTAssertFalse(versions.isEmpty)
        for v in versions {
            let dir = Fixture.legacy.appendingPathComponent("resumes/\(v)")
            let tex = try String(contentsOf: dir.appendingPathComponent("template.tex"), encoding: .utf8)
            let expected = try JSONCoding.decoder.decode(TexTemplate.self, from: Data(contentsOf: dir.appendingPathComponent("template.json")))
            let got = LaTeX.parse(tex)
            XCTAssertEqual(got.sections.count, expected.sections.count, v)
            for (a, b) in zip(got.sections, expected.sections) {
                XCTAssertEqual(a.id, b.id); XCTAssertEqual(a.title, b.title, v); XCTAssertEqual(a.header, b.header)
                XCTAssertEqual(a.begin, b.begin); XCTAssertEqual(a.end, b.end)
                XCTAssertEqual(a.bullets.map(\.raw), b.bullets.map(\.raw), "\(v) \(a.id)")
                XCTAssertEqual(a.bullets.map(\.text), b.bullets.map(\.text), "\(v) \(a.id)")
            }
            XCTAssertEqual(got.headlineLine, expected.headlineLine, v); XCTAssertEqual(got.summaryLine, expected.summaryLine, v)
        }
    }

    func testExtractPDFAndDOCX() throws {
        let pdf = try Extract.text(filename: "cv.pdf", data: Fixture.pdf(lines: Fixture.resumeLines))
        XCTAssertTrue(pdf.contains("demand forecasting system"), pdf)
        let docx = try Extract.text(filename: "cv.docx", data: Fixture.docx(lines: ["Hello & welcome", "Second line"]))
        XCTAssertEqual(docx.trimmingCharacters(in: .whitespacesAndNewlines), "Hello & welcome\nSecond line")
    }

    func testExtractErrorsAreActionable() {
        func msg(_ name: String, _ data: Data) -> String {
            do { _ = try Extract.text(filename: name, data: data); return "" } catch { return error.localizedDescription }
        }
        XCTAssertTrue(msg("cv.pages", Data("x".utf8)).contains("Save it as PDF or Word .docx"))
        XCTAssertTrue(msg("cv.exe", Data("x".utf8)).contains("Add a PDF"))
        XCTAssertEqual(msg("cv.pdf", Data()), "That file is empty.")
        XCTAssertTrue(msg("cv.pdf", Data("not a pdf".utf8)).contains("Couldn't open that PDF"))
        XCTAssertTrue(msg("cv.docx", Data("not a zip".utf8)).contains("Couldn't open that Word file"))
    }

    func testParsePDFAndLaTeXWithFakeAI() async throws {
        let p = ResumeParser(ai: AI(client: PrototypeFake.client, store: nil))
        let main = try await p.parse(filename: "cv.pdf", data: Fixture.pdf(lines: Fixture.resumeLines), name: "main", label: "Main")
        XCTAssertEqual(main.content.format, "html")
        XCTAssertGreaterThan(main.content.bulletCount, 5, "PDF resume parsed into a bullet bank")
        XCTAssertEqual(main.content.experience.first?.bullets.first?.id, "e1.1")
        XCTAssertEqual(main.content.yearsExperience, "5")

        let tex = try await p.parse(filename: "cv.tex", data: Fixture.data("sample_resume.tex"), name: "latex", label: "LaTeX")
        XCTAssertEqual(tex.content.format, "tex")
        XCTAssertEqual(tex.content.experience.first?.bullets.first?.id, "1.1", "LaTeX resume keeps exact bullets from \\item lines")
        XCTAssertNotNil(tex.templateTex); XCTAssertEqual(tex.template?.sections.count, 2)
    }

    func testParseRejectsUnreadableAndBadNames() async {
        let p = ResumeParser(ai: AI(client: PrototypeFake.client, store: nil))
        do { _ = try await p.parse(filename: "cv.txt", data: Data("too short".utf8), name: "main", label: ""); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("scanned image"))
        }
        do { _ = try await p.parse(filename: "cv.txt", data: Data("x".utf8), name: "Bad Name", label: ""); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("lowercase"))
        }
    }
}
