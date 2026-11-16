import Foundation

/// Adzuna's job search API (docs/SOURCES.md). Terms: a free key the user gets themselves, personal job search allowed,
/// each advert links to Adzuna and shows an "Adzuna" label (≥116×23, see `attribution`); descriptions are snippets.
/// Off by default and only `ready` once the user has saved their own app ID and key (profile Keychain, never logged).
public struct Adzuna: JobSource {
    public struct Keys: Sendable, Equatable {
        public var appId: String, appKey: String
        public init(appId: String, appKey: String) { self.appId = appId; self.appKey = appKey }
    }

    public let id = "adzuna", name = "Adzuna"
    public let terms = "Jobs from many boards, with your own free Adzuna key. Each result links to Adzuna. Checked at most every 6 hours."
    public let minInterval: TimeInterval = 6 * 3600
    public let defaultOn = false
    /// Free plan allows ~250 requests a day; a few per run, at most every 6 hours, stays far below it.
    public static let maxRequests = 4
    /// Adzuna's countries and their own sites, shared with libs/core (adzuna.ts); only these sites may become an attribution link.
    static let table: [(code: String, site: String)] = {
        struct Row: Decodable { let code, site: String }
        guard let url = Bundle.module.url(forResource: "Resources/adzuna_countries", withExtension: "json"),
              let d = try? Data(contentsOf: url), let rows = try? JSONDecoder().decode([Row].self, from: d) else { return [] }
        return rows.map { ($0.code, $0.site) }
    }()
    public static let countries = table.map(\.code)
    public static let attribution = URL(string: "https://www.adzuna.co.uk")!
    static let sites = Set(table.map(\.site))
    /// The attribution link for one advert: the Adzuna country site its own link is on (https, `[www.]` + one of `sites`), else `attribution`.
    public static func attribution(for jobURL: String) -> URL {
        // Literal "https://", then printable ASCII without a backslash (no whitespace, BOM or IDN), so Foundation and WHATWG URL parsing (libs/core) agree.
        guard Re.search("^https://[\\x21-\\x5B\\x5D-\\x7E]+\\z", jobURL, []), let u = URL(string: jobURL), u.scheme == "https", let host = u.host?.lowercased(),
              sites.contains(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host),
              let site = URL(string: "https://" + host) else { return attribution }
        return site
    }
    public static let signUp = URL(string: "https://developer.adzuna.com/signup")!
    static let keychainAccount = "source:adzuna"
    /// The request URL carries the key, so Adzuna never goes through a session with a disk cache.
    /// No 429 back-off: a run is already ≥6 h apart, so waiting 15–60 s to retry only delays the "rate limited" message.
    static let noCache: HTTP = {
        let c = URLSessionConfiguration.ephemeral; c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return HTTP(session: URLSession(configuration: c), retryRateLimit: false)
    }()
    public struct InvalidKey: LocalizedError { public var errorDescription: String? { "The Adzuna app ID can't contain \":\". Copy it again from your Adzuna dashboard." } }

    let keys: Keys?, country: String
    public init(keys: Keys?, country: String) { self.keys = keys; self.country = country }
    /// The source as the user set it up: keys from the profile Keychain, country from the search settings.
    public init(keychain: Keychain, search: SearchConfig) { self.init(keys: Self.keys(in: keychain), country: Self.country(search.adzunaCountry)) }

    public var ready: Bool { keys != nil && Self.countries.contains(country) }

    public func fetch(_ queries: [SearchQuery], http: HTTP) async -> SourceResult {
        guard let keys, ready else { return .unreachable }
        let http = http === HTTP.shared ? Self.noCache : http
        var out: [Job] = [], seen = Set<String>(), any = false
        for q in queries.prefix(Self.maxRequests) {
            if Task.isCancelled { break }
            var c = URLComponents(string: "https://api.adzuna.com/v1/api/jobs/\(country)/search/1")!
            c.queryItems = [.init(name: "app_id", value: keys.appId), .init(name: "app_key", value: keys.appKey),
                            .init(name: "results_per_page", value: "50"), .init(name: "what", value: q.what),
                            .init(name: "max_days_old", value: "30")] + (q.where.map { [.init(name: "where", value: $0)] } ?? [])
            // The URL carries the key: never log it or put it in an error (HTTP logs only the host).
            guard let url = c.url, let r = await http.get(url) else { continue }
            if r.status == 429 { return any ? .jobs(out) : .rateLimited }
            if r.status == 401 || r.status == 403 {
                return .refused("Adzuna didn't accept your key. Check the app ID and key under Search → Job sources.")
            }
            guard r.status == 200, let j = r.json else { continue }
            any = true
            for job in Self.parse(j) where seen.insert(job.url).inserted { out.append(job) }
        }
        return any ? .jobs(out) : .unreachable
    }

    public static func parse(_ j: JSONValue) -> [Job] {
        (j["results"]?.array ?? []).compactMap { x in
            let title = Text.stripHTML(x["title"]?.string), company = x["company"]?["display_name"]?.string ?? ""
            let url = x["redirect_url"]?.string ?? ""
            guard !title.isEmpty, !company.isEmpty, url.hasPrefix("https://") else { return nil }
            var job = Job(company: company, title: title, location: x["location"]?["display_name"]?.string ?? "", url: url)
            job.posted = Dates.toDate(x["created"]?.string); job.description = Text.stripHTML(x["description"]?.string)
            job.source = "api:adzuna"
            return job
        }
    }

    // MARK: Setup

    public static func keys(in keychain: Keychain) -> Keys? {
        guard let v = keychain.get(account: keychainAccount), let i = v.firstIndex(of: ":") else { return nil }
        let k = Keys(appId: String(v[..<i]), appKey: String(v[v.index(after: i)...]))
        return k.appId.isEmpty || k.appKey.isEmpty ? nil : k
    }

    /// Saves (or with nil / blank fields, removes) the user's Adzuna keys.
    public static func save(_ keys: Keys?, in keychain: Keychain) throws {
        let id = keys?.appId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = keys?.appKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if id.contains(":") { throw InvalidKey() }   // the item is "id:key"; keep the saved key as it was
        guard !id.isEmpty, !key.isEmpty else { keychain.delete(account: keychainAccount); return }
        try keychain.set("\(id):\(key)", account: keychainAccount)
    }

    /// The saved country, else one from the Mac's region, else the US.
    public static func country(_ saved: String) -> String { countries.contains(saved) ? saved : defaultCountry(region: Locale.current.region?.identifier) }
    static func defaultCountry(region: String?) -> String {
        let r = (region ?? "").lowercased() == "uk" ? "gb" : (region ?? "").lowercased()
        return countries.contains(r) ? r : "us"
    }
}
