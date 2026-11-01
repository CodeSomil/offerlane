import Foundation

/// Python-`re`-style helpers over NSRegularExpression (ICU syntax, which accepts the prototype's patterns).
/// Patterns are compiled once and cached; flags default to case-insensitive where the prototype used `re.I`.
public enum Re {
    private static let cache = NSCache<NSString, NSRegularExpression>()
    private static let lock = NSLock()

    public static func compile(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)" as NSString
        lock.lock(); defer { lock.unlock() }
        if let r = cache.object(forKey: key) { return r }
        guard let r = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        cache.setObject(r, forKey: key); return r
    }

    /// True if `pattern` matches anywhere in `s`.
    public static func search(_ pattern: String, _ s: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> Bool {
        guard let r = compile(pattern, options) else { return false }
        return r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Capture groups of the first match (index 0 = whole match); nil groups become nil.
    public static func groups(_ pattern: String, _ s: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> [String?]? {
        guard let r = compile(pattern, options), let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
    }

    /// First capture group (or the whole match when the pattern has no groups).
    public static func first(_ pattern: String, _ s: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> String? {
        guard let g = groups(pattern, s, options) else { return nil }
        return g.count > 1 ? g[1] : g[0]
    }

    /// Like Python `re.findall`: the first group of every match if the pattern has groups, else the whole match.
    public static func findAll(_ pattern: String, _ s: String, _ options: NSRegularExpression.Options = []) -> [String] {
        guard let r = compile(pattern, options) else { return [] }
        return r.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            let i = m.numberOfRanges > 1 ? 1 : 0
            return Range(m.range(at: i), in: s).map { String(s[$0]) }
        }
    }

    /// Like Python `re.sub` with an NSRegularExpression template (`$1`, not `\1`).
    public static func sub(_ pattern: String, _ template: String, _ s: String, _ options: NSRegularExpression.Options = []) -> String {
        guard let r = compile(pattern, options) else { return s }
        return r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// `re.sub` with a closure that receives the capture groups of each match.
    public static func sub(_ pattern: String, _ s: String, _ options: NSRegularExpression.Options = [], with f: ([String?]) -> String) -> String {
        guard let r = compile(pattern, options) else { return s }
        var out = "", last = s.startIndex
        for m in r.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let whole = Range(m.range, in: s) else { continue }
            out += s[last..<whole.lowerBound]
            out += f((0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } })
            last = whole.upperBound
        }
        return out + s[last...]
    }

    /// Like Python `re.split`.
    public static func split(_ pattern: String, _ s: String, _ options: NSRegularExpression.Options = []) -> [String] {
        guard let r = compile(pattern, options) else { return [s] }
        var out: [String] = [], last = s.startIndex
        for m in r.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let whole = Range(m.range, in: s) else { continue }
            out.append(String(s[last..<whole.lowerBound])); last = whole.upperBound
        }
        out.append(String(s[last...])); return out
    }

    public static func escape(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }
}
