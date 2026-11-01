import XCTest

/// Gate 2: an approved role is tailored in the background, then reviewed (diff, guard, edit + rebuild) and approved.
final class ReviewTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testTailorReviewEditApprove() throws {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let app = XCUIApplication()
            app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-ui-" + UUID().uuidString
            app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
            app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
            app.launchEnvironment["OFFERLANE_SEED"] = "matches"
            app.launchEnvironment["OFFERLANE_APPEARANCE"] = mode
            app.launch()

            XCTAssertTrue(app.staticTexts["Senior Data Scientist, Forecasting"].waitForExistence(timeout: 10))
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'approve.'")).firstMatch.click()
            let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'review.open.'")).firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 30), "tailored in the background and waiting for review")
            open.click()

            XCTAssertTrue(app.staticTexts["1 invented claim blocked"].waitForExistence(timeout: 10), "guard warning visible")
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH 'Tailored: Reworded:'")).firstMatch.exists, "tailored text shown")
            XCTAssertTrue(app.staticTexts["ATS check passed"].exists)
            snap(app, "review-\(mode)")

            app.buttons["review.edit"].click()
            XCTAssertTrue(app.buttons["Rebuild PDF"].waitForExistence(timeout: 5))
            snap(app, "review-edit-\(mode)")
            app.buttons["Rebuild PDF"].click()
            XCTAssertTrue(app.buttons["review.approve"].waitForExistence(timeout: 20), "back from edit mode after rebuilding")

            app.buttons["review.approve"].click()
            XCTAssertTrue(app.staticTexts["Resume approved. The Apply window will open it next."].waitForExistence(timeout: 5))
            // Approve & Apply hands the role to the Apply window straight away.
            let states = ["Ready to apply", "Applying", "Ready to submit", "Needs you"].map { app.staticTexts["Globex · \($0)"] }
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline && !states.contains(where: { $0.exists }) { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
            XCTAssertTrue(states.contains(where: { $0.exists }), "approved resume moves into the apply stage")
            app.terminate()
        }
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
