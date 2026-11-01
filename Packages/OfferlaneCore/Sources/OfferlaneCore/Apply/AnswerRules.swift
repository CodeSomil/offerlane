import Foundation

/// A form field as the injected autofill script reports it.
public struct FormField: Codable, Hashable, Sendable {
    public var i: Int
    public var type: String
    public var name: String = ""
    public var flabel: String = ""
    public var label: String
    public var group: String = ""
    public var role: String = ""
    public var required: Bool = false
    public var value: String = ""
    public var checked: Bool = false
    public var options: [String]?
    public init(i: Int = 0, type: String, label: String, group: String = "", name: String = "", required: Bool = false, value: String = "", options: [String]? = nil) {
        self.i = i; self.type = type; self.label = label; self.group = group; self.name = name; self.required = required; self.value = value; self.options = options
    }
}

/// Which answer goes in which field. Ported from browser.py (`rules`, `want`, `best_answer`, `pick`).
public enum AnswerRules {
    public static let doneRx = "thank(s| you) for (applying|your application|submitting)|application (has been |was )?(submitted|received)|we('ve| have) received your application|your application is (in|complete)|successfully submitted"
    public static let verifyRx = "verify your (email|account)|verification (email|link|code)|check your (email|inbox)|activate your account"
    public static let humanRx = "captcha|are you a robot|verify you are human|press and hold|unusual traffic"
    public static let consentRx = "consent|agree|privacy|terms|acknowledge|certify|i confirm|i have read"

