import Foundation
import PDFKit
import ZIPFoundation

public struct ResumeImportError: LocalizedError, Equatable {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// Text from an uploaded resume file. Errors are written for the person uploading, with what to do next.
public enum Extract {
    public static let formats = ["pdf", "docx", "txt", "md", "tex"]
    public static let maxBytes = 10 * 1024 * 1024

    public static func text(filename: String, data: Data) throws -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard formats.contains(ext) else {
            if ["doc", "pages", "rtf", "odt"].contains(ext) {
                throw ResumeImportError("That format isn't supported. Save it as PDF or Word .docx and add it again.")
            }
            throw ResumeImportError("Add a PDF, Word .docx, text or LaTeX .tex file.")
        }
        guard !data.isEmpty else { throw ResumeImportError("That file is empty.") }
        guard data.count <= maxBytes else { throw ResumeImportError("That file is larger than 10 MB. Export a smaller PDF and try again.") }
        switch ext {
        case "pdf": return try pdf(data)
        case "docx": return try docx(data)
        case "tex":
            let t = String(decoding: data, as: UTF8.self)
            return t.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("%") }.map { LaTeX.human(String($0)) }.joined(separator: "\n")
        default: return String(decoding: data, as: UTF8.self)
        }
    }

    public static func pdf(_ data: Data) throws -> String {
        guard let doc = PDFDocument(data: data) else {
            throw ResumeImportError("Couldn't open that PDF. Try exporting it again, or add the .docx.")
        }
        if doc.isLocked && !doc.unlock(withPassword: "") {
            throw ResumeImportError("That PDF is password-protected. Export an unprotected copy and try again.")
        }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
    }

    public static func docx(_ data: Data) throws -> String {
        guard let archive = try? Archive(data: data, accessMode: .read), let entry = archive["word/document.xml"] else {
            throw ResumeImportError("Couldn't open that Word file. Save it again as .docx (or PDF) and try again.")
        }
        var xml = Data()
        do { _ = try archive.extract(entry, skipCRC32: true) { xml.append($0) } } catch {
            throw ResumeImportError("Couldn't read that Word file. Save it again as .docx (or PDF) and try again.")
        }
        return DocxText.parse(xml)
    }
}

/// Paragraph-aware text from word/document.xml: <w:t> runs, <w:tab/>, <w:br/>, paragraph breaks.
final class DocxText: NSObject, XMLParserDelegate {
    private var out = "", inText = false
    static func parse(_ xml: Data) -> String {
        let d = DocxText(); let p = XMLParser(data: xml); p.delegate = d; p.parse()
        return d.out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes: [String: String] = [:]) {
        switch e { case "w:t": inText = true; case "w:tab": out += "\t"; case "w:br": out += "\n"; default: break }
    }
    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
        if e == "w:t" { inText = false } else if e == "w:p" { out += "\n" }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { if inText { out += s } }
}
