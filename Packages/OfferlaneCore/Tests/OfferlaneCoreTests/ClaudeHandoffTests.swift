import XCTest
@testable import OfferlaneCore

/// P1.4: Route B. The bundle carries facts only; the reply is parsed leniently, Guard-checked, and lands only in Review.
final class ClaudeHandoffTests: MCPTestBase {
    func testPromptHasFactsButNoPrivateData() throws {
        let store = try makeStore()
        let j = try XCTUnwrap(try store.jobs([.tailoring]).first)
        let p = try ClaudeHandoff.prompt(for: j, store: store)
        XCTAssertTrue(p.contains("e1.1: Built a forecasting model for 120 stores"))
        XCTAssertTrue(p.contains("JOB: Data Scientist at \(j.company)"))
        XCTAssertTrue(p.contains("NEVER add tools, numbers"), "the tailoring rules travel with it")
        for secret in [plantedKey, "alex.rivera@example.com", "7700 900123", "95000", "secret-ntfy-topic-77", "hr@co"] {
            XCTAssertFalse(p.contains(secret), "\(secret) in the bundle")
        }
    }

    func testParseAcceptsFencesAndRejectsProse() throws {
        let fenced = "Here you go:\n```json\n{\"headline\":\"Data Scientist\",\"order\":{\"e1\":[\"e1.2\",\"e1.1\"]},\"cover_letter\":\"Hi\"}\n```\nGood luck!"
        XCTAssertEqual(try ClaudeHandoff.parse(fenced).order["e1"], ["e1.2", "e1.1"])
        let braces = "Sections use {ids} like {e1}. Here:\n{\"headline\":\"Data Scientist\"}"
        XCTAssertEqual(try ClaudeHandoff.parse(braces).headline, "Data Scientist")
        for bad in ["I can't help with that.", "{}", "{\"headline\": ", ""] {
            XCTAssertThrowsError(try ClaudeHandoff.parse(bad)) { XCTAssertTrue($0.plainMessage.contains("couldn't read that reply"), bad) }
        }
    }

    func testPastedReplyGoesThroughGuardToReview() async throws {
        let store = try makeStore()
        let id = try XCTUnwrap(try store.jobs([.tailoring]).first?.id)
        let lie = try ClaudeHandoff.parse(#"{"headline":"Data Scientist","rewrites":{"e1.2":"Led a team of 40 analysts"}}"#)
        do { try await ClaudeHandoff.save(lie, job: id, store: store, by: "claude-paste"); XCTFail("invented number accepted") }
        catch { XCTAssertTrue(error.plainMessage.contains("Nothing was saved")) }
        XCTAssertEqual(try store.job(id)?.status, .tailoring)
        let question = try ClaudeHandoff.parse(#"{"headline":"Data Scientist","answers":[{"q":"How did you grow sales 300%?","a":"By forecasting."}]}"#)
        do { try await ClaudeHandoff.save(question, job: id, store: store, by: "claude-paste"); XCTFail("invented number in a question") } catch {}

        let ok = try ClaudeHandoff.parse(#"{"headline":"Data Scientist","rewrites":{"e1.2":"Led 4 analysts"},"cover_letter":"I led 4 analysts."}"#)
        try await ClaudeHandoff.save(ok, job: id, store: store, by: "claude-paste")
        XCTAssertEqual(try store.job(id)?.status, .review)
        let found = try XCTUnwrap(try store.jobs([.found]).first?.id)
        do { try await ClaudeHandoff.save(ok, job: found, store: store, by: "claude-paste"); XCTFail("a paste must never approve a match") } catch {}
        XCTAssertEqual(try store.job(found)?.status, .found)
    }
}
