import XCTest

/// README screenshots: every main screen with demo data (OFFERLANE_SEED=showcase), light and dark, after each screen has settled.
/// Runs only from scripts/screenshots.sh (TEST_RUNNER_OFFERLANE_SCREENSHOTS=1), which copies the images into docs/screenshots.
@MainActor final class ScreenshotTests: XCTestCase {
    private let screens = ["Today", "Discover", "Pipeline", "Goals", "Skills", "Interview Prep", "Resumes", "Connect AI"]

    func testReadmeScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OFFERLANE_SCREENSHOTS"] == "1", "only for scripts/screenshots.sh")
        for mode in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
            app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-shots-" + UUID().uuidString
            app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
            app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
            app.launchEnvironment["OFFERLANE_SEED"] = "showcase"
            app.launchEnvironment["OFFERLANE_APPEARANCE"] = mode
            app.launch()
            XCTAssertTrue(app.staticTexts["Senior Data Scientist, Forecasting"].waitForExistence(timeout: 10))
            for screen in screens {
                app.outlines.staticTexts[screen].click()
                settle()  // the screen cross-fades in; a snap during the fade shows two screens at once
                snap(app, "readme-\(screen.lowercased().replacingOccurrences(of: " ", with: "-"))-\(mode)")
                if screen == "Pipeline" {
                    let insights = app.radioButtons["Insights"].exists ? app.radioButtons["Insights"] : app.buttons["Insights"]
                    if insights.exists { insights.click(); settle(); snap(app, "readme-insights-\(mode)") }
                }
            }
            app.terminate()
        }
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(1.5)) }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
