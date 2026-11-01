import Foundation
import CryptoKit

public enum Text {
    /// Lowercase, non-alphanumerics collapsed to single spaces.
    public static func norm(_ s: String?) -> String {
        Re.sub("[^a-z0-9]+", " ", (s ?? "").lowercased()).trimmingCharacters(in: .whitespaces)
    }

    /// Filesystem-safe fragment, max 40 characters.
    public static func slug(_ s: String?) -> String {
        let x = Re.sub("[^A-Za-z0-9]+", "_", s ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String(x.prefix(40))
    }

    public static func collapse(_ s: String) -> String {
        Re.sub("\\s+", " ", s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip tags after unescaping entities twice (ATS APIs often double-escape their HTML).
    public static func stripHTML(_ s: String?) -> String {
        collapse(Re.sub("<[^>]+>", " ", unescapeHTML(unescapeHTML(s ?? ""))))
    }

    public static func unescapeHTML(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&apos;": "'", "&nbsp;": " "] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        out = Re.sub("&#(\\d+);", out) { g in
            guard let n = UInt32(g[1] ?? ""), let u = Unicode.Scalar(n) else { return g[0] ?? "" }
            return String(Character(u))
        }
        out = Re.sub("&#x([0-9a-fA-F]+);", out) { g in
            guard let n = UInt32(g[1] ?? "", radix: 16), let u = Unicode.Scalar(n) else { return g[0] ?? "" }
            return String(Character(u))
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The fingerprint that de-duplicates postings and keeps declined roles from resurfacing:
    /// sha1(company | title | first word of location)[:12], identical to the prototype's `job_id`.
    public static func jobID(company: String, title: String, location: String?) -> String {
        let loc = (location ?? "").isEmpty ? "" : (norm(location).split(separator: " ").first.map(String.init) ?? "")
        let key = "\(norm(company))|\(norm(title))|\(loc)"
        return Insecure.SHA1.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// Search patterns: plain phrases match as case-insensitive substrings; `re:` entries are regular expressions.
    public static func patternHit(_ p: String, _ text: String) -> Bool {
        if p.hasPrefix("re:") {
            guard Re.compile(String(p.dropFirst(3)), [.caseInsensitive]) != nil else { return false }
            return Re.search(String(p.dropFirst(3)), text)
        }
        return text.lowercased().contains(p.lowercased())
    }
}

public enum Dates {
    static let isoDay: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"; return f
    }()
    public static let isoSeconds: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f
    }()

    public static func today(_ now: Date = Date()) -> String { isoDay.string(from: now) }
    public static func now(_ d: Date = Date()) -> String { isoSeconds.string(from: d) }
    public static func day(_ iso: String?) -> Date? {
        guard let iso, iso.count >= 10 else { return nil }
        return isoDay.date(from: String(iso.prefix(10)))
    }
    /// Days since an ISO date; unknown dates count as 0 (the prototype's behaviour: undated postings aren't filtered out).
    public static func ageDays(_ iso: String?, now: Date = Date()) -> Int {
        guard let d = day(iso) else { return 0 }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: d, to: isoDay.date(from: today(now))!).day ?? 0
    }
    public static func daysAgo(_ n: Int, now: Date = Date()) -> String {
        today(Calendar(identifier: .gregorian).date(byAdding: .day, value: -n, to: now)!)
    }
    /// Epoch seconds or milliseconds, or any string starting with an ISO date.
    public static func toDate(_ v: Any?) -> String? {
        switch v {
        case let n as Double: return today(Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n))
        case let n as Int: return toDate(Double(n))
        case let s as String where !s.isEmpty: return String(s.prefix(10))
        default: return nil
        }
    }
}
