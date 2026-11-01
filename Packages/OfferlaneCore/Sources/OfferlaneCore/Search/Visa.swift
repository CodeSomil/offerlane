import Foundation

/// Work-authorization realism for each posting (no LLM): the user's authorized countries, the JD's sponsorship
/// wording, and the free UK / Netherlands government sponsor registers. Ported from visa.py.
public struct Visa: Sendable {
    public static let countries: [(String, String)] = [
        ("india", "india|bengaluru|bangalore|mumbai|pune|hyderabad|delhi|gurgaon|gurugram|noida|chennai|kolkata|ahmedabad"),
        ("united states", "united states|\\busa?\\b|america|new york|san francisco|seattle|austin|boston|chicago|los angeles|menlo park|palo alto|mountain view|sunnyvale|bellevue|, (ca|ny|wa|tx|ma|il|co|ga|nc|va)\\b"),
        ("united kingdom", "united kingdom|\\buk\\b|england|london|manchester|edinburgh|cambridge|scotland"),
        ("netherlands", "netherlands|amsterdam|rotterdam|utrecht|eindhoven"), ("germany", "germany|berlin|munich|hamburg|frankfurt"),
        ("ireland", "ireland|dublin"), ("canada", "canada|toronto|vancouver|montreal"), ("singapore", "singapore"),
        ("united arab emirates", "\\buae\\b|dubai|abu dhabi|united arab emirates"), ("australia", "australia|sydney|melbourne"),
        ("france", "france|paris"), ("spain", "spain|madrid|barcelona"), ("switzerland", "switzerland|zurich|geneva"),
    ]
    static let countryRx = Dictionary(uniqueKeysWithValues: countries)
    static let easy: Set<String> = ["germany", "ireland", "singapore", "united arab emirates", "canada", "netherlands"]
    static let neg = "(unable|not able|cannot|can't|do not|does not|won't|will not)\\s+(to\\s+)?(provide\\s+)?sponsor|no (visa )?sponsorship|without (the need for )?(visa )?sponsorship|must (already )?have (the )?(full )?right to work"
    static let pos = "visa sponsorship (is )?(available|provided|offered)|(we|will|can) (offer|provide)?\\s*(visa )?sponsor|sponsorship (is )?available|relocation (support|assistance|package)"
    static let suffix = "\\b(ltd|limited|inc|llc|plc|b ?v|n ?v|gmbh|ag|sa|corp(oration)?|co|company|holdings?|group|technolog(y|ies)|services|solutions|software|india|uk|europe|international|the|pvt|private)\\b"
    public static let alias: [String: String] = [
        "uk": "united kingdom", "u.k.": "united kingdom", "england": "united kingdom", "britain": "united kingdom", "great britain": "united kingdom",
        "scotland": "united kingdom", "wales": "united kingdom", "us": "united states", "u.s.": "united states", "usa": "united states",
        "america": "united states", "united states of america": "united states", "uae": "united arab emirates", "emirates": "united arab emirates",
        "holland": "netherlands", "the netherlands": "netherlands",
    ]

    public let authorized: [String]
    public let needsSponsorship: Bool
    let registers: [String: [String]]

    public init(profile: Profile, sponsorsDir: URL = Paths.sponsors) {
        authorized = profile.authorization.authorizedCountries.map(Self.canon)
        needsSponsorship = profile.authorization.needsSponsorship
        var regs: [String: [String]] = [:]
        if needsSponsorship {
            for k in ["uk", "nl"] {
                let txt = (try? String(contentsOf: sponsorsDir.appendingPathComponent("\(k).txt"), encoding: .utf8)) ?? ""
                regs[k] = txt.split(separator: "\n").map(String.init).sorted()
            }
        }
        registers = regs
    }

    public static func canon(_ c: String) -> String {
        let x = c.trimmingCharacters(in: .whitespaces).lowercased(); return alias[x] ?? x
    }
    /// "London, UK" -> ["united kingdom"]
    public static func countriesIn(_ loc: String) -> [String] {
        let l = loc.lowercased(); return countries.filter { Re.search($0.1, l, []) }.map(\.0)
    }
    /// Is the user allowed to work where this job is? `label` lets a form question name the country itself.
    public func authorizedFor(_ loc: String, label: String = "") -> Bool {
        let hay = (loc + " " + label).lowercased()
        return authorized.contains { Re.search(Self.countryRx[$0] ?? Re.escape($0), hay, []) }
    }

    public static func nname(_ s: String) -> String {
        Text.collapse(Re.sub(suffix, " ", Re.sub("[^a-z0-9 ]", " ", s.lowercased())))
    }
    func inRegister(_ company: String, _ k: String) -> Bool {
        let n = Self.nname(company)
        guard !n.isEmpty, let reg = registers[k], !reg.isEmpty else { return false }
        // Binary search for n, or any entry starting with "n ".
        var lo = 0, hi = reg.count
        while lo < hi { let mid = (lo + hi) / 2; if reg[mid] < n { lo = mid + 1 } else { hi = mid } }
        if lo < reg.count && (reg[lo] == n || reg[lo].hasPrefix(n + " ")) { return true }
        return lo + 1 < reg.count && reg[lo + 1].hasPrefix(n + " ")
    }

    /// ok | remote | no-sponsorship | sponsors | sponsor-register | h1b-lottery | likely | unknown
    public func tag(company: String, location: String, description: String) -> String {
        let cs = Self.countriesIn(location)
        if authorizedFor(location) { return "ok" }
        if cs.isEmpty && Re.search("remote|anywhere", location) { return "remote" }
        if !needsSponsorship { return "ok" }
        if Re.search(Self.neg, description) { return "no-sponsorship" }
        if Re.search(Self.pos, description) { return "sponsors" }
        if (cs.contains("united kingdom") && inRegister(company, "uk")) || (cs.contains("netherlands") && inRegister(company, "nl")) { return "sponsor-register" }
        if cs.contains("united states") { return "h1b-lottery" }
        if !Set(cs).isDisjoint(with: Self.easy) { return "likely" }
        return "unknown"
    }

    public static func label(_ tag: String) -> String {
        switch tag {
        case "ok": "Authorized"
        case "remote": "Remote"
        case "no-sponsorship": "No sponsorship"
        case "sponsors": "Sponsors visas"
        case "sponsor-register": "On sponsor register"
        case "h1b-lottery": "H-1B lottery"
        case "likely": "Sponsorship likely"
        default: "Visa unknown"
        }
    }
}
