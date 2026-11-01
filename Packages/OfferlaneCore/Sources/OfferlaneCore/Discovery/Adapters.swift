import Foundation

/// One posting as an ATS API returns it, before it becomes a `Job`.
public struct Posting: Sendable, Hashable {
    public var title: String
    public var location: String
    public var url: String
    public var applyUrl: String
    public var posted: String?
    public var description: String
    /// A follow-up URL with the full description (SmartRecruiters, Workday).
    public var detail: URL?
}

/// The six public job-board APIs. Ported from discover.py; endpoints are the ones the career pages themselves call.
public enum ATS: String, CaseIterable, Sendable {
    case greenhouse, lever, ashby, workable, smartrecruiters, workday

    /// Order used when probing an unknown company's slug.
    public static let probeOrder: [ATS] = [.greenhouse, .lever, .ashby, .workable, .smartrecruiters]

    public func list(_ slug: String, http: HTTP, queries: [String] = [""]) async -> [Posting]? {
        switch self {
        case .greenhouse:
            guard let r = await http.get(URL(string: "https://boards-api.greenhouse.io/v1/boards/\(slug)/jobs?content=true")!), r.status == 200, let j = r.json else { return nil }
            return Self.greenhouse(j)
        case .lever:
            guard let r = await http.get(URL(string: "https://api.lever.co/v0/postings/\(slug)?mode=json")!), r.status == 200, let j = r.json, j.array != nil else { return nil }
            return Self.lever(j)
        case .ashby:
            guard let r = await http.get(URL(string: "https://api.ashbyhq.com/posting-api/job-board/\(slug)?includeCompensation=true")!), r.status == 200, let j = r.json else { return nil }
            return Self.ashby(j)
        case .workable:
            guard let r = await http.get(URL(string: "https://apply.workable.com/api/v1/widget/accounts/\(slug)?details=true")!), r.status == 200, let j = r.json else { return nil }
            return Self.workable(j)
        case .smartrecruiters:
            guard let r = await http.get(URL(string: "https://api.smartrecruiters.com/v1/companies/\(slug)/postings?limit=100")!), r.status == 200,
                  let j = r.json, !(j["content"]?.array ?? []).isEmpty else { return nil }
            return Self.smartrecruiters(j, slug: slug)
        case .workday:
            guard let api = Self.workdayAPI(slug) else { return nil }
            var out: [String: Posting] = [:]
            for q in queries {
                guard let r = await http.postJSON(api.appendingPathComponent("jobs"), ["appliedFacets": [String: Any](), "limit": 20, "offset": 0, "searchText": q]),
                      r.status == 200, let j = r.json else { return nil }
                for p in Self.workday(j, siteURL: slug, api: api) { out[p.url] = p }
            }
            return Array(out.values)
        }
    }

    // MARK: parsers (pure, unit-tested against recorded responses)

    static func s(_ v: JSONValue?) -> String { v?.string ?? "" }

