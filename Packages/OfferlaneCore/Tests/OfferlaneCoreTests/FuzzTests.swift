import XCTest
import ZIPFoundation
@testable import OfferlaneCore

/// Hostile and random input for every parser that sees outside data: resumes (PDF, Word, LaTeX, text),
/// job-posting HTML, and email (headers, MIME words, bodies with verification links).
/// The bar: never crash or hang; fail with a friendly error or return text.
final class FuzzTests: XCTestCase {
    /// Deterministic generator so failures reproduce.
    struct RNG: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    }
    var rng = RNG(s: 0x0FFE_271A_9E37_79B9)

    func bytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }) }
    func mutate(_ d: Data, flips: Int) -> Data {
        var m = d; guard !m.isEmpty else { return m }
        for _ in 0..<flips { m[Int.random(in: 0..<m.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
        if Bool.random(using: &rng) { m = m.prefix(Int.random(in: 0..<m.count, using: &rng)) }
        return m
    }
    func text(_ n: Int, alphabet: String) -> String { String((0..<n).map { _ in alphabet.randomElement(using: &rng)! }) }

    func testResumeExtractionNeverCrashes() throws {
        let pdf = Fixture.pdf(lines: Fixture.resumeLines), docx = try Fixture.docx(lines: Fixture.resumeLines)
        for i in 0..<120 {
            for (name, seed) in [("cv.pdf", pdf), ("cv.docx", docx), ("cv.txt", Data("Resume text".utf8)), ("cv.md", Data("# Resume".utf8))] {
                let input = i % 3 == 0 ? bytes(Int.random(in: 0...4096, using: &rng)) : mutate(seed, flips: 1 + i % 40)
                do { _ = try Extract.text(filename: name, data: input) } catch let e as ResumeImportError {
                    XCTAssertFalse(e.localizedDescription.isEmpty)
                } catch { XCTFail("\(name) #\(i): unexpected \(error)") }
            }
        }
    }

    /// A .docx whose document.xml expands to far more than any resume is refused without reading it all.
    func testDocxZipBombIsRefused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bomb-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        let size = 64 << 20   // 64 MB of zeros compresses to ~64 KB
        try archive.addEntry(with: "word/document.xml", type: .file, uncompressedSize: Int64(size), compressionMethod: .deflate) { pos, n in
            Data(count: min(n, size - Int(pos)))
        }
        let data = try Data(contentsOf: url)
        XCTAssertLessThan(data.count, 1 << 20)
        XCTAssertThrowsError(try Extract.text(filename: "bomb.docx", data: data)) {
            XCTAssertTrue($0.localizedDescription.contains("far larger than a resume"), $0.localizedDescription)
        }
    }

    /// XML external entities in a Word file are never resolved (no file reads, no network).
    func testDocxExternalEntitiesAreIgnored() throws {
        let xml = """
        <?xml version="1.0"?><!DOCTYPE d [<!ENTITY x SYSTEM "file:///etc/passwd">]>
        <w:document xmlns:w="w"><w:body><w:p><w:r><w:t>Name &x; end</w:t></w:r></w:p></w:body></w:document>
        """
        let out = DocxText.parse(Data(xml.utf8))
        XCTAssertFalse(out.contains("root:"), "no /etc/passwd contents")
    }

    func testLaTeXParserNeverCrashes() throws {
        let sample = String(decoding: Fixture.data("sample_resume.tex"), as: UTF8.self)
        let alphabet = "\\{}[]%$&#_^~ abcdefgitemsection\n"
        for i in 0..<300 {
            var s: String
            switch i % 4 {
            case 0: s = text(Int.random(in: 0...3000, using: &rng), alphabet: alphabet)
            case 1: s = String(String(decoding: mutate(Data(sample.utf8), flips: 1 + i % 60), as: UTF8.self))
            case 2: s = String(repeating: "{", count: 5000) + "\\item x" + String(repeating: "}", count: 10)   // deep nesting
            default: s = "\\begin{itemize}" + String(repeating: "\\item \\textbf{", count: 2000)
            }
            _ = LaTeX.parse(s); _ = LaTeX.human(s); _ = LaTeX.esc(s)
        }
    }

    func testHTMLAndEmailParsersNeverCrash() {
        let tags = "<>/=\"' abc&;#xscriptstyle!--\n\u{0}\u{FEFF}é漢"
        for i in 0..<300 {
            let s = text(Int.random(in: 0...4000, using: &rng), alphabet: tags)
            _ = Text.stripHTML(s)
            _ = Ranking.condense(s)
            _ = Mime.decodeWords("=?utf-8?B?\(text(i % 50, alphabet: "A+/=b9"))?= =?x-unknown?Q?\(text(i % 40, alphabet: "=A_3F"))?=")
            let header = Data(("Subject: " + s.prefix(300) + "\r\nFrom: " + text(40, alphabet: tags) + "\r\nContent-Type: multipart/mixed; boundary=\"" + text(10, alphabet: "-ab") + "\"\r\n\r\n").utf8)
            let msg = MailMessage.parse(seq: i, header: header, body: Data(s.utf8))
            _ = Tracking.classify(msg.subject + " " + msg.snippet)
            _ = Tracking.verification(in: [msg], hint: "workday")
        }
        // A pathological body: enormous, deeply nested markup.
        _ = Text.stripHTML(String(repeating: "<div>", count: 50_000) + "x")
    }
}
