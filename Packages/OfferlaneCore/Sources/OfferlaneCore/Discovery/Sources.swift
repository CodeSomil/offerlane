import Foundation

/// A job source beyond the user's watchlist boards: a free public jobs API. Terms are verified per source (docs/SOURCES.md).
public protocol JobSource: Sendable {
    var id: String { get }
    /// Shown on each result ("via Remotive"); some terms require naming the source.
    var name: String { get }
    /// One line for the source switch in Settings.
    var terms: String { get }
    /// Least time between two fetches, from the source's published limits.
    var minInterval: TimeInterval { get }
    var defaultOn: Bool { get }
    /// False while the source can't run yet (e.g. no key saved): it's skipped, not reported as unreachable.
    var ready: Bool { get }
    func fetch(_ queries: [SearchQuery], http: HTTP) async -> SourceResult
}

public extension JobSource { var ready: Bool { true } }

public enum SourceResult: Sendable {
    case jobs([Job])
    case rateLimited
    case unreachable
    /// The source answered but refused us (e.g. a wrong key); the message says what to fix.
    case refused(String)
}

public enum JobSources {
    /// Every source the app offers, for names and switches (Adzuna here has no key). Unverified ones (Arbeitnow,
    /// The Muse) are not listed; see docs/SOURCES.md. JobSpy is excluded: it scrapes sites whose terms forbid it.
    public static let all: [any JobSource] = [Remotive(), Adzuna(keys: nil, country: "us")]

    /// The sources for a run, with the user's keys from the profile Keychain.
    public static func configured(keychain: Keychain, search: SearchConfig) -> [any JobSource] {
        [Remotive(), Adzuna(keychain: keychain, search: search)]
    }

    public static func enabled(_ search: SearchConfig, from list: [any JobSource] = all) -> [any JobSource] {
        list.filter { $0.ready && (search.sources[$0.id] ?? $0.defaultOn) }
    }
}

/// Remotive's public remote-jobs API. Terms (README): link back to the Remotive URL and name Remotive as the source;
/// more than 2 requests a minute is blocked, at most ~4 a day is asked. So: one request per run, at most every 6 hours.
public struct Remotive: JobSource {
    public let id = "remotive", name = "Remotive"
    public let terms = "Free remote jobs (24 h delayed). Each result links to Remotive. Checked at most every 6 hours."
    public let minInterval: TimeInterval = 6 * 3600
    public let defaultOn = true
    static let url = URL(string: "https://remotive.com/api/remote-jobs")!
    public init() {}

    // The whole feed in one request; keyword queries would cost one request each, and the local filter does that job free.
    public func fetch(_ queries: [SearchQuery], http: HTTP) async -> SourceResult {
        guard let r = await http.get(Self.url) else { return .unreachable }
        if r.status == 429 { return .rateLimited }
        guard r.status == 200, let j = r.json else { return .unreachable }
        return .jobs(Self.parse(j))
    }

    public static func parse(_ j: JSONValue) -> [Job] {
        (j["jobs"]?.array ?? []).compactMap { x in
            let s = { (k: String) in x[k]?.string ?? "" }
            guard !s("title").isEmpty, !s("company_name").isEmpty else { return nil }
            var job = Job(company: s("company_name"), title: s("title"), location: s("candidate_required_location"), url: s("url"))
            if !job.location.lowercased().contains("remote") { job.location = job.location.isEmpty ? "Remote" : "Remote (\(job.location))" }
            job.posted = Dates.toDate(x["publication_date"]?.string); job.description = Text.stripHTML(x["description"]?.string)
            // The employer's own posting, when the ad links to it: the apply step and the board registry use it.
            job.applyUrl = Careers.boardLink(in: s("description")) ?? ""
            job.source = "api:remotive"
            return job
        }
    }
}
