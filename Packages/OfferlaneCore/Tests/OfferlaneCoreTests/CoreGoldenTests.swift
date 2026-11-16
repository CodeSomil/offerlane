import XCTest
@testable import OfferlaneCore

/// The shared golden for the TypeScript port (libs/core, v4 P3): fixed inputs, then what the Swift prompt builders,
/// PlanApplier and Brief make of them. The inputs are stored too, so the TS side decodes the same JSON shapes.
/// Regenerate with `OFFERLANE_WRITE_GOLDEN=1 swift test --filter CoreGoldenTests`.
final class CoreGoldenTests: XCTestCase {
    static let day = "2026-10-31T09:00:00Z"

    func version(_ name: String, label: String) -> ResumeVersion {
        var r = ResumeContent(); r.variant = name; r.label = label
        r.name = "Test Person"; r.email = "test@example.com"; r.location = "London, UK"
        r.headline = "Data Scientist"; r.summary = "Data scientist with 5 years in forecasting and pricing."
        r.experience = [
            .init(id: "e1", title: "Senior Data Scientist", company: "Acme", location: "London", dates: "2022 - now", bullets: [
                .init(id: "e1b1", text: "Built a demand forecasting system covering 1,200 products, cutting error by 30%."),
                .init(id: "e1b2", text: "Led a team of 4 analysts on pricing experiments in Python and SQL."),
                .init(id: "e1b3", text: "Ran weekly reviews with category managers."),
            ]),
            .init(id: "e2", title: "Data Analyst", company: "Initrode", dates: "2019 - 2022", bullets: [
                .init(id: "e2b1", text: "Automated 12 weekly reports with dbt and Airflow."),
                .init(id: "e2b2", text: "Cleaned survey data for the marketing team."),
            ]),
        ]
        r.projects = [.init(id: "p1", name: "Open-source forecaster", dates: "2023", bullets: [.init(id: "p1b1", text: "Published a Prophet wrapper used by 300 people.")])]
        r.skills = [.init(label: "Languages", items: "Python, SQL"), .init(label: "Tools", items: "dbt, Airflow"), .init(label: "ML", items: "forecasting, pricing")]
        r.yearsExperience = "5"; r.topSkills = ["python", "sql", "forecasting"]; r.suggestedTitles = ["Data Scientist"]
        return ResumeVersion(name: name, label: label, isDefault: name == "main", content: r, sourceText: "", sourceFile: "cv.txt", created: Self.day)
    }

    func inputs() -> (ResumeVersion, [ResumeVersion], Profile, SearchConfig, Job, TailorPlan) {
        let v = version("main", label: "Main"), lead = version("lead", label: "Lead")
        var p = Profile()
        p.work.yearsExperience = "5"; p.work.currentTitle = "Senior Data Scientist"; p.work.currentCompany = "Acme"
        p.work.currentSalary = "£70k"; p.work.expectedSalary = "£85k"
        p.authorization.authorizedCountries = ["United Kingdom"]; p.authorization.needsSponsorship = true
        p.prefs.dealbreakers = "no on-site 5 days"; p.prefs.notes = "prefers fintech"
        var s = SearchConfig(); s.targetTitles = ["Data Scientist", "ML Engineer"]; s.aspirations = ["Head of Data"]
        s.locations = ["london", "manchester"]; s.remoteOk = true
        var j = Job(company: "Globex", title: "Senior Data Scientist", location: "London, UK", url: "https://boards.example/globex/1")
        j.id = "job-1"; j.ats = "greenhouse"; j.atsSlug = "globex"; j.posted = "2026-10-28"; j.visa = "sponsor"; j.minYears = 4
        j.description = "<p>You will build <b>forecasting</b> models for 2,000 stores.</p><ul><li>Python and SQL</li><li>Kubernetes a plus</li></ul>"
        j.firstSeen = Self.day; j.updated = Self.day; j.lastSeen = Self.day; j.variant = "main"; j.tailorNote = "Stress pricing work."
        var plan = TailorPlan()
        plan.keywords = ["forecasting", "pricing"]
        plan.headline = "Senior Data Scientist, forecasting and pricing"
        plan.summary = "Data scientist with 9 years in forecasting."               // 9 isn't in the resume: rejected
        plan.order = ["e1": ["e1b2", "e1b1"], "e2": ["e2b1", "e2b1", "nope"]]      // drops e1b3 and e2b2; duplicate and unknown ids
        plan.rewrites = ["e1b1": "Built demand forecasting for 1200 products in Kubernetes, cutting error 30%.",  // new term flagged
                         "e1b2": "Led 6 analysts on pricing experiments.",                                     // 6: rejected
                         "p1b1": "Published a Prophet wrapper used by 300 people."]                            // unchanged
        plan.skillsOrder = ["ML", "Languages"]
        plan.coverLetter = "Dear Globex team"; plan.whyCompany = "Retail forecasting at scale."
        plan.answers = [.init(q: "Why this role?", a: "Forecasting is my work.")]; plan.changesSummary = "Led with pricing."
        plan.variant = "main"
        return (v, [v, lead], p, s, j, plan)
    }

