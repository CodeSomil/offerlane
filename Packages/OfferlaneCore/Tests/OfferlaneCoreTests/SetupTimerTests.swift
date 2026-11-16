import XCTest
@testable import OfferlaneCore

final class SetupTimerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func testTotalsPerStepIncludingBack() throws {
        var t = SetupTimer()
        t.start(at: at(0)); t.enter("ai", at: at(0))
        t.enter("resumes", at: at(40))
        t.enter("ai", at: at(50))         // Back: time keeps adding to the same step
        t.enter("resumes", at: at(60))
        t.enter("finish", at: at(150))
        let s = try XCTUnwrap(t.finish(at: at(170)))
        XCTAssertEqual(s.steps.map(\.name), ["ai", "resumes", "finish"], "first-seen order")
        XCTAssertEqual(s.steps.map(\.seconds), [50, 100, 20])
        XCTAssertEqual(s.total, 170)
        XCTAssertTrue(s.underFiveMinutes)
        XCTAssertEqual(s.line, "setup timer: ai 50s, resumes 100s, finish 20s, total 170s (under 5 min: yes)")
    }

    func testOverFiveMinutesAndSecondsOnly() throws {
        var t = SetupTimer()
        t.start(at: at(0)); t.enter("ai", at: at(0))
        let s = try XCTUnwrap(t.finish(at: at(300.4)))
        XCTAssertFalse(s.underFiveMinutes, "5:00 is not under 5 minutes")
        XCTAssertEqual(s.line, "setup timer: ai 300s, total 300s (under 5 min: no)")
    }

    func testNotStartedOrFinishedTwiceGivesNothing() {
        var t = SetupTimer()
        t.enter("ai", at: at(0))
        XCTAssertNil(t.finish(at: at(10)), "never started (e.g. opened from Settings)")
        t.start(at: at(0)); t.enter("ai", at: at(0))
        XCTAssertNotNil(t.finish(at: at(10)))
        XCTAssertNil(t.finish(at: at(20)), "one summary per first run")
    }
}
