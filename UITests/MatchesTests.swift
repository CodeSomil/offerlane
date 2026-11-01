import XCTest

/// Gate 1: approve and decline roles, undo a decline, To Do reflects it. Light and dark screenshots.
final class MatchesTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func launch(dark: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-ui-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = "matches"
        app.launchEnvironment["OFFERLANE_APPEARANCE"] = dark ? "dark" : "light"
        app.launch(); return app
    }

    func testApproveDeclineUndo() throws {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let app = launch(dark: dark)
            XCTAssertTrue(app.staticTexts["Senior Data Scientist, Forecasting"].waitForExistence(timeout: 10), "strong match on To Do")
            snap(app, "todo-\(mode)")
            app.outlines.staticTexts["Matches"].click()
            XCTAssertTrue(app.staticTexts["Machine Learning Engineer"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["Data Analyst"].exists, "weaker matches start collapsed")
            app.buttons["matches.toggleWeaker"].click()
            XCTAssertTrue(app.staticTexts["Data Analyst"].waitForExistence(timeout: 3))
            app.buttons["matches.toggleWeaker"].click()
            snap(app, "matches-\(mode)")

            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'decline.'")).element(boundBy: 1).click()
            XCTAssertTrue(app.staticTexts["Declined. It won't come back in later searches."].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["Machine Learning Engineer"].exists)
            app.buttons["Undo"].click()
            XCTAssertTrue(app.staticTexts["Machine Learning Engineer"].waitForExistence(timeout: 5), "undo restores the role")

            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'approve.'")).firstMatch.click()
            XCTAssertTrue(app.staticTexts["Approved. Offerlane will tailor your resume next."].waitForExistence(timeout: 5))
            app.outlines.staticTexts["To Do"].click()
            XCTAssertTrue(app.staticTexts["Senior Data Scientist, Forecasting"].waitForExistence(timeout: 5))
            // Tailoring runs in the background straight away, so the role may already be waiting for review.
            let tailoring = app.staticTexts["Globex · Tailoring"], review = app.staticTexts["Globex · Review resume"]
            XCTAssertTrue(waitFor { tailoring.exists || review.exists }, "approved role is in progress")
            app.outlines.staticTexts["Activity"].click()
            XCTAssertTrue(app.staticTexts["approved role"].waitForExistence(timeout: 5))
            snap(app, "activity-\(mode)")
            app.terminate()
        }
    }

    private func waitFor(_ timeout: TimeInterval = 10, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        return cond()
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
