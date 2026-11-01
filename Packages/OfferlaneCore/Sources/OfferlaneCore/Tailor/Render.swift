import Foundation
import CoreText
import PDFKit

/// The standard resume template, typeset with Core Text into a selectable-text, ATS-friendly PDF.
public enum ResumePDF {
    public static func pageSize(_ paper: String) -> CGSize { paper.lowercased() == "letter" ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89) }

    struct Block { var text: NSAttributedString; var spaceBefore: CGFloat; var rule = false; var keepWithNext = false }

    static func font(_ size: CGFloat, bold: Bool = false) -> CTFont { CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil) }

    static func para(_ parts: [(String, CTFont)], color: CGColor = CGColor(gray: 0.07, alpha: 1), indent: CGFloat = 0, firstIndent: CGFloat = 0,
                     rightTab: CGFloat? = nil, lineSpacing: CGFloat = 1.0) -> NSAttributedString {
        let s = NSMutableAttributedString()
        for (t, f) in parts { s.append(NSAttributedString(string: t, attributes: [.init(kCTFontAttributeName as String): f, .init(kCTForegroundColorAttributeName as String): color])) }
        var settings: [CTParagraphStyleSetting] = []
        var head = indent, first = firstIndent, mult = lineSpacing
        withUnsafeBytes(of: &head) { settings.append(CTParagraphStyleSetting(spec: .headIndent, valueSize: MemoryLayout<CGFloat>.size, value: $0.baseAddress!)) }
        withUnsafeBytes(of: &first) { settings.append(CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: MemoryLayout<CGFloat>.size, value: $0.baseAddress!)) }
        withUnsafeBytes(of: &mult) { settings.append(CTParagraphStyleSetting(spec: .lineHeightMultiple, valueSize: MemoryLayout<CGFloat>.size, value: $0.baseAddress!)) }
        var tabs: CFArray = [] as CFArray
        if let rightTab { tabs = [CTTextTabCreate(.right, Double(rightTab), nil)] as CFArray }
        let style: CTParagraphStyle = withUnsafeBytes(of: &tabs) { tabPtr in
            var all = settings
            if rightTab != nil { all.append(CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: tabPtr.baseAddress!)) }
            return CTParagraphStyleCreate(all, all.count)
        }
        s.addAttribute(.init(kCTParagraphStyleAttributeName as String), value: style, range: NSRange(location: 0, length: s.length))
        return s
    }

    static func blocks(_ c: ResumeContent, scale k: CGFloat, width: CGFloat) -> [Block] {
        let fs = 10.3 * k, grey = CGColor(gray: 0.2, alpha: 1)
        var b: [Block] = []
        b.append(Block(text: para([(c.name, font(17 * k, bold: true))]), spaceBefore: 0))
        let contact = ([c.location, c.phone, c.email] + c.links.keys.sorted().compactMap { c.links[$0] }).filter { !$0.isEmpty }.joined(separator: " | ")
        if !contact.isEmpty { b.append(Block(text: para([(contact, font(fs))], color: grey), spaceBefore: 2 * k)) }
        if !c.headline.isEmpty { b.append(Block(text: para([(c.headline, font(fs, bold: true))]), spaceBefore: 3 * k)) }
        func heading(_ t: String) { b.append(Block(text: para([(t.uppercased(), font(10.6 * k, bold: true))]), spaceBefore: 9 * k, rule: true, keepWithNext: true)) }
        if !c.summary.isEmpty { heading("Summary"); b.append(Block(text: para([(c.summary, font(fs))], lineSpacing: 1.05), spaceBefore: 3 * k)) }
        func section(_ title: String, _ items: [ResumeContent.Section], head: (ResumeContent.Section) -> [(String, CTFont)]) {
            guard !items.isEmpty else { return }
            heading(title)
            for it in items {
                var parts = head(it); if !it.dates.isEmpty { parts.append(("\t" + it.dates, font(fs))) }
                b.append(Block(text: para(parts, rightTab: width), spaceBefore: 4 * k, keepWithNext: !it.bullets.isEmpty))
                for bl in it.bullets { b.append(Block(text: para([("•\t", font(fs)), (bl.text, font(fs))], indent: 11 * k, firstIndent: 1 * k, lineSpacing: 1.05), spaceBefore: 1.2 * k)) }
            }
        }
        section("Experience", c.experience.filter { !$0.bullets.isEmpty || !$0.company.isEmpty }) { e in
            [(e.title, font(fs, bold: true))] + (e.company.isEmpty ? [] : [(", " + e.company, font(fs))]) + (e.location.isEmpty ? [] : [(" – " + e.location, font(fs))])
        }
        section("Projects", c.projects.filter { !$0.bullets.isEmpty }) { p in [(p.name.isEmpty ? p.title : p.name, font(fs, bold: true))] }
        if !c.education.isEmpty {
            heading("Education")
            for e in c.education {
                var parts: [(String, CTFont)] = [(e.degree, font(fs, bold: true)), (", " + e.school + (e.details.isEmpty ? "" : " – " + e.details), font(fs))]
                if !e.dates.isEmpty { parts.append(("\t" + e.dates, font(fs))) }
                b.append(Block(text: para(parts, rightTab: width), spaceBefore: 3 * k))
            }
        }
        if !c.skills.isEmpty {
            heading("Skills")
            for s in c.skills { b.append(Block(text: para([(s.label + ": ", font(fs, bold: true)), (s.items, font(fs))]), spaceBefore: 1.5 * k)) }
        }
        let extra = (c.certifications + c.extras).filter { !$0.isEmpty }
        if !extra.isEmpty { heading("Additional"); b.append(Block(text: para([(extra.joined(separator: " · "), font(fs))]), spaceBefore: 3 * k)) }
        return b
    }

    /// One render at a given type scale. Returns the PDF and its page count.
    public static func render(_ c: ResumeContent, paper: String = "A4", scale: CGFloat = 1) -> (Data, Int) {
        var box = CGRect(origin: .zero, size: pageSize(paper))
        let margin = 11 / 25.4 * 72 * scale, width = box.width - 2 * margin
        let data = NSMutableData()
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, [kCGPDFContextTitle: "\(c.name) Resume", kCGPDFContextCreator: "Offerlane"] as CFDictionary)!
        let blocks = blocks(c, scale: scale, width: width)
        func height(_ s: NSAttributedString) -> CGFloat {
            CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(s), CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil).height.rounded(.up)
        }
        var pages = 1, y = box.height - margin
        ctx.beginPDFPage(nil)
        for (i, bl) in blocks.enumerated() {
            let h = height(bl.text)
            var need = bl.spaceBefore + h
            if bl.keepWithNext, i + 1 < blocks.count { need += blocks[i + 1].spaceBefore + height(blocks[i + 1].text) }
            if y - need < margin && y < box.height - margin - 1 { ctx.endPDFPage(); ctx.beginPDFPage(nil); pages += 1; y = box.height - margin }
            else { y -= bl.spaceBefore }
            let rect = CGRect(x: margin, y: y - h, width: width, height: h)
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(bl.text), CFRange(), CGPath(rect: rect, transform: nil), nil), ctx)
            y -= h
            if bl.rule { ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1)); ctx.setLineWidth(0.6); ctx.move(to: CGPoint(x: margin, y: y - 1)); ctx.addLine(to: CGPoint(x: margin + width, y: y - 1)); ctx.strokePath(); y -= 2 }
        }
        ctx.endPDFPage(); ctx.closePDF()
        return (data as Data, pages)
    }

    public static func pages(_ pdf: Data) -> Int { PDFDocument(data: pdf)?.pageCount ?? 0 }
    public static func text(_ pdf: Data) -> String {
        guard let d = PDFDocument(data: pdf) else { return "" }
        return (0..<d.pageCount).compactMap { d.page(at: $0)?.string }.joined(separator: "\n")
    }
}

