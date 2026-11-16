import Foundation

/// A pay range a posting states itself ("$120,000 - $150,000", "£60k to £75k a year", "$45–$60/hr", "€45.000 - €60.000", "₹12 - 18 LPA", "£400 - £550 per day").
public struct PayRange: Codable, Hashable, Sendable {
    public enum Period: String, Codable, Sendable {
        case year, month, day, hour
        public var per: String { self == .hour ? " an hour" : " a \(rawValue)" }
    }
    public var currency: String
    public var low: Double
    public var high: Double
    public var period: Period

    static let currency = "(CA\\$|AU\\$|US\\$|C\\$|A\\$|USD|GBP|EUR|INR|CAD|AUD|[$£€₹])"
    static let symbol = ["CA$": "C$", "AU$": "A$", "US$": "$", "USD": "$", "GBP": "£", "EUR": "€", "INR": "₹", "CAD": "C$", "AUD": "A$"]
    /// 120,000 / 12,00,000 (Indian grouping) / 45.000 (dot thousands) / 45.5, then k, lakh (L, LPA) or crore, maybe glued "pa"; a unit
    /// followed by a letter or digit isn't one ("$60 Kids", "L5"). ASCII digits only, as JS `\d` is.
    static let amount = "([0-9]{1,3}(?:,[0-9]{2})*(?:,[0-9]{3})+|[0-9]{1,3}(?:\\.[0-9]{3})+(?![0-9])|[0-9]+(?:\\.[0-9]+)?)(?:\\s?([kK]|[lL]akhs?|LPA|lpa|L|[cC]r(?:ores?)?)(?:pa|[A-Z]{3})?(?![A-Za-z0-9]))?"
    static let pattern = "\(currency)\\s?\(amount)\\s*(?:-|–|—|to)\\s*(?:[A-Z]{3}\\s?)?(?:CA\\$|AU\\$|US\\$|C\\$|A\\$|[$£€₹])?\\s?\(amount)"

    /// Every range in `text` that passes the sanity bounds; anything else (funding, bonus amounts, a single figure) is ignored.
    // SHORTCUT: a symbol after the number ("45.000 €") and space thousands ("45 000") aren't read; add them if European postings miss pay.
    public static func parse(_ text: String) -> [PayRange] {
        guard let rx = Re.compile(pattern) else { return [] }
        return rx.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            func g(_ i: Int) -> String? { Range(m.range(at: i), in: text).map { String(text[$0]) } }
            guard let cur = g(1), let a = g(2).flatMap(number), let b = g(4).flatMap(number) else { return nil }
            let sym = symbol[cur] ?? cur
            let ua = g(3).map { unit($0, sym) }, ub = g(5).map { unit($0, sym) }
            let low = a * (ua ?? (a < 1000 ? ub ?? 1 : 1)), high = b * (ub ?? 1) // "$120-150k", "₹12 - 18 LPA"
            let after = Range(m.range, in: text).map { String(text[$0.upperBound...].prefix(25)) } ?? ""
            // The period word must be on the same line; a figure only a year fits stays a year ("$120k - $150k a day-one start").
            let said: Period = Re.search("^[ \\t]*(/\\s?h(ou)?r|per hour|an hour|hourly)", after) ? .hour
                : Re.search("^[ \\t]*(/\\s?day|per day|a day|daily)", after) ? .day
                : Re.search("^[ \\t]*(/\\s?mo(nth)?|per month|a month|monthly|p\\.?m\\.?(?![a-z]))", after) ? .month : .year
            func fits(_ p: Period) -> Bool { let (lo, hi) = bounds(p, sym); return (lo...hi).contains(low) }
            let period: Period = said != .year && !fits(said) && fits(.year) ? .year : said
            let ok = low <= high && high <= low * 3 && fits(period)
            return ok ? PayRange(currency: sym, low: low, high: high, period: period) : nil
        }
    }
    /// Plausible lowest figure per period; rupee figures run about 10–50× higher.
    static func bounds(_ p: Period, _ cur: String) -> (Double, Double) {
        let (lo, hi): (Double, Double) = switch p { case .year: (10_000, 2_000_000); case .month: (500, 30_000); case .day: (50, 5_000); case .hour: (7, 500) }
        return cur == "₹" ? (lo * 10, hi * 50) : (lo, hi)
    }
    /// Lakh and crore are rupee units only ("$150,000 - $180,000 L role").
    static func unit(_ s: String, _ cur: String) -> Double { switch s.lowercased().first { case "k": 1e3; case "c": cur == "₹" ? 1e7 : 1; default: cur == "₹" ? 1e5 : 1 } }
    static func number(_ s: String) -> Double? {
        Double((Re.search("^[0-9]{1,3}(\\.[0-9]{3})+$", s) ? s.replacingOccurrences(of: ".", with: "") : s).replacingOccurrences(of: ",", with: ""))
    }
}

