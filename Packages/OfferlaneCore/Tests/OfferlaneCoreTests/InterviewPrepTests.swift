import XCTest
@testable import OfferlaneCore

final class InterviewPrepTests: XCTestCase {
    func resume() -> ResumeContent {
        var r = ResumeContent()
        r.experience = [.init(id: "exp1", title: "Senior Data Scientist", company: "Acme", bullets: [
            .init(id: "exp1.b1", text: "Built a churn model in Python that cut churn by 12%."),
            .init(id: "exp1.b2", text: "Led a team of 4 analysts on forecasting."),
        ])]
        return r
    }

    func testEveryTrackHasQuestionsAndRolesGetTheirTrack() {
        XCTAssertGreaterThanOrEqual(InterviewPrep.bank.behavioral.count, 10)
        for t in CareerPaths.bundled { XCTAssertGreaterThanOrEqual(InterviewPrep.bank.tracks[t.id]?.count ?? 0, 5, t.id) }
        let q = InterviewPrep.questions(role: "Senior Data Scientist", report: nil)
        XCTAssertEqual(q.first?.kind, "role")
        XCTAssertTrue(q.contains { $0.text.contains("A/B test") })
        let unknown = InterviewPrep.questions(role: "Pastry Chef", report: nil)
        XCTAssertTrue(unknown.allSatisfy { $0.kind == "behavioral" })
    }

    func testSkillQuestionsComeFromTheGapReport() throws {
        let st = try Store()
        var j = Job(company: "A", title: "Data Scientist", location: "London", url: "https://example.com/a"); j.description = "Python and SQL."
        try st.upsert(j)
        try st.saveResume(ResumeVersion(name: "main", label: "Main", content: resume(), sourceText: "", sourceFile: "cv.txt"))
        let q = InterviewPrep.questions(role: "Data Scientist", report: try SkillPlanner.report(store: st, role: "Data Scientist")).filter { $0.kind == "skill" }
        XCTAssertTrue(q.contains { $0.text == "Tell me about your experience with Python." }, "\(q)")
        XCTAssertTrue(q.contains { $0.text.contains("SQL") && $0.text.contains("get up to speed") })
    }

    // Invariant: stories cite only real bullets and add no numbers.
    func testStoriesCiteOnlyResumeBullets() async throws {
        let ai = AI(client: FakeLLM.prototype, store: try Store())
        let res = await InterviewPrep.stories(resume: resume(), ai: ai)
        XCTAssertNil(res.note)
        XCTAssertEqual(res.stories.count, 2); XCTAssertEqual(res.dropped, 2, "invented number and unknown bullet are rejected")
        let src = InterviewPrep.bullets(resume())
        for s in res.stories {
            let cited = src.filter { s.bulletIds.contains($0.id) }
            XCTAssertEqual(cited.count, s.bulletIds.count)
            let text = cited.map { $0.text + " " + $0.heading }.joined(separator: " ")
            for p in [s.title, s.situation, s.task, s.action, s.result] { XCTAssertTrue(Guard.check(p, source: text).ok, p) }
        }
        XCTAssertEqual(res.stories.first?.title, "Senior Data Scientist @ Acme", "empty AI title falls back to the bullet's heading")
    }

    func testFallbackWithoutAIOrWhenAIFails() async throws {
        let none = await InterviewPrep.stories(resume: resume(), ai: nil)
        XCTAssertEqual(none.stories.map(\.action), resume().sections[0].bullets.map(\.text))
        XCTAssertNotNil(none.note)
        let broken = AI(client: FakeLLM(rules: [{ _ in "not json" }]), store: nil)
        let failed = await InterviewPrep.stories(resume: resume(), ai: broken)
        XCTAssertEqual(failed.stories.count, 2); XCTAssertTrue(failed.note?.contains("couldn't") == true)
        let empty = await InterviewPrep.stories(resume: ResumeContent(), ai: nil)
        XCTAssertTrue(empty.stories.isEmpty); XCTAssertNotNil(empty.note)
    }

    func testFeedbackDropsInventedNumbersAndClampsScore() async throws {
        let ai = AI(client: FakeLLM.prototype, store: nil)
        let f = try await InterviewPrep.feedback(question: "Tell me about yourself.", answer: "I build models.", role: "Data Scientist", ai: ai)
        XCTAssertEqual(f.score, 4)
        XCTAssertEqual(f.improve, ["Say what the result was."], "the 40% line isn't in the answer")
        XCTAssertFalse(f.followUp.isEmpty)
        let wild = AI(client: FakeLLM(rules: [{ _ in "{\"score\":9,\"strengths\":[],\"improve\":[],\"followUp\":\"\"}" }]), store: nil)
        let w = try await InterviewPrep.feedback(question: "Q", answer: "A", role: "R", ai: wild)
        XCTAssertEqual(w.score, 5)
    }

    func testStateRoundTripsInStore() throws {
        let st = try Store()
        var s = InterviewPrepState(); s.stories = [StarStory(title: "T", action: "A", bulletIds: ["exp1.b1"])]
        s.practice = [.init(day: "2026-11-10", question: "Q", score: 3)]
        try st.set(.interviewPrep, s)
        XCTAssertEqual(try st.get(.interviewPrep, as: InterviewPrepState.self), s)
    }
}
