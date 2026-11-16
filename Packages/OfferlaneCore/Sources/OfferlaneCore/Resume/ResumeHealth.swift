import Foundation

/// Resume health for one version (and optionally one role): deterministic checks, no AI call.
/// Findings cite the resume's own bullet ids; missing skills come only from the lexicon and are never added for the user.
public struct ResumeHealth: Codable, Hashable, Sendable {
    public struct Check: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var pass: Bool
        public var detail: String
        public var weight: Int
        /// Bullets this finding is about (ids from the resume).
        public var bulletIds: [String] = []
    }
    /// Passed weight ÷ total weight, 0...100; keyword coverage counts in proportion.
    public var score: Int
    public var checks: [Check]
    public var role: String?
    public var postings: Int
    /// Most-asked skills for the role that an ATS can read in the PDF / cannot find.
    public var readable: [String]
    public var missing: [String]

    static let topSkills = 10, longBullet = 35

    public static func check(_ r: ResumeContent, pdf: Data, scan: MarketScan? = nil, lexicon: SkillLexicon = .bundled) -> ResumeHealth {
        let text = ResumePDF.text(pdf)
        let ats = Builder.atsCheck(pdf, keywords: [], name: r.name).0
        let atsPass = ats.hasPrefix("PASS")
        let bullets = r.sections.flatMap(\.bullets)
        let noNumber = bullets.filter { !Re.search("\\d", $0.text) }
        let long = bullets.filter { $0.text.split(whereSeparator: \.isWhitespace).count > longBullet }
        let withNumbers = bullets.count - noNumber.count
        var checks = [
            Check(id: "ats", title: "Readable by applicant tracking systems", pass: atsPass,
                  detail: atsPass ? "Name, email and text can be read from the PDF." : (ats.components(separatedBy: " (").first ?? ats), weight: 30),
            Check(id: "contact", title: "Contact details", pass: !r.email.isEmpty && !r.phone.isEmpty,
                  detail: r.email.isEmpty ? "Add your email." : r.phone.isEmpty ? "Add a phone number." : "Email and phone are present.", weight: 10),
            Check(id: "experience", title: "Experience with bullets", pass: r.experience.contains { !$0.bullets.isEmpty },
                  detail: r.experience.isEmpty ? "No experience section was found." : "\(r.experience.count) role\(r.experience.count == 1 ? "" : "s"), \(bullets.count) bullets.", weight: 10),
            Check(id: "skills", title: "Skills section", pass: !r.skills.isEmpty,
                  detail: r.skills.isEmpty ? "Add a skills section so keyword searches find you." : "Present.", weight: 5),
            Check(id: "impact", title: "Results in bullets", pass: !bullets.isEmpty && withNumbers * 10 >= bullets.count * 4,
                  detail: "\(withNumbers) of \(bullets.count) bullets show a measurable result."
                    + (noNumber.isEmpty ? "" : " If you have a real figure for the bullets below, add it; don't estimate."),
                  weight: 15, bulletIds: Array(noNumber.prefix(3).map(\.id))),
            Check(id: "length", title: "Bullet length", pass: long.isEmpty,
                  detail: long.isEmpty ? "Every bullet is \(longBullet) words or fewer." : "\(long.count) bullet\(long.count == 1 ? " is" : "s are") over \(longBullet) words; shorten to one idea each.",
                  weight: 10, bulletIds: long.map(\.id)),
        ]
        var readable: [String] = [], missing: [String] = []
        var keywordShare = 0.0
        if let scan, scan.postings > 0 {
            let inPDF = lexicon.matches(text)
            for d in scan.demand.prefix(topSkills) { if inPDF.contains(d.id) { readable.append(d.name) } else { missing.append(d.name) } }
            let total = readable.count + missing.count
            keywordShare = total == 0 ? 1 : Double(readable.count) / Double(total)
            checks.append(Check(id: "keywords", title: "Keywords for \(scan.role)", pass: keywordShare >= 0.6,
                                detail: "\(readable.count) of \(total) most-asked skills are readable in this resume."
                                    + (missing.isEmpty ? "" : " Add the missing ones only if you really have them."), weight: 20))
        }
        let total = checks.reduce(0) { $0 + $1.weight }
        let got = checks.reduce(0.0) { $0 + ($1.id == "keywords" ? keywordShare : $1.pass ? 1 : 0) * Double($1.weight) }
        return ResumeHealth(score: total == 0 ? 0 : Int((got / Double(total) * 100).rounded()), checks: checks,
                            role: scan?.role, postings: scan?.postings ?? 0, readable: readable, missing: missing)
    }
}
