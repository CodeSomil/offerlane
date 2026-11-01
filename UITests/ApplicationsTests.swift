import XCTest

/// Applications board: stats, Show removed, drag a card to a new status, notes + timeline.
final class ApplicationsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testBoardDragAndRemoved() throws {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let app = XCUIApplication()
            app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-ui-" + UUID().uuidString
            app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
            app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
            app.launchEnvironment["OFFERLANE_SEED"] = "applications"
            app.launchEnvironment["OFFERLANE_APPEARANCE"] = mode
            app.launch()
            app.outlines.staticTexts["Applications"].click()
            func card(_ c: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", c + ",")).firstMatch }
            XCTAssertTrue(card("Northwind").waitForExistence(timeout: 10))
            XCTAssertFalse(card("Tailspin").exists, "rejections are hidden from the board")
            app.checkBoxes["applications.showRemoved"].click()
            XCTAssertTrue(card("Tailspin").waitForExistence(timeout: 5), "…and shown under Show removed")
            app.checkBoxes["applications.showRemoved"].click()
            snap(app, "applications-\(mode)")

            // Move via the card's context menu (the keyboard/VoiceOver alternative to dragging).
            card("Northwind").rightClick()
            app.menuItems["Move to"].hover()
            app.menuItems["Acknowledged"].click()
            card("Northwind").click()
            XCTAssertTrue(app.staticTexts["Northwind · London, UK · Acknowledged"].waitForExistence(timeout: 5), "moved from Applied to Acknowledged")
            XCTAssertTrue(app.staticTexts["moved on the board"].exists, "timeline records the change")
            snap(app, "application-detail-\(mode)")
            app.buttons["Done"].click()
            app.terminate()
        }
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