    public static func greenhouse(_ j: JSONValue) -> [Posting] {
        (j["jobs"]?.array ?? []).map { x in
            Posting(title: s(x["title"]), location: s(x["location"]?["name"]), url: s(x["absolute_url"]), applyUrl: s(x["absolute_url"]),
                    posted: Dates.toDate(x["updated_at"]?.string), description: Text.stripHTML(x["content"]?.string))
        }
    }
    public static func lever(_ j: JSONValue) -> [Posting] {
        (j.array ?? []).map { x in
            let lists = (x["lists"]?.array ?? []).map { Text.stripHTML($0["content"]?.string) }.joined(separator: " ")
            return Posting(title: s(x["text"]), location: s(x["categories"]?["location"]), url: s(x["hostedUrl"]), applyUrl: s(x["applyUrl"]),
                           posted: Dates.toDate(x["createdAt"]?.double), description: (s(x["descriptionPlain"]) + " " + lists).trimmingCharacters(in: .whitespaces))
        }
    }
    public static func ashby(_ j: JSONValue) -> [Posting] {
        (j["jobs"]?.array ?? []).filter { if case .bool(false) = $0["isListed"] ?? .null { return false }; return true }.map { x in
            var remote = false; if case .bool(true) = x["isRemote"] ?? .null { remote = true }
            let desc = s(x["descriptionPlain"]).isEmpty ? Text.stripHTML(x["descriptionHtml"]?.string) : s(x["descriptionPlain"])
            return Posting(title: s(x["title"]), location: s(x["location"]) + (remote ? " / Remote" : ""), url: s(x["jobUrl"]), applyUrl: s(x["applyUrl"]),
                           posted: Dates.toDate(x["publishedAt"]?.string), description: desc)
        }
    }
    public static func workable(_ j: JSONValue) -> [Posting] {
        (j["jobs"]?.array ?? []).map { x in
            var remote = false; if case .bool(true) = x["telecommuting"] ?? .null { remote = true }
            let loc = [s(x["city"]), s(x["country"])].filter { !$0.isEmpty }.joined(separator: ", ") + (remote ? " / Remote" : "")
            let url = s(x["url"]).isEmpty ? s(x["shortlink"]) : s(x["url"])
            return Posting(title: s(x["title"]), location: loc, url: url, applyUrl: s(x["application_url"]).isEmpty ? url : s(x["application_url"]),
                           posted: Dates.toDate(x["published_on"]?.string), description: Text.stripHTML(x["description"]?.string))
        }
    }
    public static func smartrecruiters(_ j: JSONValue, slug: String) -> [Posting] {
        (j["content"]?.array ?? []).map { x in
            let l = x["location"]; var remote = false; if case .bool(true) = l?["remote"] ?? .null { remote = true }
            let id = s(x["id"]), u = "https://jobs.smartrecruiters.com/\(slug)/\(id)"
            return Posting(title: s(x["name"]), location: [s(l?["city"]), s(l?["country"])].filter { !$0.isEmpty }.joined(separator: ", ") + (remote ? " / Remote" : ""),
                           url: u, applyUrl: u, posted: Dates.toDate(x["releasedDate"]?.string), description: "",
                           detail: URL(string: "https://api.smartrecruiters.com/v1/companies/\(slug)/postings/\(id)"))
        }
    }

    /// https://<tenant>.wdN.myworkdayjobs.com/<site> → https://<tenant>.wdN.myworkdayjobs.com/wday/cxs/<tenant>/<site>
    public static func workdayAPI(_ siteURL: String) -> URL? {
        guard let u = URL(string: siteURL), let host = u.host else { return nil }
        let tenant = host.split(separator: ".").first.map(String.init) ?? ""
        guard let site = u.path.split(separator: "/").map(String.init).first(where: { !Re.search("^[a-z]{2}-[A-Z]{2}$", $0, []) }) else { return nil }
        return URL(string: "https://\(host)/wday/cxs/\(tenant)/\(site)")
    }
    public static func workday(_ j: JSONValue, siteURL: String, api: URL, now: Date = Date()) -> [Posting] {
        guard let u = URL(string: siteURL), let host = u.host,
              let site = u.path.split(separator: "/").map(String.init).first(where: { !Re.search("^[a-z]{2}-[A-Z]{2}$", $0, []) }) else { return [] }
        return (j["jobPostings"]?.array ?? []).compactMap { p in
            guard let path = p["externalPath"]?.string, !path.isEmpty else { return nil }
            let on = s(p["postedOn"]).lowercased()
            var posted: String?
            if let d = Re.first("(\\d+)\\+? days", on) { posted = Dates.daysAgo(Int(d) ?? 0, now: now) }
            else if on.contains("yesterday") { posted = Dates.daysAgo(1, now: now) }
            else if on.contains("today") { posted = Dates.today(now) }
            let url = "https://\(host)/\(site)\(path)"
            return Posting(title: s(p["title"]), location: s(p["locationsText"]), url: url, applyUrl: url, posted: posted, description: "",
                           detail: URL(string: api.absoluteString + path))
        }
    }

    /// Full description from a detail response (SmartRecruiters `jobAd.sections`, Workday `jobPostingInfo`).
    public static func detailText(_ j: JSONValue) -> String {
        if let wd = j["jobPostingInfo"]?["jobDescription"]?.string { return Text.stripHTML(wd) }
        let sec = j["jobAd"]?["sections"]
        return ["jobDescription", "qualifications"].map { Text.stripHTML(sec?[$0]?["text"]?.string) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
