import Foundation

public struct InterviewQuestion: Codable, Hashable, Sendable, Identifiable {
    /// "behavioral", "role" (from the role's track) or "skill" (asked for in the user's collected postings).
    public var kind: String
    public var text: String
    public var id: String { text }
}

/// A STAR story drawn only from the resume bullets it cites.
public struct StarStory: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var situation: String
    public var task: String
    public var action: String
    public var result: String
    public var bulletIds: [String]
    /// Terms not found in the cited bullets: shown so the user checks they are true.
    public var warnings: [String]
    public init(id: String = UUID().uuidString, title: String, situation: String = "", task: String = "", action: String = "", result: String = "",
                bulletIds: [String], warnings: [String] = []) {
        self.id = id; self.title = title; self.situation = situation; self.task = task; self.action = action; self.result = result
        self.bulletIds = bulletIds; self.warnings = warnings
    }
}

public struct MockFeedback: Codable, Hashable, Sendable {
    public var score: Int
    public var strengths: [String]
    public var improve: [String]
    public var followUp: String
}

/// Store key .interviewPrep: saved stories and a practice log.
public struct InterviewPrepState: Codable, Hashable, Sendable {
    public struct Practice: Codable, Hashable, Sendable {
        public var day: String; public var question: String; public var score: Int
        public init(day: String, question: String, score: Int) { self.day = day; self.question = question; self.score = score }
    }
    public var stories: [StarStory] = []
    public var practice: [Practice] = []
    public init() {}
}

public enum InterviewPrep {
    struct Bank: Decodable { var behavioral: [String]; var tracks: [String: [String]] }
    static let bank: Bank = {
        guard let url = Bundle.module.url(forResource: "Resources/interview_questions", withExtension: "json"),
              let d = try? Data(contentsOf: url), let b = try? JSONDecoder().decode(Bank.self, from: d) else { return Bank(behavioral: [], tracks: [:]) }
        return b
    }()

    /// Role questions from the role's track, skill questions from the gap report (no AI call), then the common behavioral set.
    public static func questions(role: String, report: GapReport?) -> [InterviewQuestion] {
        let track = CareerPaths.locate(role).flatMap { bank.tracks[$0.track.id] } ?? []
        let skills = (report?.items ?? []).filter { $0.demand.kind != "cert" }.prefix(4).map {
            $0.have ? "Tell me about your experience with \($0.demand.name)." : "This role asks for \($0.demand.name). How would you get up to speed?"
        }
        return track.map { .init(kind: "role", text: $0) } + skills.map { .init(kind: "skill", text: $0) } + bank.behavioral.map { .init(kind: "behavioral", text: $0) }
    }

    public struct SourceBullet: Hashable, Sendable { public var id: String; public var text: String; public var heading: String }
    public static func bullets(_ r: ResumeContent) -> [SourceBullet] {
        r.sections.flatMap { s in s.bullets.map { SourceBullet(id: $0.id, text: $0.text, heading: s.heading) } }.filter { !$0.text.isEmpty }
    }

    public struct StoryResult: Sendable {
        public var stories: [StarStory]
        /// AI stories rejected for citing unknown bullets or adding numbers.
        public var dropped: Int
        /// Plain-language note when the AI wasn't used (cause + what was done instead).
        public var note: String?
    }

    struct Drafts: Decodable {
        struct D: Decodable { var title: String?; var bullets: [String]?; var s: String?; var t: String?; var a: String?; var r: String? }
        var stories: [D]
    }

