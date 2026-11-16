import XCTest

final class LaunchTests: XCTestCase {
    func testSidebarNavigates() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]   // never block on "reopen windows?"
        let home = NSTemporaryDirectory() + UUID().uuidString
        // Skip onboarding: a settings document marked as set up.
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        app.launchEnvironment["OFFERLANE_HOME"] = home
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launch()
        XCTAssertTrue(app.outlines.staticTexts["Discover"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No matches yet"].waitForExistence(timeout: 5), "Find is the start screen; empty state with a next action")
        XCTAssertTrue(app.buttons["Find Jobs"].firstMatch.exists)
        snap(app, "find-empty")
        for item in ["Today", "Discover", "Review", "Pipeline", "Skills", "Resumes", "Connect AI", "Settings"] {
            XCTAssertTrue(app.outlines.staticTexts[item].exists, "\(item) in the sidebar")
        }
        // Keyboard: ⌘3 Review, ⌘4 Pipeline, ⌘2 back to Discover.
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["You're all caught up"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Go to Discover"].exists, "empty Review offers one clear action")
        snap(app, "review-empty")
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["No applications yet"].waitForExistence(timeout: 5))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["No matches yet"].waitForExistence(timeout: 5))
    }

    /// The branded launch screen (logo, wordmark, lane motif) on a normal launch.
    func testSplash() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]   // never block on "reopen windows?"
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SPLASH"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        snap(app, "splash")
        // It never blocks: the app is usable straight away and the splash fades on its own.
        XCTAssertTrue(app.outlines.staticTexts["Discover"].waitForExistence(timeout: 5))
        let splash = app.descendants(matching: .any)["splash"]
        let end = Date().addingTimeInterval(5)
        while splash.exists && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertFalse(splash.exists, "splash fades out by itself")
    }

    /// Saves window screenshots to $SCREENSHOT_DIR (or the test's temp dir) for visual review.
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = app.windows.firstMatch.screenshot()
        let a = XCTAttachment(screenshot: shot); a.name = name; a.lifetime = .keepAlways; add(a)
        let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? NSTemporaryDirectory()
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
