import Foundation

/// One curated learning resource (Resources/learning_catalog.json). The app never shows a resource from anywhere else.
public struct CatalogItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var provider: String
    public var url: String
    /// course or cert
    public var kind: String
    /// free, audit (free to view, certificate paid) or paid
    public var access: String
    /// Copied from the provider page; nil when the page does not say.
    public var cost: String?
    public var hours: Double?
    /// skills.json ids this resource teaches (a cert also lists its own cert id).
    public var skills: [String]
    public init(id: String, title: String, provider: String, url: String, kind: String = "course", access: String = "free",
                cost: String? = nil, hours: Double? = nil, skills: [String]) {
        self.id = id; self.title = title; self.provider = provider; self.url = url; self.kind = kind; self.access = access
        self.cost = cost; self.hours = hours; self.skills = skills
    }
    var accessRank: Int { ["free": 0, "audit": 1][access] ?? 2 }
}

public enum LearningCatalog {
    public static let bundled: [CatalogItem] = {
        struct File: Decodable { var items: [CatalogItem] }
        guard let url = Bundle.module.url(forResource: "Resources/learning_catalog", withExtension: "json"),
              let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) else { return [] }
        return f.items
    }()

    /// Resources that teach at least one gap: free first, then the most gap score covered, then id (stable).
    public static func candidates(for gaps: [GapItem], in items: [CatalogItem] = bundled) -> [CatalogItem] {
        let score = Dictionary(gaps.map { ($0.id, $0.score) }, uniquingKeysWith: max)
        let value = { (c: CatalogItem) in c.skills.reduce(0.0) { $0 + (score[$1] ?? 0) } }
        return items.filter { value($0) > 0 }.sorted { ($0.accessRank, -value($0), $0.id) < ($1.accessRank, -value($1), $1.id) }
    }
}

/// Verifies a link still resolves before the app shows it: https only, a 2xx after redirects,
/// and redirects may only stay on the same site (so a lapsed domain or a parked page is not shown).
public struct LinkChecker: Sendable {
    public struct Result: Codable, Hashable, Sendable {
        public var ok: Bool
        /// HTTP status; 0 when there was no answer (offline, DNS, timeout).
        public var status: Int
        public var checked: String
    }
    let session: URLSession
    let maxAgeDays: Int
    public init(session: URLSession = .shared, maxAgeDays: Int = 7) { self.session = session; self.maxAgeDays = maxAgeDays }

    // shortcut: last two labels, wrong for hosts like x.co.uk; upgrade to a public-suffix list if the catalog gains one.
    static func site(_ host: String) -> String { host.split(separator: ".").suffix(2).joined(separator: ".").lowercased() }

    public func check(_ url: String) async -> Result {
        let now = Dates.now()
        guard let u = URL(string: url), u.scheme == "https", let host = u.host else { return Result(ok: false, status: 0, checked: now) }
        var req = URLRequest(url: u); req.timeoutInterval = 15
        req.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else { return Result(ok: false, status: 0, checked: now) }
        let final = http.url ?? u
        let sameSite = final.scheme == "https" && Self.site(final.host ?? "") == Self.site(host)
        return Result(ok: (200..<300).contains(http.statusCode) && sameSite, status: http.statusCode, checked: now)
    }

    /// Checks every url not verified within `maxAgeDays` (failures are always rechecked); returns the updated cache.
    public func check(_ urls: [String], cache: [String: Result]) async -> [String: Result] {
        var out = cache
        let due = Set(urls).filter { u in cache[u].map { !$0.ok || Dates.ageDays($0.checked) >= maxAgeDays } ?? true }
        await withTaskGroup(of: (String, Result).self) { g in
            for u in due { g.addTask { (u, await check(u)) } }
            for await (u, r) in g { out[u] = r }
        }
        return out
    }
}
