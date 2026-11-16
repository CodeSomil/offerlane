import XCTest

/// Launch-to-interactive and scrolling budgets. Times are attached to the test report.
final class PerformanceTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(seed: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]   // never block on "reopen windows?"
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-perf-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_PERF"] = "1"
        if let seed { app.launchEnvironment["OFFERLANE_SEED"] = seed }
        app.launch(); return app
    }

    /// Process start → main window showing its data, measured inside the app. Budget: under 1 second.
    func testLaunchToInteractive() throws {
        var samples: [Int] = []
        for _ in 0..<3 {
            let app = launch(seed: "matches")
            let probe = app.staticTexts["perf.launchMillis"]
            XCTAssertTrue(probe.waitForExistence(timeout: 10))
            samples.append(Int(probe.label) ?? Int((probe.value as? String) ?? "") ?? .max)
            app.terminate()
        }
        let best = samples.min() ?? .max, median = samples.sorted()[samples.count / 2]
        record("launch-to-interactive ms: \(samples) (median \(median))")
        // The first launch after a build pays one-off dyld/cache costs; the median is the honest number.
        XCTAssertLessThan(median, 1000, "launch to interactive should be under 1 s (best \(best) ms)")
    }

    /// 2,000+ roles: the list stays smooth (lazy rows) while scrolling end to end.
    func testScrollManyMatches() throws {
        let app = launch(seed: "many")
        let list = app.descendants(matching: .any)["matches.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))
        // Scroll at a window coordinate: resolving the list element on every gesture would time
        // XCUITest's accessibility snapshot of 2,000 rows rather than the app.
        let point = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
        let start = Date()
        for _ in 0..<25 { point.scroll(byDeltaX: 0, deltaY: -800) }
        for _ in 0..<25 { point.scroll(byDeltaX: 0, deltaY: 800) }
        let seconds = Date().timeIntervalSince(start)
        record(String(format: "50 scroll gestures over 2,000+ rows: %.2f s", seconds))
        XCTAssertTrue(app.buttons["Find Jobs"].isHittable, "still responsive after scrolling")
        XCTAssertLessThan(seconds, 30, "scrolling a long list must not stall")
        app.terminate()
    }

    private func record(_ text: String) {
        print("PERF " + text)
        let a = XCTAttachment(string: text); a.name = "perf"; a.lifetime = .keepAlways; add(a)
    }
}
