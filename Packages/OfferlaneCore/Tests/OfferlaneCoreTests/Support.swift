import Foundation
import CoreText
import ZIPFoundation
@testable import OfferlaneCore

enum Fixture {
    /// Point the LaTeX renderer at the vendored tectonic (scripts/fetch-tectonic.sh) for tests.
    static let useVendoredTectonic: Void = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../Vendor/tectonic").standardized
        if ProcessInfo.processInfo.environment["OFFERLANE_TECTONIC"] == nil { setenv("OFFERLANE_TECTONIC", root.appendingPathComponent("bin/tectonic").path, 1) }
        if ProcessInfo.processInfo.environment["OFFERLANE_TECTONIC_CACHE"] == nil { setenv("OFFERLANE_TECTONIC_CACHE", root.appendingPathComponent("cache").path, 1) }
    }()
    static func url(_ name: String) -> URL { Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)! }
    static func data(_ name: String) -> Data { try! Data(contentsOf: url(name)) }

    /// A real previous-version (v2) data folder, read in place and never copied into the repo. Opt-in: set OFFERLANE_LEGACY_DIR.
    /// Tests that need it skip when it isn't set.
    static var legacy: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["OFFERLANE_LEGACY_DIR"] ?? "/nonexistent") }
    static var hasLegacy: Bool { FileManager.default.fileExists(atPath: legacy.appendingPathComponent("profile.json").path) }
    /// Local-only fixtures derived from personal data live in Fixtures/private (git-ignored).
    static func privateData(_ name: String) -> Data? { Bundle.module.url(forResource: "Fixtures/private/\(name)", withExtension: nil).flatMap { try? Data(contentsOf: $0) } }

    /// A text PDF built with Core Text (one page per ~45 lines).
    static func pdf(lines: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for chunk in stride(from: 0, to: lines.count, by: 45).map({ Array(lines[$0..<min($0 + 45, lines.count)]) }) {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(string: chunk.joined(separator: "\n"),
                                          attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 9, nil)])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attr), CFRange(), CGPath(rect: box.insetBy(dx: 40, dy: 40), transform: nil), nil)
            CTFrameDraw(frame, ctx); ctx.endPDFPage()
        }
        ctx.closePDF(); return data as Data
    }

    /// A minimal .docx with one paragraph per line.
    static func docx(lines: [String]) throws -> Data {
        let body = lines.map { "<w:p><w:r><w:t xml:space=\"preserve\">\($0.replacingOccurrences(of: "&", with: "&amp;"))</w:t></w:r></w:p>" }.joined()
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(body)</w:body></w:document>"
        let archive = try Archive(accessMode: .create)
        let bytes = Data(xml.utf8)
        try archive.addEntry(with: "word/document.xml", type: .file, uncompressedSize: Int64(bytes.count)) { pos, size in
            bytes.subdata(in: Int(pos)..<Int(pos) + size)
        }
        return archive.data!
    }

    static let resumeLines: [String] = [
        "Test Person", "London, UK | +44 7700 900000 | test@example.com", "Senior Data Scientist, Acme 2022 - now",
        "Built a demand forecasting system covering 1,200 products across 14 markets, cutting error by 30%.",
        "Shipped 4 production machine learning models serving 2 million users with real-time feature pipelines.",
        "Led a team of 3 analysts on pricing experiments that informed the annual pricing strategy review.",
        "Designed the experimentation platform used by 6 product teams to run A/B tests with sequential testing.",
        "Partnered with finance to build revenue forecasts reviewed monthly by the executive leadership team.",
        "Migrated legacy SAS reporting to Python and dbt, cutting the monthly close reporting time by 2 days.",
        "Data Scientist, Beta 2020 - 2022",
        "Designed churn models with gradient boosting, improving retention by 8% across the subscription base.",
        "Automated weekly reporting in Python and SQL so stakeholders got numbers every Monday morning by 9am.",
        "Education: BSc Mathematics, University of Somewhere, 2016 - 2020", "Skills: Python, SQL, forecasting, machine learning",
    ]
}

enum PrototypeFake { static var client: FakeLLM { FakeLLM.prototype } }
