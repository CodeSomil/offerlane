import XCTest

/// P1 shell: ⌘K palette reaches screens and roles from the keyboard; toasts land in the notifications popover.
final class PaletteTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testPaletteAndNotifications() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-ui-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = "matches"
        app.launch()
        XCTAssertTrue(app.staticTexts["Senior Data Scientist, Forecasting"].waitForExistence(timeout: 10))

        // Screen by keyboard only: ⌘K, type, Return.
        app.typeKey("k", modifierFlags: .command)
        let query = app.textFields["palette.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.typeText("pipe\r")
        XCTAssertFalse(query.waitForExistence(timeout: 1), "palette closes after running")
        XCTAssertTrue(app.descendants(matching: .any)["applications.mode"].waitForExistence(timeout: 5), "on Pipeline")

        // Role by title: the only match, Return shows it on Discover.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.typeText("Forecasting\r")
        XCTAssertTrue(app.staticTexts["Senior Data Scientist, Forecasting"].waitForExistence(timeout: 5), "role shown on Discover")

        // A toast is kept in the notifications popover.
        let bell = app.buttons["notifications"]
        XCTAssertTrue(bell.exists)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'decline.'")).firstMatch.click()
        XCTAssertTrue(app.staticTexts["Declined. It won't come back in later searches."].waitForExistence(timeout: 5))
        XCTAssertEqual(bell.label, "Notifications, 1 new")
        bell.click()
        XCTAssertTrue(app.descendants(matching: .any)["notice"].waitForExistence(timeout: 5))
        XCTAssertEqual(bell.label, "Notifications", "opening marks them read")
        app.terminate()
    }
}
