import Foundation

/// Recognise a pasted careers URL and turn it into a company entry the discovery adapters understand.
public enum Careers {
    public static func detect(_ raw: String, name: String? = nil) -> SearchConfig.Company? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s.contains("://") ? s : "https://" + s), let host = u.host?.lowercased() else { return nil }
        let parts = u.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        func named(_ slug: String) -> String { name ?? slug.replacingOccurrences(of: "-", with: " ").capitalized }
        if host.hasSuffix("myworkdayjobs.com") || host.contains(".myworkdaysite.com") {
            // https://nvidia.wd5.myworkdayjobs.com/en-US/NVIDIAExternalCareerSite/job/... -> https://nvidia.wd5.myworkdayjobs.com/NVIDIAExternalCareerSite
            guard let site = parts.first(where: { !Re.search("^[a-z]{2}-[A-Z]{2}$", $0, []) }) else { return nil }
            return .init(name: name ?? host.split(separator: ".").first.map { String($0).capitalized } ?? host, workday: "https://\(host)/\(site)", ats: "workday")
        }
        let table: [(String, String)] = [("greenhouse.io", "greenhouse"), ("lever.co", "lever"), ("ashbyhq.com", "ashby"),
                                         ("workable.com", "workable"), ("smartrecruiters.com", "smartrecruiters")]
        guard let ats = table.first(where: { host.hasSuffix($0.0) })?.1 else { return nil }
        var slug: String?
        if ats == "greenhouse", let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "for" })?.value { slug = q }
        if slug == nil {
            let skip: Set<String> = ["v1", "v0", "boards", "embed", "job_board", "postings", "api", "widget", "accounts", "companies", "posting-api", "job-board"]
            slug = parts.first { !skip.contains($0) }
        }
        guard let slug, !slug.isEmpty else { return nil }
        return .init(name: named(slug), slug: slug.lowercased(), ats: ats)
    }

    /// Verified public Workday career sites, bundled with the app.
    public static let workdayTenants: [String: String] = {
        guard let url = Bundle.module.url(forResource: "Resources/workday_tenants", withExtension: "json"),
              let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return Dictionary(uniqueKeysWithValues: m.map { ($0.key.lowercased(), $0.value) })
    }()

    /// Attach known Workday sites so big employers are searched directly.
    public static func attachWorkday(_ companies: [SearchConfig.Company]) -> [SearchConfig.Company] {
        companies.map { c in
            var c = c
            if c.workday == nil, let u = workdayTenants[c.name.lowercased()] { c.workday = u; c.ats = "workday" }
            return c
        }
    }
}
