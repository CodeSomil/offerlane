import XCTest

/// Resumes: the selected version gets a health panel (score + checks) next to its preview.
@MainActor final class ResumeHealthTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testHealthPanelScoresTheSelectedVersion() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-health-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = "matches"
        app.launch()
        app.outlines.staticTexts["Resumes"].click()

        XCTAssertTrue(app.staticTexts["resumes.score"].waitForExistence(timeout: 20), "health score shown for the default version")
        let checks = app.staticTexts.matching(identifier: "resumes.check")
        XCTAssertEqual(checks.count, 6, "six checks; no role is seeded, so no keyword check")
        for check in ["Readable by applicant tracking systems", "Results in bullets"] {
            XCTAssertTrue(checks.matching(NSPredicate(format: "value BEGINSWITH %@", check)).firstMatch.exists, check)
        }
        app.terminate()
    }
}
