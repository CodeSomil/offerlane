import XCTest

/// Pipeline → Insights: reply rates by resume version, source and role type, plus the weekly lines.
@MainActor final class InsightsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testInsightsShowRatesForSubmittedApplications() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-insights-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = "applications"
        app.launch()
        app.outlines.staticTexts["Pipeline"].click()
        app.descendants(matching: .any)["applications.mode"].radioButtons["Insights"].click()

        let lines = app.staticTexts.matching(identifier: "insights.line")
        XCTAssertTrue(lines.firstMatch.waitForExistence(timeout: 10), "weekly insights shown")
        XCTAssertTrue(lines.matching(NSPredicate(format: "value BEGINSWITH %@", "This week: 4 sent")).firstMatch.exists)
        XCTAssertTrue(lines.matching(NSPredicate(format: "value BEGINSWITH %@", "Overall: 50% reply rate")).firstMatch.exists, "interview + rejection of 4")
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(identifier: "insights.row").count, 3, "one row per breakdown at least")
        app.terminate()
    }
}