    /// One cached AI call; every story is checked against only the bullets it cites. Without an AI: one draft per bullet.
    public static func stories(resume: ResumeContent, ai: AI?) async -> StoryResult {
        let src = Array(bullets(resume).prefix(40))
        guard !src.isEmpty else { return StoryResult(stories: [], dropped: 0, note: "Your resume has no bullet points to build stories from. Add one on the Resumes screen.") }
        guard let ai else { return StoryResult(stories: fallback(src), dropped: 0, note: "No AI is connected, so each story starts from one resume bullet. Fill in the rest, or connect an AI.") }
        let list = src.map { "[\($0.id)] \($0.text) (\($0.heading))" }.joined(separator: "\n")
        let prompt = """
        Draft STAR stories for interviews from these resume bullets. Use ONLY facts in the bullets you cite; never add numbers, tools, employers or outcomes.
        Return JSON {"stories":[{"title":"short","bullets":["ids you used"],"s":"situation","t":"task","a":"action","r":"result"}]}, at most 6 stories. Leave a field "" if the bullets don't say.
        BULLETS:
        \(list)
        """
        do {
            let d = try await ai.cachedJSON(LLMRequest(prompt: prompt, maxTokens: 1800), key: ai.cacheKey("star-v1", [list]), kind: "star", as: Drafts.self)
            let kept = guarded(d, src)
            if kept.isEmpty { return StoryResult(stories: fallback(src), dropped: d.stories.count, note: "The AI's stories didn't stick to your resume, so each story starts from one bullet instead.") }
            return StoryResult(stories: kept, dropped: d.stories.count - kept.count, note: nil)
        } catch {
            return StoryResult(stories: fallback(src), dropped: 0, note: "The AI couldn't draft stories (\(error.localizedDescription)). Each story starts from one resume bullet instead.")
        }
    }

    static func guarded(_ d: Drafts, _ src: [SourceBullet]) -> [StarStory] {
        let byId = Dictionary(src.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return d.stories.compactMap { s in
            let ids = s.bullets ?? []
            guard !ids.isEmpty, ids.allSatisfy({ byId[$0] != nil }) else { return nil }
            let source = ids.compactMap { byId[$0] }.map { "\($0.text)\n\($0.heading)" }.joined(separator: "\n")
            let parts = [s.title, s.s, s.t, s.a, s.r].map { Text.collapse($0 ?? "") }
            var warnings: [String] = []
            for p in parts where !p.isEmpty {
                let g = Guard.check(p, source: source)
                guard g.ok, SkillPlanner.noLinks(p) else { return nil }
                warnings += g.warnings
            }
            return StarStory(title: parts[0].isEmpty ? byId[ids[0]]!.heading : parts[0], situation: parts[1], task: parts[2], action: parts[3], result: parts[4],
                             bulletIds: ids, warnings: warnings)
        }
    }

    static func fallback(_ src: [SourceBullet]) -> [StarStory] {
        src.prefix(8).map { StarStory(title: $0.heading, action: $0.text, bulletIds: [$0.id]) }
    }

    /// One AI call scoring a practice answer. Feedback lines that bring in numbers the user didn't say are dropped.
    public static func feedback(question: String, answer: String, role: String, ai: AI) async throws -> MockFeedback {
        let prompt = """
        Give interview feedback as a fair, encouraging interviewer for a "\(role)" role. Judge structure (STAR), relevance and clarity. Don't invent facts about the candidate.
        Return JSON {"score":1-5,"strengths":["..."],"improve":["..."],"followUp":"one follow-up question"}.
        QUESTION: \(question)
        ANSWER: \(answer)
        """
        let f = try await ai.json(LLMRequest(prompt: prompt, maxTokens: 600), as: MockFeedback.self)
        let source = question + "\n" + answer + "\n" + role
        let ok = { (s: String) in !s.isEmpty && Guard.check(s, source: source).ok && SkillPlanner.noLinks(s) }
        return MockFeedback(score: min(max(f.score, 1), 5), strengths: f.strengths.map(Text.collapse).filter(ok).prefix(3).map { $0 },
                            improve: f.improve.map(Text.collapse).filter(ok).prefix(3).map { $0 }, followUp: ok(Text.collapse(f.followUp)) ? Text.collapse(f.followUp) : "")
    }
}