/// What the saved postings for one role state, per currency and period. Not a market survey.
public struct PayBand: Hashable, Sendable, Identifiable {
    public var currency: String
    public var period: PayRange.Period
    public var low: Double, median: Double, high: Double
    public var jobIds: [String]
    public var id: String { currency + period.rawValue }
    public var label: String { "\(Offers.money(low, currency))–\(Offers.money(high, currency))" + period.per }
}

/// One offer the user typed in. Equity is the user's own per-year estimate.
public struct Offer: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID().uuidString
    public var jobId = ""
    public var company = "", title = "", location = ""
    public var currency = "$"
    public var base = 0.0, bonus = 0.0, equityPerYear = 0.0, signOn = 0.0
    public var notes = ""
    public init() {}
    public var yearly: Double { base + bonus + equityPerYear }
    public var firstYear: Double { yearly + signOn }
}

public struct OfferRow: Hashable, Sendable, Identifiable {
    public var offer: Offer
    public var band: PayBand?
    /// "below" | "within" | "above" the posted yearly range, nil without one.
    public var position: String?
    public var visa: String
    public var id: String { offer.id }
}

public struct NegotiationScript: Hashable, Sendable {
    public var body: String
    public var warnings: [String] = []
    public var note: String?
}

/// Salary and offer tools. Ranges come only from postings; offers only from the user. Nothing here sends a message.
public enum Offers {
    public static func bands(jobs: [Job], role: String) -> [PayBand] {
        // One range per posting so a posting listing many cities can't dominate.
        let found = MarketScan.relevant(jobs, role: role).compactMap { j in PayRange.parse(j.description).first.map { (j.id, $0) } }
        return Dictionary(grouping: found) { $0.1.currency + $0.1.period.rawValue }.values.map { xs in
            let mids = xs.map { ($0.1.low + $0.1.high) / 2 }.sorted()
            let median = mids.count % 2 == 1 ? mids[mids.count / 2] : (mids[mids.count / 2 - 1] + mids[mids.count / 2]) / 2
            return PayBand(currency: xs[0].1.currency, period: xs[0].1.period, low: xs.map(\.1.low).min()!, median: median,
                           high: xs.map(\.1.high).max()!, jobIds: xs.map(\.0))
        }.sorted { ($0.jobIds.count, $0.id) > ($1.jobIds.count, $1.id) }
    }

    public static func compare(_ offers: [Offer], jobs: [Job], visa: Visa) -> [OfferRow] {
        let byId = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return offers.map { o in
            let band = bands(jobs: jobs, role: o.title).first { $0.currency == o.currency && $0.period == .year }
            let position = band.map { o.base < $0.low ? "below" : o.base > $0.high ? "above" : "within" }
            let tag = byId[o.jobId].map(\.visa).flatMap { $0.isEmpty ? nil : $0 }
                ?? visa.tag(company: o.company, location: o.location, description: byId[o.jobId]?.description ?? "")
            return OfferRow(offer: o, band: band, position: o.base > 0 ? position : nil, visa: tag)
        }.sorted { $0.offer.firstYear > $1.offer.firstYear }
    }

    /// Roles at the Offer stage that have no offer entered yet, ready to fill in.
    public static func drafts(jobs: [Job], existing: [Offer]) -> [Offer] {
        let have = Set(existing.map(\.jobId))
        return jobs.filter { $0.status == .offer && !have.contains($0.id) }.map { j in
            var o = Offer(); o.jobId = j.id; o.company = j.company; o.title = j.title; o.location = j.location; return o
        }
    }