    /// A messy model reply for ResumeParser.content: prose and a fence, numbers for strings, blank and non-string items.
    static let parseReply = """
    Here is the JSON:
    ```json
    {"name":"Test Person","email":"test@example.com","phone":7700900123,"location":"London, UK",
     "links":{"linkedin":"https://linkedin.example/in/test","github":"","portfolio":""},
     "headline":"Data Scientist","summary":"",
     "experience":[{"company":"Acme","title":"Senior Data Scientist","location":"London","dates":"2022 - now",
                    "bullets":["  Built demand forecasting for 1,200 products.  ","", 42, "Led 4 analysts."]},
                   {"company":"Initrode","title":"Data Analyst","dates":"2019 - 2022","bullets":["Automated 12 reports."]}, "junk"],
     "projects":[{"name":"Forecaster","dates":2023,"bullets":["Published a wrapper used by 300 people."]}],
     "education":[{"school":"UCL","degree":"MSc","dates":"2019","details":""}],
     "skills":[{"label":"Languages","items":"Python, SQL"},{"label":"","items":"orphan"}],
     "certifications":["", "AWS ML"],"extras":["Fluent French", ""],
     "years_experience":7,"seniority":"senior","field":"data science",
     "suggested_titles":["Data Scientist","ML Engineer"],"top_skills":["python","sql",true]}
    ```
    """

