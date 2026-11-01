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

    /// Submitted applications at different stages, plus one rejection (OFFERLANE_SEED=applications).
    public static func seedApplications(_ store: Store) throws {
        let path: [JobStatus] = [.tailoring, .review, .ready, .applying, .prefilled, .applied]
        for (company, title, final) in [("Northwind", "Senior Data Scientist", JobStatus.applied), ("Contoso", "ML Engineer", .interview),
                                        ("Fabrikam", "Applied Scientist", .acknowledged), ("Tailspin", "Data Scientist", .rejected)] {
            let j = Job(company: company, title: title, location: "London, UK", url: "https://example.com/\(company.lowercased())")
            try store.upsert(j)
            for s in path { try store.transition(j.id, to: s, by: "demo") }
            if final != .applied { try store.transition(j.id, to: final, by: "email", detail: "demo reply") }
        }
    }
}