    public static func money(_ v: Double, _ cur: String) -> String { cur + v.formatted(.number.precision(.fractionLength(0...2))) }
    /// Tags where the user still has to ask about sponsorship.
    static func asksSponsorship(_ tag: String) -> Bool { !["ok", "remote", ""].contains(tag) }

    /// Everything a script may draw numbers from. "120,000 (120k)" so either way of writing it passes the guard.
    static func facts(_ row: OfferRow, expected: String) -> String {
        let o = row.offer
        func line(_ name: String, _ v: Double) -> String? { v > 0 ? "\(name): \(money(v, o.currency)) (\((v / 1000).formatted(.number.precision(.fractionLength(0...1))))k)" : nil }
        var lines = ["OFFER: \(o.title) at \(o.company) \(o.location)"]
        lines += [line("Base", o.base), line("Bonus", o.bonus), line("Equity per year", o.equityPerYear), line("Sign-on", o.signOn)].compactMap { $0 }
        if let b = row.band {
            lines.append("POSTED RANGE for similar saved roles (\(b.jobIds.count) postings): \(b.label)")
            lines += [line("Posted low", b.low), line("Posted median", b.median), line("Posted high", b.high)].compactMap { $0 }
        }
        if !expected.isEmpty { lines.append("EXPECTED SALARY: \(expected)") }
        lines.append("VISA: \(Visa.label(row.visa))")
        return lines.joined(separator: "\n")
    }

    /// One cached AI call per offer; a number or link the facts lack, or a guessed name, falls back to the template.
    public static func script(_ row: OfferRow, expected: String, name: String, ai: AI?) async -> NegotiationScript {
        let fallback = template(row, expected: expected, name: name)
        guard let ai else { return NegotiationScript(body: fallback, note: "No AI is connected, so this is a plain template. Edit it, or connect an AI.") }
        let source = facts(row, expected: expected)
        let prompt = """
        Draft a salary negotiation reply to a job offer. Polite, confident, under 160 words. Use ONLY numbers in the FACTS; never invent figures, \
        competing offers or links. \(asksSponsorship(row.visa) ? "Ask the employer to confirm visa sponsorship. " : "")\
        Greet the person as "\(Networking.placeholder)" and sign as \(name.isEmpty ? "[Your name]" : name). Return JSON {"body":"..."}.
        FACTS:
        \(source)
        """
        struct D: Decodable { var body: String? }
        do {
            let d = try await ai.cachedJSON(LLMRequest(prompt: prompt, maxTokens: 500), key: ai.cacheKey("negotiate-v1", [source, name]), kind: "negotiate", as: D.self)
            let body = (d.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return NegotiationScript(body: fallback, note: "The AI returned an empty script, so this is a plain template.") }
            let g = Guard.check(body, source: source + "\n" + name)
            guard g.ok, SkillPlanner.noLinks(body), !Networking.guessesName(body) else {
                return NegotiationScript(body: fallback, note: "The AI's script used figures or facts you didn't enter, so this is a plain template.")
            }
            return NegotiationScript(body: body, warnings: g.warnings)
        } catch {
            return NegotiationScript(body: fallback, note: "The AI couldn't draft this (\(error.localizedDescription)). Here is a plain template instead.")
        }
    }

    public static func template(_ row: OfferRow, expected: String, name: String) -> String {
        let o = row.offer
        var parts = ["Hi \(Networking.placeholder),", "Thank you for the offer for the \(o.title) role at \(o.company). I'm excited about the team and the work."]
        if let b = row.band, o.base > 0, o.base < b.high {
            parts.append("Similar roles I've seen posted list \(b.label). Is there room to bring the base salary closer to \(money(b.high, o.currency))?")
        } else if !expected.isEmpty {
            parts.append("I was hoping for a base salary closer to \(expected). Is there flexibility there?")
        } else {
            parts.append("Is there flexibility on the base salary or the sign-on bonus?")
        }
        if asksSponsorship(row.visa) { parts.append("Could you also confirm that the company will sponsor my work visa and cover the related costs?") }
        parts.append("Thanks,\n" + (name.isEmpty ? "[Your name]" : name))
        return parts.joined(separator: "\n\n")
    }
}