/// LaTeX resumes: the user's own .tex with only the bullet text swapped, compiled by the bundled tectonic.
public enum LaTeXRender {
    static let pdftexOnly = "^[ \\t]*\\\\(?:input\\{glyphtounicode\\}|pdfgentounicode\\s*=\\s*1|pdfglyphtounicode\\b).*$"

    public static func source(_ c: ResumeContent, version v: ResumeVersion) throws -> String {
        guard let tex = v.templateTex, let tpl = v.template else { throw RenderError.failed("No LaTeX template saved for this version.") }
        var L = tex.components(separatedBy: "\n"); let base = v.content
        // The saved line numbers must still describe this file (it could have been edited outside the app).
        guard tpl.sections.allSatisfy({ $0.begin < $0.end && $0.end < L.count && ($0.header ?? $0.begin) <= $0.begin }),
              (tpl.headlineLine ?? 0) < L.count, (tpl.summaryLine ?? 0) < L.count else {
            throw RenderError.failed("The LaTeX template no longer matches its saved structure; add the .tex file again.")
        }
        let raw = Dictionary(tpl.sections.flatMap { $0.bullets.map { ($0.id, $0.raw) } }, uniquingKeysWith: { a, _ in a })
        let bySec = Dictionary(c.sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func swap(_ n: Int, _ new: String) {
            guard n < L.count else { return }
            if let g = Re.groups("^(\\s*\\{\\\\small\\s*)(.*)(\\}(\\\\\\\\(\\[[^\\]]*\\])?)?\\s*)$", L[n], []), let a = g[1], let z = g[3] { L[n] = a + LaTeX.esc(new) + z }
            else { L[n] = LaTeX.esc(new) }
        }
        if let n = tpl.headlineLine, !c.headline.isEmpty, c.headline != base.headline { swap(n, c.headline) }
        if let n = tpl.summaryLine, !c.summary.isEmpty, c.summary != base.summary { swap(n, c.summary) }
        for s in tpl.sections.sorted(by: { $0.begin > $1.begin }) {
            let bl = bySec[s.id]?.bullets ?? []
            let items = bl.map { b in "\\item " + ((b.text == (b.original ?? b.text)) ? (raw[b.id] ?? LaTeX.esc(b.text)) : LaTeX.esc(b.text)) }
            if !items.isEmpty { L.replaceSubrange((s.begin + 1)..<s.end, with: items) }
            else { L.removeSubrange((s.header ?? s.begin)...s.end) }
        }
        return Re.sub(pdftexOnly, "% $0", L.joined(separator: "\n") + "\n", [.anchorsMatchLines])
    }

    public static var tectonic: URL? {
        let env = ProcessInfo.processInfo.environment["OFFERLANE_TECTONIC"].map { URL(fileURLWithPath: $0) }
        let bundled = Bundle.main.url(forAuxiliaryExecutable: "tectonic") ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tectonic")
        // Development and tests point OFFERLANE_TECTONIC at Vendor/tectonic/bin/tectonic; shipped apps use the bundled copy.
        return [env, bundled].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Package cache: App Support, seeded from the bundled pre-warmed cache on first use.
    public static func cacheDir() -> URL {
        let dir = Paths.root.appendingPathComponent("tectonic-cache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            let seeds = [Bundle.main.resourceURL?.appendingPathComponent("TectonicCache"),
                         ProcessInfo.processInfo.environment["OFFERLANE_TECTONIC_CACHE"].map { URL(fileURLWithPath: $0) }]
            if let seed = seeds.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                try? FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: seed, to: dir)
            }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public static func compile(_ tex: String) async throws -> Data {
        guard let exe = tectonic else { throw RenderError.failed("The LaTeX engine is missing from this copy of Offerlane.") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("offerlane-tex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try tex.write(to: work.appendingPathComponent("r.tex"), atomically: true, encoding: .utf8)
        let out = try await ProcessRunner.run(exe, ["--untrusted", "--keep-logs", "r.tex"], cwd: work, env: ["TECTONIC_CACHE_DIR": cacheDir().path], timeout: 300)
        let pdf = work.appendingPathComponent("r.pdf")
        guard FileManager.default.fileExists(atPath: pdf.path) else {
            let log = (try? String(contentsOf: work.appendingPathComponent("r.log"), encoding: .utf8)) ?? out.stdout + out.stderr
            let errs = log.split(separator: "\n").filter { $0.hasPrefix("!") || $0.hasPrefix("error") }.prefix(3).joined(separator: " | ")
            throw RenderError.failed("LaTeX failed: " + (errs.isEmpty ? String(log.suffix(400)) : errs))
        }
        return try Data(contentsOf: pdf)
    }
}

public enum RenderError: LocalizedError, Equatable {
    case failed(String)
    public var errorDescription: String? { if case .failed(let m) = self { return m }; return nil }
}

/// Render with the page budget: shrink type a little, then drop the weakest trailing bullets.
public enum Builder {
    public struct Output: Sendable { public var pdf: Data; public var pages: Int; public var trimmed: [String]; public var note: String?; public var content: ResumeContent }

    public static func maxPages(_ v: ResumeVersion) -> Int { v.content.yearsValue < 8 ? 1 : 2 }

    static func trim(_ c: inout ResumeContent, _ trimmed: inout [String]) -> Bool {
        var all = c.experience.map { (true, $0.id) } + c.projects.map { (false, $0.id) }
        all.reverse()
        let pick = all.first { e, id in ((e ? c.experience : c.projects).first { $0.id == id }?.bullets.count ?? 0) > 2 }
            ?? all.first { e, id in !((e ? c.experience : c.projects).first { $0.id == id }?.bullets.isEmpty ?? true) }
        guard let (isExp, id) = pick else { return false }
        if isExp, let i = c.experience.firstIndex(where: { $0.id == id }) { trimmed.append(c.experience[i].bullets.removeLast().id) }
        else if let i = c.projects.firstIndex(where: { $0.id == id }) { trimmed.append(c.projects[i].bullets.removeLast().id) }
        return true
    }

    public static func render(_ content: ResumeContent, version v: ResumeVersion, paper: String) async throws -> Output {
        var c = content, trimmed: [String] = []
        let budget = maxPages(v)
        if v.content.format == "tex", v.templateTex != nil {
            do {
                for _ in 0..<25 {
                    let src = try LaTeXRender.source(c, version: v)
                    let pdf = try await LaTeXRender.compile(src), n = ResumePDF.pages(pdf)
                    if n <= budget || !trim(&c, &trimmed) { return Output(pdf: pdf, pages: n, trimmed: trimmed, note: nil, content: c) }
                }
                throw RenderError.failed("The resume didn't fit the page budget.")
            } catch {
                Log.error("latex: \(error.localizedDescription)")
                c = content; trimmed = []
                var out = try await render(c, version: ResumeVersion(name: v.name, label: v.label, content: { var x = v.content; x.format = "html"; return x }(),
                                                                       sourceText: v.sourceText, sourceFile: v.sourceFile), paper: paper)
                out.note = "Your LaTeX design couldn't be built (\(error.localizedDescription.prefix(160))), so the standard template was used."
                return out
            }
        }
        var scale: CGFloat = 1
        for _ in 0..<40 {
            let (pdf, n) = ResumePDF.render(c, paper: paper, scale: scale)
            if n <= budget { return Output(pdf: pdf, pages: n, trimmed: trimmed, note: nil, content: c) }
            if scale > 0.9 { scale = max(0.9, ((scale - 0.03) * 100).rounded() / 100); continue }
            if !trim(&c, &trimmed) { return Output(pdf: pdf, pages: n, trimmed: trimmed, note: nil, content: c) }
        }
        let (pdf, n) = ResumePDF.render(c, paper: paper, scale: scale)
        return Output(pdf: pdf, pages: n, trimmed: trimmed, note: nil, content: c)
    }

    /// Text-extraction check: is the PDF readable by an ATS, and which JD keywords made it in?
    public static func atsCheck(_ pdf: Data, keywords: [String], name: String) -> (String, [String]) {
        let t = ResumePDF.text(pdf).lowercased()
        var probs: [String] = []
        if t.count < 300 { probs.append("very little extractable text") }
        if let first = name.lowercased().split(separator: " ").first, !t.contains(first) { probs.append("name not extractable") }
        if !Re.search("[\\w.+-]+@[\\w-]+\\.[\\w.]+", t) { probs.append("email not extractable") }
        let missing = keywords.filter { !t.contains($0.lowercased()) }
        return ((probs.isEmpty ? "PASS" : "FAIL: " + probs.joined(separator: "; ")) + " (\(keywords.count - missing.count)/\(keywords.count) JD keywords readable)", missing)
    }
}
