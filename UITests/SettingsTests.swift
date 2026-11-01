import XCTest

/// Settings round-trip: change settings, save, relaunch, and they're still there. Plus the Resumes screen.
final class SettingsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func launch(home: String, dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OFFERLANE_HOME"] = home
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = "matches"
        app.launchEnvironment["OFFERLANE_APPEARANCE"] = dark ? "dark" : "light"
        app.launch(); return app
    }

    func testSettingsRoundTripAndResumes() throws {
        let home = NSTemporaryDirectory() + "offerlane-ui-" + UUID().uuidString
        var app = launch(home: home)
        app.outlines.staticTexts["Settings"].click()
        let emailToggle = app.switches["email.enabled"]
        XCTAssertTrue(emailToggle.waitForExistence(timeout: 10))
        emailToggle.click()
        let addr = app.textFields["Email address"]; XCTAssertTrue(addr.waitForExistence(timeout: 5)); addr.click(); addr.typeText("me@example.com")
        let pw = app.secureTextFields["App password"]; pw.click(); pw.typeText("abcd efgh ijkl mnop")
        app.buttons["Save Email Settings"].click()
        XCTAssertTrue(app.staticTexts["Email settings saved."].waitForExistence(timeout: 5))
        snap(app, "settings-light")
        app.terminate()

        app = launch(home: home, dark: true)
        app.outlines.staticTexts["Settings"].click()
        XCTAssertTrue(app.textFields["Email address"].waitForExistence(timeout: 10), "email tracking stays on after relaunch")
        XCTAssertEqual(app.textFields["Email address"].value as? String, "me@example.com", "address saved")
        XCTAssertEqual((app.secureTextFields["App password"].value as? String)?.isEmpty, false, "app password restored from Keychain")
        snap(app, "settings-dark")

        app.outlines.staticTexts["Resumes"].click()
        XCTAssertTrue(app.staticTexts["Main"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["Default"].exists)
        sleep(2)
        snap(app, "resumes-dark")
        app.terminate()
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
