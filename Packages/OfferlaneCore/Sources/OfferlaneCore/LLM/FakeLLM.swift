import Foundation

/// Deterministic stand-in for the AI so tests need no account or key. Each rule matches a prompt prefix.
public struct FakeLLM: LLMClient {
    public typealias Rule = @Sendable (LLMRequest) -> String?
    public let rules: [Rule]
    public var displayName: String { "Fake AI" }
    public var billed: Bool { false }
    public init(rules: [Rule]) { self.rules = rules }

    public func complete(_ r: LLMRequest) async throws -> LLMResponse {
        for rule in rules { if let out = rule(r) { return LLMResponse(text: out, usage: LLMUsage(input: r.prompt.count / 4, output: out.count / 4), model: "fake") } }
        throw LLMError.other("FakeLLM has no answer for: \(r.prompt.prefix(80))")
    }
}

extension FakeLLM {
    /// The prototype's fake_llm.py, ported: deterministic answers keyed on each prompt's first words.
    /// Used by the test suites and by the app when launched with OFFERLANE_FAKE_AI=1 (UI tests).
    public static var prototype: FakeLLM {
        FakeLLM(rules: [
            { r in
                guard r.prompt.hasPrefix("Convert this resume") else { return nil }
                let body = r.prompt.components(separatedBy: "RESUME:").last ?? ""
                let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " •-")) }.filter { $0.count > 70 }
                let enc = { (a: ArraySlice<String>) in String(data: try! JSONSerialization.data(withJSONObject: Array(a)), encoding: .utf8)! }
                return """
                {"name":"Test Person","email":"test@example.com","phone":"+44 7700 900000","location":"London, UK","headline":"Data Scientist",
                 "summary":"","experience":[{"company":"Acme","title":"Senior Data Scientist","dates":"2022 - now","bullets":\(enc(lines.prefix(6)))},
                 {"company":"Beta","title":"Data Scientist","dates":"2020 - 2022","bullets":\(enc(lines.dropFirst(6).prefix(6)))}],
                 "education":[{"school":"Uni","degree":"BSc","dates":"2016 - 2020"}],"skills":[{"label":"ML","items":"Python, SQL"}],
                 "years_experience":5,"seniority":"senior","field":"data science","suggested_titles":["Data Scientist","Machine Learning Engineer"],
                 "top_skills":["python","sql","forecasting","llm"]}
                """
            },
            { r in r.prompt.hasPrefix("Reply with") ? "{\"ok\": true}" : nil },
            { r in
                guard r.prompt.hasPrefix("Build a job-search") else { return nil }
                return """
                {"title_include":["machine learning","data scien","applied ai"],"title_exclude":["intern","director"],"queries":["data scientist"],
                 "companies":[{"name":"Scale AI","slug":"scaleai"},{"name":"Spotify"},{"name":"Perplexity"}]}
                """
            },
            { r in
                guard r.prompt.hasPrefix("Score each job") else { return nil }
                let ids = Re.findAll("^([0-9a-f]{12}) \\|", r.prompt, [.anchorsMatchLines])
                return "[" + ids.enumerated().map { "{\"id\":\"\($0.element)\",\"score\":\(92 - 3 * $0.offset),\"reason\":\"fake reason\"}" }.joined(separator: ",") + "]"
            },
            { r in
                // Tailoring: reorder the first section, invent a number (the guard must reject it), reword one bullet.
                guard r.prompt.hasPrefix("JOB:") else { return nil }
                let secs = Re.findAll("^\\[(\\w+)\\]", r.cache, [.anchorsMatchLines])
                let ids = Re.findAll("^  (\\S+): ", r.cache, [.anchorsMatchLines])
                guard let s0 = secs.first else { return nil }
                let stem = String(s0.drop { "es".contains($0) })
                let first = ids.filter { $0.split(separator: ".").first.map(String.init) == stem || $0.hasPrefix(s0 + ".") }
                guard first.count >= 2 else { return nil }
                let orig = Re.first("^  \(Re.escape(first[1])): (.*)$", r.cache, [.anchorsMatchLines]) ?? ""
                let order = Array(first.prefix(3).reversed()).map { "\"\($0)\"" }.joined(separator: ",")
                let reworded = String(data: try! JSONSerialization.data(withJSONObject: ["Reworded: " + orig], options: [.withoutEscapingSlashes]), encoding: .utf8)!.dropFirst().dropLast()
                return """
                {"keywords":["python","machine learning"],"headline":"ML Engineer","summary":"Builds ML systems.",
                 "order":{"\(s0)":[\(order)]},"rewrites":{"\(first[0])":"Made up claim with 999 users.","\(first[1])":\(reworded)},
                 "cover_letter":"Hello from the cover letter","why_company":"Because","answers":[{"q":"Why do you want to work here?","a":"Because the mission fits."}],
                 "changes_summary":"Led with ML work."}
                """
            },
            { r in r.prompt.hasPrefix("Classify each") ? "[]" : nil },
        ])
    }
}
