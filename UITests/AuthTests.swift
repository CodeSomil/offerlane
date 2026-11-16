import XCTest

/// Accounts: welcome → create a local profile → claim v0.1 data → stay signed in across relaunch → sign out → sign back in.
final class AuthTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(home: String, seed: Bool, dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OFFERLANE_HOME"] = home
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_AUTH"] = "1"          // test the real sign-in flow
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_APPEARANCE"] = dark ? "dark" : "light"
        if seed { app.launchEnvironment["OFFERLANE_SEED"] = "matches" }   // a v0.1 install waiting to be claimed
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]   // no "reopen windows?" prompt
        app.launch(); return app
    }

    func testProfileClaimSessionSignOutSignIn() throws {
        let home = NSTemporaryDirectory() + "offerlane-auth-" + UUID().uuidString
        var app = launch(home: home, seed: true)

        XCTAssertTrue(app.staticTexts["Welcome"].waitForExistence(timeout: 10), "signed-out launch shows the welcome screen")
        XCTAssertFalse(app.buttons["auth.google"].isEnabled, "Google sign-in disabled while the client ID is a placeholder")
        XCTAssertTrue(app.staticTexts["Google sign-in isn't set up in this copy of Offerlane yet. Use email and password instead."].exists)
        snap(app, "welcome-light")

        app.buttons["auth.useEmail"].click()
        type(app.textFields["auth.name"], "Test Person")
        type(app.textFields["auth.email"], "test@example.com")
        type(app.secureTextFields["auth.password"], "short")
        XCTAssertTrue(app.descendants(matching: .any)["auth.strength"].waitForExistence(timeout: 3), "strength meter")
        XCTAssertFalse(app.buttons["auth.create"].isEnabled, "weak password can't be used")
        type(app.secureTextFields["auth.password"], " but now long enough 42!")
        type(app.secureTextFields["auth.confirm"], "short but now long enough 42!")
        snap(app, "create-profile-light")
        XCTAssertTrue(app.buttons["auth.create"].isEnabled)
        app.buttons["auth.create"].click()

        XCTAssertTrue(app.staticTexts["Bring in your existing data?"].waitForExistence(timeout: 15), "v0.1 data offered to the first profile")
        snap(app, "claim-data-light")
        app.buttons["claim.use"].click()
        XCTAssertTrue(app.staticTexts["Senior Data Scientist, Forecasting"].waitForExistence(timeout: 15), "claimed roles appear in the profile")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH 'Your existing data is now in this profile'")).firstMatch.exists)
        app.terminate()

        // Relaunch: still signed in, straight to the main window.
        app = launch(home: home, seed: false)
        XCTAssertTrue(app.staticTexts["Senior Data Scientist, Forecasting"].waitForExistence(timeout: 10), "session survives a restart")
        XCTAssertFalse(app.staticTexts["Welcome"].exists)

        // Sign out from Settings; data stays.
        app.outlines.staticTexts["Settings"].click()
        XCTAssertTrue(app.buttons["settings.signOut"].waitForExistence(timeout: 5))
        snap(app, "settings-profile-light")
        app.buttons["settings.signOut"].click()
        app.buttons["Sign Out"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Sign in"].waitForExistence(timeout: 10), "signed out → sign-in form (email remembered)")
        XCTAssertEqual(app.textFields["auth.email"].value as? String, "test@example.com")

        type(app.secureTextFields["auth.password"], "wrong password")
        app.buttons["auth.signIn"].click()
        let error = app.descendants(matching: .any)["auth.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10), "wrong password explained")
        snap(app, "sign-in-error-light")

        let pw = app.secureTextFields["auth.password"]
        pw.click(); pw.typeKey("a", modifierFlags: .command); pw.typeKey(.delete, modifierFlags: [])
        pw.typeText("short but now long enough 42!\r")
        XCTAssertTrue(app.staticTexts["Senior Data Scientist, Forecasting"].waitForExistence(timeout: 15), "signed back in; data was kept")
        app.terminate()
    }

    func testWelcomeDark() throws {
        let app = launch(home: NSTemporaryDirectory() + "offerlane-auth-" + UUID().uuidString, seed: false, dark: true)
        XCTAssertTrue(app.staticTexts["Welcome"].waitForExistence(timeout: 10))
        snap(app, "welcome-dark")
        app.buttons["auth.useEmail"].click()
        XCTAssertTrue(app.staticTexts["Create your profile"].waitForExistence(timeout: 5))
        app.buttons["Back"].click()
        XCTAssertTrue(app.staticTexts["Welcome"].waitForExistence(timeout: 5), "Back returns to the choice")
        app.terminate()
    }

    private func type(_ e: XCUIElement, _ text: String) {
        XCTAssertTrue(e.waitForExistence(timeout: 5)); e.click(); e.typeText(text)
    }
    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