    /// answers.md → ordered (question, answer) pairs.
    public static func parseAnswers(_ md: String) -> [(String, String)] {
        var out: [(String, String)] = [], key: String?, buf = ""
        func flush() { if let k = key { let a = buf.trimmingCharacters(in: .whitespacesAndNewlines); if !a.isEmpty { out.append((k, a)) } } }
        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix("### ") { flush(); key = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces); buf = "" }
            else if key != nil { buf += line + "\n" }
        }
        flush(); return out
    }

    static let stop: Set<String> = ["the", "and", "you", "your", "are", "for", "with", "this", "what", "why", "how", "have", "please", "our", "that", "would"]
    static func words(_ s: String) -> Set<String> { Set(Re.findAll("[a-z]{3,}", s.lowercased())).subtracting(stop) }

    public static func bestAnswer(_ label: String, _ answers: [(String, String)]) -> String? {
        let lw = words(label); var best: String?, sc = 0.0
        for (q, a) in answers {
            let qw = words(q)
            var s = Double(lw.intersection(qw).count) / Double(max(1, lw.union(qw).count))
            if label.lowercased().contains(q.lowercased()) || q.lowercased().contains(label.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " *?"))) { s = max(s, 0.9) }
            if s > sc { best = a; sc = s }
        }
        if sc >= 0.45 { return best }
        if Re.search("\\bwhy\\b|interested in|motivat|excites? you|attract(s|ed)? you|want to (work|join)", label) {
            return answers.first { Re.search("^why\\b", $0.0) }?.1
        }
        return nil
    }

    public enum Value { case text(String?), fn(@Sendable (String) -> String?) }
    public typealias Rule = (String, Value)

    public static func rules(_ p: Profile, jobLocation loc: String, consent: Bool, visa: Visa) -> [Rule] {
        let ps = p.personal, w = p.work, a = p.authorization, e = p.eeo, ed = p.education, m = p.misc
        func yn(_ b: Bool) -> String { b ? "Yes" : "No" }
        func opt(_ s: String) -> String? { s.isEmpty ? nil : s }
        let phone = ps.phone
        let cc = Re.groups("^\\+\\d{1,3}", phone, [])?.first ?? nil
        let needs = a.needsSponsorship
        return [
            ("first name|given name|preferred first", .text(ps.firstName)), ("last name|surname|family name", .text(ps.lastName)),
            ("^(full )?name\\b|your name|legal name", .text(ps.fullName)), ("e-?mail", .text(ps.email)),
            ("country code|phone code", .text(cc)), ("phone device|device type", .text("Mobile")),
            ("phone number|local number", .text(Re.sub("^\\+\\d{1,3}[\\s-]*", "", phone))), ("phone|mobile", .text(phone)),
            ("linkedin", .text(opt(ps.linkedin))), ("github", .text(opt(ps.github))), ("website|portfolio|personal (site|url)", .text(opt(ps.portfolio))),
            ("bound by|non-?compete|restrictive covenant", .text(nil)),
            ("(ever|previously|currently).{0,40}(employed|worked) (by|for|at)|former employee|previously worked", .text("No")),
            ("whatsapp|sms|text message", .text(nil)),
            ("sponsor|visa", .fn { L in yn(needs && !visa.authorizedFor(loc, label: L)) }),
            ("(legally )?(authori[sz]ed|eligible|right) to work|work authori[sz]ation|work permit", .fn { L in yn(visa.authorizedFor(loc, label: L)) }),
            ("relocat", .text(yn(w.willingToRelocate))), ("remote", .text(yn(w.openToRemote))),
            ("employer|current (company|organi[sz]ation)|most recent company|^company( name)?\\W*$", .text(w.currentCompany)),
            ("job title|current (title|role|position)|recent title", .text(w.currentTitle)),
            ("years? of (relevant |professional |total )?experience|how many years", .text(opt(w.yearsExperience))),
            ("notice period", .text(w.noticePeriod)), ("start date|when can you start|earliest", .text(m.startDate)),
            ("current (ctc|salary|compensation|pay)", .text(opt(w.currentSalary))),
            ("expected (ctc|salary|compensation|pay)|salary expectation|desired (salary|compensation|pay)|compensation expectation", .text(opt(w.expectedSalary))),
            ("how did you (hear|find|learn)|^source", .text(m.howHeard.isEmpty ? "Company website" : m.howHeard)),
            ("address line ?1|street", .text(opt(ps.address))), ("\\bcity\\b", .text(ps.city)), ("state|province|region", .text(opt(ps.state))),
            ("postal|zip", .text(opt(ps.postalCode))),
            ("location|where are you (based|located)", .text([ps.city, ps.state, ps.country].filter { !$0.isEmpty }.joined(separator: ", "))),
            ("country", .text(ps.country)), ("school|university|college|institution", .text(ed.school)), ("degree", .text(ed.degree)),
            ("graduat", .text(opt(ed.graduationYear))),
            ("gender", .text(e.gender)), ("veteran", .text(e.veteran)), ("disabilit", .text(e.disability)), ("race|ethnic|hispanic|latino", .text(e.race)),
            ("sexual orientation", .text(e.sexualOrientation)), ("pronoun", .text(opt(m.pronouns))), ("citizenship|nationality", .text(a.citizenship)),
            (consentRx, .text(consent ? "Yes" : nil)),
        ]
    }

    /// The value for a field (nil = leave it) and the label it was matched on.
    public static func want(_ f: FormField, _ R: [Rule], _ answers: [(String, String)]) -> (String?, String) {
        let L = (f.group.isEmpty ? (f.label.isEmpty ? f.name : f.label) : f.group).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !L.isEmpty else { return (nil, "") }
        if f.type == "textarea" || L.count > 70 {
            if Re.search("cover letter", L) { return (answers.first { $0.0 == "Cover letter" }?.1 ?? bestAnswer("cover letter", answers), L) }
            let a = bestAnswer(L, answers)
            if a != nil || f.type == "textarea" { return (a, L) }
        }
        for (rx, v) in R where Re.search(rx, L) {
            switch v {
            case .text(let s): return (s, L)
            case .fn(let f): return (f(L.lowercased()), L)
            }
        }
        return (bestAnswer(L, answers), L)
    }

    /// The option matching a value: exact, prefix, contains, decline-style, yes/no, first comma part.
    public static func pick(_ options: [String], _ value: String?) -> String? {
        let v = (value ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        let O = options.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !Re.search("^(select|choose|--|please)", $0.trimmingCharacters(in: .whitespaces)) }
        let tests: [(String) -> Bool] = [
            { $0.lowercased() == v }, { $0.lowercased().hasPrefix(v) }, { $0.lowercased().contains(v) },
            { o in v.hasPrefix("decline") && Re.search("decline|prefer not|don.t wish|not to (say|disclose)|do not wish", o) },
            { o in v.hasPrefix("no") && Re.search("^no\\b", o) }, { o in v.hasPrefix("yes") && Re.search("^(yes\\b|i agree|i consent)", o) },
            { o in v.count > 3 && o.lowercased().contains(v.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? v) },
        ]
        for t in tests { if let o = O.first(where: t) { return o } }
        return nil
    }

    /// Normalise a posting URL to the page with the form (ported from form_url).
    public static func formURL(_ j: Job) -> String {
        let u = j.applyUrl.isEmpty ? j.url : j.applyUrl
        let base = u.split(separator: "?").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? u
        switch j.ats {
        case "lever" where !base.hasSuffix("/apply"): return base + "/apply"
        case "ashby" where !base.hasSuffix("/application"): return base + "/application"
        case "workable" where !base.hasSuffix("/apply"): return base + "/apply/"
        case "greenhouse":
            let id = Re.first("gh_jid=(\\d+)", u) ?? Re.first("token=(\\d+)", u) ?? Re.first("/jobs?[/.](\\d{5,})", u)
            let slug = j.atsSlug.isEmpty ? Re.first("greenhouse\\.io/(?!embed)([\\w-]+)/jobs", u) : j.atsSlug
            if let id, let slug { return "https://job-boards.greenhouse.io/embed/job_app?for=\(slug)&token=\(id)" }
            return u
        default: return u
        }
    }
}
