import XCTest

final class LaunchTests: XCTestCase {
    func testSidebarNavigates() throws {
        let app = XCUIApplication()
        let home = NSTemporaryDirectory() + UUID().uuidString
        // Skip onboarding: a settings document marked as set up.
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        app.launchEnvironment["OFFERLANE_HOME"] = home
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launch()
        XCTAssertTrue(app.outlines.staticTexts["Matches"].waitForExistence(timeout: 10))
        snap(app, "todo")
        app.outlines.staticTexts["Matches"].click()
        XCTAssertTrue(app.staticTexts["No matches yet"].waitForExistence(timeout: 5), "empty state with a next action")
        XCTAssertTrue(app.buttons["Find Jobs"].firstMatch.exists)
        snap(app, "matches")
    }

    /// Saves window screenshots to $SCREENSHOT_DIR (or the test's temp dir) for visual review.
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = app.windows.firstMatch.screenshot()
        let a = XCTAttachment(screenshot: shot); a.name = name; a.lifetime = .keepAlways; add(a)
        let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? NSTemporaryDirectory()
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