    func json<T: Encodable>(_ x: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(x), options: .fragmentsAllowed) }

    func testCoreMatchesGolden() throws {
        let (v, versions, p, s, j, plan) = inputs()
        let review = PlanApplier.review(plan, v)
        var edits = review
        edits.headline = "Data Scientist"
        edits.groups[0].bullets[0].text = "Led a team of 4 analysts on pricing work in Python and SQL."
        edits.groups[0].bullets.reverse()
        edits.groups[1].bullets.removeAll()
        let (content, warnings) = PlanApplier.apply(plan, to: v)
        // Pinned by hand too, so a golden rewrite can't hide it: a repeated id in the AI's order is used once.
        XCTAssertEqual(content.experience[1].bullets.map(\.id), ["e2b1"])
        let briefPublic = Brief.candidate(resume: v.content, versions: versions, profile: p, search: s, includePrivate: false)
        let tailor = Tailor.request(j, version: v, brief: briefPublic)
        let supported = ["The team builds forecasting models.", "How does the team use Python?", "Globex raised $50M from Sequoia.",
                         "They use Kubernetes daily.", "Visit https://globex.example for more."]
        let parsed = ResumeParser.content(try AI.decode(Self.parseReply, as: ResumeParser.Parsed.self), name: "main", label: "")
        var prefilled = Profile(); prefilled.personal.phone = "typed by the user"; prefilled.prefill(from: parsed)
        // Copy to Claude (P3.6): the scrub, reading a pasted reply, the Guard on every text, and answers.md.
        let cleanCases: [(String, [String])] = [
            ("Mail test.person+cv@example.co.uk or call 07700 900123 (abc).", ["07700 900123", "abc", "  "]),
            ("Keys sk-abcdefghijklmnopqrstuv, AIzaSyA1234567890abcdefghij, gsk_abcdefghijklmnopqrstu; 2019 - 2023 stays.", []),
            ("Write to josé@exämple.com at 10 DOWNING STREET, SW1A 2AA.", ["10 Downing Street", "SW1A 2AA", "10 Downing"]),
        ]
        let replies = ["Sure! {not json} Here it is:\n```json\n{\"headline\":\"Data Scientist\",\"order\":{\"e1\":[\"e1b2\"]},\"cover_letter\":\"Hi\"}\n```\nGood luck.",
                       "I can't help with that.", "{}", "{\"headline\":\"\",\"summary\":\"Only a summary\"}"]
        var loud = plan; loud.coverLetter = "I grew revenue 40% at Acme."; loud.whyCompany = ""
        loud.answers = [.init(q: "Team size?", a: "I led 4 analysts."), .init(q: "Budget?", a: "I ran a $2M budget.")]
        var parses: [[String: Any]] = []
        for r in replies { parses.append(["reply": r, "plan": try (try? ClaudeHandoff.parse(r)).map(json) ?? NSNull()]) }
        var md = plan; md.answers.append(.init(q: "", a: "dropped")); md.answers.append(.init(q: "  Notice period? ", a: " One month.\n"))
        let out: [String: Any] = [
            "handoff": [
                "clean": cleanCases.map { ["text": $0.0, "known": $0.1, "out": MCPServer.clean($0.0, known: $0.1)] as [String: Any] },
                "parse": parses,
                "rejections": ["plan": ClaudeHandoff.rejections(plan, v), "loud": ClaudeHandoff.rejections(loud, v), "loudPlan": try json(loud)] as [String: Any],
                "answersMarkdown": ["plan": try json(md), "out": Tailor.answersMarkdown(md, company: "Globex")] as [String: Any],
            ] as [String: Any],
            "inputs": ["version": try json(v), "versions": try json(versions), "profile": try json(p), "search": try json(s),
                       "job": try json(j), "plan": try json(plan), "edits": try json(edits)],
            "brief": ["private": Brief.candidate(resume: v.content, versions: versions, profile: p, search: s),
                      "public": briefPublic,
                      "single": Brief.candidate(resume: v.content, versions: [v], profile: Profile(), search: SearchConfig())],
            "compact": PlanApplier.compact(v),
            "source": PlanApplier.source(v),
            "apply": ["content": try json(content), "warnings": warnings],
            "review": try json(review),
            "planFromReview": try json(PlanApplier.plan(from: edits, old: plan, v)),
            "prompts": [
                "rank": Ranking.head(versions: ["main"]),
                "rankMulti": Ranking.head(versions: ["main", "lead"]),
                "rankLine": Ranking.line(j),
                "resumeParse": ResumeParser.prompt,
                "searchSetup": SearchSetup.prompt,
                "searchBrief": SearchSetup.brief(s, resume: v.content, versions: versions, profile: p),
                "tailor": ["bank": tailor.bank, "jd": tailor.jd, "prompt": tailor.prompt],
                "handoff": ClaudeHandoff.text(j, version: v, brief: briefPublic),
                "companyBrief": CompanyBriefs.prompt(CompanyBriefs.source(j)),
            ] as [String: Any],
            "status": ["allowed": Dictionary(uniqueKeysWithValues: JobStatus.allCases.map { f in (f.rawValue, JobStatus.allCases.filter { StateMachine.canMove(f, to: $0) }.map(\.rawValue)) }),
                       "titles": Dictionary(uniqueKeysWithValues: JobStatus.allCases.map { ($0.rawValue, $0.title) }),
                       "order": JobStatus.allCases.map(\.rawValue), "tracked": JobStatus.tracked.map(\.rawValue)] as [String: Any],
            "parse": ["reply": Self.parseReply, "content": try json(parsed), "profile": try json(prefilled)],
            "companySupported": supported.map { ["line": $0, "ok": CompanyBriefs.supported($0, source: CompanyBriefs.source(j))] as [String: Any] },
        ]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let got = String(decoding: data, as: UTF8.self) + "\n"
        if ProcessInfo.processInfo.environment["OFFERLANE_WRITE_GOLDEN"] == "1" {
            let dst = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/core/core_expected.json")
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try got.write(to: dst, atomically: true, encoding: .utf8)
            return
        }
        XCTAssertEqual(got, String(decoding: Fixture.data("core/core_expected.json"), as: UTF8.self))
    }

    /// Hand-written cases with their expected results; libs/core runs the same file.
    func testGuardCases() throws {
        let cases = try JSONDecoder().decode([GuardCase].self, from: Fixture.data("core/guard_cases.json"))
        XCTAssertGreaterThan(cases.count, 5)
        for c in cases {
            let r = Guard.check(c.new, source: c.source)
            XCTAssertEqual(r.ok, c.ok, c.why); XCTAssertEqual(r.warnings, c.warnings, c.why)
        }
    }

    func testPayCases() throws {
        let cases = try JSONDecoder().decode([PayCase].self, from: Fixture.data("core/pay_cases.json"))
        XCTAssertGreaterThan(cases.count, 5)
        for c in cases { XCTAssertEqual(PayRange.parse(c.text), c.expect, c.text) }
    }

    struct GuardCase: Decodable { var new: String; var source: String; var ok: Bool; var warnings: [String]; var why: String }
    struct PayCase: Decodable { var text: String; var expect: [PayRange] }
}
