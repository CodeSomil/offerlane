import Foundation

/// LaTeX resumes: bullets come straight from `\item` lines, so they are exact. Ported from resume.py.
public enum LaTeX {
    /// LaTeX markup → readable text.
    public static func human(_ input: String) -> String {
        var s = Re.sub("\\\\textasciitilde\\{([^}]*)\\}", "~$1", input)
        s = Re.sub("\\\\textperiodcentered\\{\\}", "·", s)
        s = Re.sub("\\\\(textbf|textit|emph|underline|small|footnotesize|href\\{[^}]*\\})\\{([^}]*)\\}", "$2", s)
        s = Re.sub("\\\\href\\{[^}]*\\}\\{([^}]*)\\}", "$1", s)
        for (a, b) in [("\\&", "&"), ("\\%", "%"), ("\\$", "$"), ("\\#", "#"), ("\\_", "_"), ("--", "–")] { s = s.replacingOccurrences(of: a, with: b) }
        s = Re.sub("\\\\[a-zA-Z]+\\*?", " ", s)
        s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "").replacingOccurrences(of: "\\", with: "")
        return Text.collapse(s)
    }

    /// Readable text → LaTeX (for rewritten bullets). `**bold**` becomes \textbf{}.
    public static func esc(_ input: String) -> String {
        var s = input.replacingOccurrences(of: "\\", with: "")
        for (a, b) in [("&", "\\&"), ("%", "\\%"), ("$", "\\$"), ("#", "\\#"), ("_", "\\_"), ("~", "\\textasciitilde{}"), ("·", "\\textperiodcentered{}"), ("–", "--")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return Re.sub("\\*\\*(.+?)\\*\\*", "\\\\textbf{$1}", s)
    }

    static let head = "\\\\textbf\\{([^}]*)\\}|\\\\(?:sub)*section\\*?\\{([^}]*)\\}"

    public static func parse(_ tex: String) -> TexTemplate {
        let L = tex.components(separatedBy: "\n")
        var tpl = TexTemplate(); var i = 0
        while i < L.count {
            if L[i].trimmingCharacters(in: .whitespaces).hasPrefix("\\begin{itemize}") {
                var j = i + 1; var items: [String] = []
                while j < L.count && !L[j].trimmingCharacters(in: .whitespaces).hasPrefix("\\end{itemize}") {
                    let s = L[j].trimmingCharacters(in: .whitespaces)
                    if s.hasPrefix("\\item") { items.append(String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
                    else if !items.isEmpty && !s.isEmpty && !s.hasPrefix("%") { items[items.count - 1] += " " + s }
                    j += 1
                }
                var hdr: Int? = nil, title = ""
                var k = i - 1
                while k > max(-1, i - 4) {
                    if let g = Re.groups(head, L[k], []) { hdr = k; title = human(g[1] ?? g[2] ?? ""); break }
                    if L[k].trimmingCharacters(in: .whitespaces).hasPrefix("\\end{itemize}") { break }
                    k -= 1
                }
                let n = tpl.sections.count + 1
                tpl.sections.append(.init(id: "s\(n)", title: title.isEmpty ? "Section \(n)" : title, header: hdr, begin: i, end: j,
                                          bullets: items.enumerated().map { .init(id: "\(n).\($0.offset + 1)", raw: $0.element, text: human($0.element)) }))
                i = j
            }
            i += 1
        }
        for (k, l) in L.enumerated() {
            if Re.search("\\\\section\\*?\\{\\s*(summary|profile|about|professional summary)\\s*\\}", l) {
                tpl.summaryLine = ((k + 1)..<min(k + 4, L.count)).first { !L[$0].trimmingCharacters(in: .whitespaces).isEmpty }
            }
            if tpl.headlineLine == nil && k < 40 && l.contains("\\\\[") && l.contains("|") && !l.contains("@") { tpl.headlineLine = k }
        }
        return tpl
    }
}
