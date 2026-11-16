import Foundation

/// Sample roles for UI tests (OFFERLANE_SEED=matches). Never used otherwise.
public enum DemoData {
    public static func seedMatches(_ store: Store) throws {
        if try store.resume() == nil {
            var r = ResumeContent(); r.name = "Test Person"; r.email = "test@example.com"; r.location = "London, UK"; r.headline = "Data Scientist"
            r.yearsExperience = "5"; r.skills = [.init(label: "ML", items: "Python, SQL, forecasting")]
            r.experience = [
                .init(id: "e1", title: "Senior Data Scientist", company: "Acme", dates: "2022 – now", bullets: [
                    .init(id: "e1.1", text: "Built a demand forecasting system covering 1,200 products, cutting error by 30%."),
                    .init(id: "e1.2", text: "Shipped 4 production ML models serving 2 million users."),
                    .init(id: "e1.3", text: "Led a team of 3 analysts on pricing experiments."),
                    .init(id: "e1.4", text: "Partnered with finance on monthly revenue forecasts.")]),
                .init(id: "e2", title: "Data Scientist", company: "Beta", dates: "2020 – 2022", bullets: [
                    .init(id: "e2.1", text: "Designed churn models with gradient boosting, improving retention by 8%."),
                    .init(id: "e2.2", text: "Automated weekly reporting in Python and SQL.")]),
            ]
            let src = r.experience.flatMap { $0.bullets.map(\.text) }.joined(separator: "\n")
            try store.saveResume(ResumeVersion(name: "main", label: "Main", content: r, sourceText: src, sourceFile: "cv.txt"))
            var p = try store.profile(); p.personal.firstName = "Test"; p.personal.lastName = "Person"; p.personal.email = "test@example.com"
            try store.set(.profile, p)
        }
        var s = try store.search(); s.minScore = 65; try store.set(.search, s)
        let rows: [(String, String, String, Int, String, String)] = [
            ("Globex", "Senior Data Scientist, Forecasting", "London, UK", 88, "Forecasting focus matches your demand-planning work.", "ok"),
            ("Initech", "Machine Learning Engineer", "Remote - EMEA", 74, "Strong ML fit; remote within your time zone.", "remote"),
            ("Umbrella", "Staff Data Scientist", "New York, NY", 58, "Seniority one level above; US visa needed.", "h1b-lottery"),
            ("Hooli", "Data Analyst", "Berlin, Germany", 41, "More analytics than ML.", "likely"),
        ]
        for (company, title, loc, score, reason, visa) in rows {
            var j = Job(company: company, title: title, location: loc, url: "https://example.com/\(company.lowercased())")
            j.description = "You will build models. Requirements: 5+ years of experience with Python and SQL."
            j.posted = Dates.daysAgo(3); j.minYears = 5; j.visa = visa; j.localScore = Double(score - 10)
            try store.upsert(j)
            try store.update(j.id) { $0.llmScore = score; $0.llmReason = reason; $0.variant = "main"; $0.visa = visa; $0.minYears = 5 }
        }
    }

    /// Matches plus one Adzuna advert, for its attribution label (OFFERLANE_SEED=sources).
    public static func seedSources(_ store: Store) throws {
        try seedMatches(store)
        var s = try store.search(); s.titleInclude = ["data scien"]; s.companies = [.init(name: "Globex", slug: "globex", ats: "greenhouse")]
        try store.set(.search, s)
        var j = Job(company: "Vandelay", title: "Data Scientist, Pricing", location: "Sydney, Australia", url: "https://www.adzuna.com.au/details/1")  // not the .co.uk fallback, so the badge test sees the country site
        j.description = "You will build pricing models in Python and SQL."; j.posted = Dates.daysAgo(2); j.source = "api:adzuna"
        try store.upsert(j)
        try store.update(j.id) { $0.llmScore = 80; $0.llmReason = "Pricing models match your forecasting work."; $0.variant = "main" }
    }

    /// Matches with Ollama saved as the AI: a provider that sits under "More options" (OFFERLANE_SEED=ollama).
    public static func seedOllama(_ store: Store) throws {
        try seedMatches(store)
        var s = try store.settings(); s.provider = .ollama; s.modelFast = "llama3.2"; s.modelSmart = "llama3.2"
        try store.set(.settings, s)
    }

    /// Many scored roles, for the scrolling performance test (OFFERLANE_SEED=many).
    public static func seedMany(_ store: Store, count: Int = 2000) throws {
        try seedMatches(store)
        let companies = ["Globex", "Initech", "Umbrella", "Hooli", "Stark", "Wayne", "Acme", "Wonka", "Tyrell", "Cyberdyne"]
        let titles = ["Data Scientist", "ML Engineer", "Analytics Lead", "Applied Scientist", "Research Engineer"]
        for i in 0..<count {
            let c = companies[i % companies.count], t = "\(titles[i % titles.count]) \(i)"
            var j = Job(company: c, title: t, location: "London, UK", url: "https://example.com/\(c.lowercased())/\(i)")
            j.description = "You will build models. Requirements: Python and SQL."
            j.posted = Dates.daysAgo(i % 20)
            try store.upsert(j)
            try store.update(j.id) { $0.llmScore = 66 + i % 34; $0.llmReason = "Generated role \(i) for scrolling."; $0.variant = "main" }
        }
    }

    /// Applications plus one contact whose follow-up is overdue, for the Today follow-up hero (OFFERLANE_SEED=followup).
    public static func seedFollowUp(_ store: Store) throws {
        try seedApplications(store)
        var c = Contact(name: "Ana Ruiz"); c.company = "Contoso"; c.followUp = Dates.today(Date().addingTimeInterval(-86_400))
        try Contacts.upsert(c, in: store)
    }

    /// Every screen filled, for README screenshots (OFFERLANE_SEED=showcase): matches with fuller postings, target roles, applications.
    public static func seedShowcase(_ store: Store) throws {
        try seedMatches(store)
        let posting = "You will build forecasting and machine learning models in production. Requirements: 5+ years with Python and SQL, "
            + "experience with PyTorch or TensorFlow, Spark, AWS, Docker and Kubernetes, A/B testing and statistics, and clear communication with stakeholders."
        for j in try store.jobs() { try store.update(j.id) { $0.description = posting } }
        var s = try store.search(); s.targetTitles = ["Data Scientist", "Machine Learning Engineer"]; try store.set(.search, s)
        try seedApplications(store)
        // Screenshots show the v4 Pipeline states too: one quiet application and one offer.
        let offer = Job(company: "Woodgrove", title: "Lead Data Scientist", location: "Remote", url: "https://example.com/woodgrove")
        try store.upsert(offer)
        for st in [JobStatus.tailoring, .review, .ready, .applying, .prefilled, .applied, .screen, .interview, .offer] { try store.transition(offer.id, to: st, by: "demo") }
        if var quiet = try store.jobs().first(where: { $0.company == "Northwind" }) {
            quiet.updated = Dates.now(Date().addingTimeInterval(-16 * 86_400)); try store.save(quiet)  // save, not update: update stamps now
        }
    }

    /// Submitted applications at different stages, plus one rejection (OFFERLANE_SEED=applications).
    public static func seedApplications(_ store: Store) throws {
        let path: [JobStatus] = [.tailoring, .review, .ready, .applying, .prefilled, .applied]
        for (company, title, final) in [("Northwind", "Senior Data Scientist", JobStatus.applied), ("Contoso", "ML Engineer", .interview),
                                        ("Fabrikam", "Applied Scientist", .acknowledged), ("Tailspin", "Data Scientist", .rejected)] {
            var j = Job(company: company, title: title, location: "London, UK", url: "https://example.com/\(company.lowercased())")
            j.description = "You will build machine learning models in production with Python and SQL."   // so the company brief has a source
            try store.upsert(j)
            for s in path { try store.transition(j.id, to: s, by: "demo") }
            if final != .applied { try store.transition(j.id, to: final, by: "email", detail: "demo reply") }
            if final == .interview { _ = try store.update(j.id) { $0.interviewAt = Dates.now(Date().addingTimeInterval(3 * 86_400)) } }
        }
    }
}
