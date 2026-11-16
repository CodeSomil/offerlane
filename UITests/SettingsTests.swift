import XCTest

/// Settings round-trip: change settings, save, relaunch, and they're still there. Plus the Resumes screen.
final class SettingsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func launch(home: String, dark: Bool = false, seed: String = "matches") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]   // never block on "reopen windows?"
        app.launchEnvironment["OFFERLANE_HOME"] = home
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = seed
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

        // Unsaved-change protection: leaving asks first; Keep Editing stays put.
        app.outlines.staticTexts["Discover"].click()
        XCTAssertTrue(app.buttons["Keep Editing"].waitForExistence(timeout: 5), "leaving with unsaved edits asks first")
        XCTAssertTrue(app.buttons["Discard Changes"].exists)
        snap(app, "unsaved-guard-light")
        app.buttons["Keep Editing"].click()
        XCTAssertEqual(app.textFields["Email address"].value as? String, "me@example.com", "edits kept")
        app.buttons["Save Email Settings"].click()
        XCTAssertTrue(app.staticTexts["Email settings saved."].waitForExistence(timeout: 5))
        // AI limits: pick 25k tokens per run; it survives the relaunch below.
        let runLimit = app.popUpButtons["settings.runLimit"]
        XCTAssertTrue(runLimit.exists, "per-run AI limit is in Settings")
        runLimit.click(); app.menuItems["25k tokens"].click()
        XCTAssertTrue(app.popUpButtons["settings.tailorLimit"].exists)
        snap(app, "settings-light")
        app.terminate()

        app = launch(home: home, dark: true)
        app.outlines.staticTexts["Settings"].click()
        XCTAssertTrue(app.textFields["Email address"].waitForExistence(timeout: 10), "email tracking stays on after relaunch")
        XCTAssertEqual(app.textFields["Email address"].value as? String, "me@example.com", "address saved")
        XCTAssertEqual((app.secureTextFields["App password"].value as? String)?.isEmpty, false, "app password restored from Keychain")
        XCTAssertEqual(app.popUpButtons["settings.runLimit"].value as? String, "25k tokens", "AI limit saved")
        snap(app, "settings-dark")

        app.outlines.staticTexts["Resumes"].click()
        XCTAssertTrue(app.staticTexts["Main"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["Default"].exists)
        let ats = app.descendants(matching: .any)["resumes.ats"]
        XCTAssertTrue(ats.waitForExistence(timeout: 20), "the preview gets an ATS health check")
        XCTAssertTrue(app.staticTexts["ATS check passed"].exists, "seeded resume has a name, email and enough text")
        snap(app, "resumes-dark")
        app.terminate()
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Adzuna: switching it on asks for the user's own key; the key is kept across launches; clearing it switches Adzuna off.
    func testAdzunaKeySetup() throws {
        let home = NSTemporaryDirectory() + "offerlane-ui-" + UUID().uuidString
        var app = launch(home: home, seed: "sources")
        func openSearch() {
            app.outlines.staticTexts["Settings"].click()
            let edit = app.buttons["Edit Search…"]; XCTAssertTrue(edit.waitForExistence(timeout: 10)); edit.click()
        }
        openSearch()
        let toggle = app.descendants(matching: .any)["source.adzuna"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["adzuna.appId"].exists, "no key fields while Adzuna is off")
        toggle.click()
        let id = app.textFields["adzuna.appId"]; XCTAssertTrue(id.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["adzuna.missing"].exists, "says Adzuna is skipped without a key")
        id.click(); id.typeText("id123")
        let key = app.secureTextFields["adzuna.appKey"]; key.click(); key.typeText("SECRETKEY987")
        XCTAssertFalse(app.descendants(matching: .any)["adzuna.missing"].exists)
        app.buttons["onboarding.done"].click()
        app.terminate()

        app = launch(home: home, seed: "sources"); openSearch()
        XCTAssertTrue(app.textFields["adzuna.appId"].waitForExistence(timeout: 10), "still on after relaunch")
        XCTAssertEqual(app.textFields["adzuna.appId"].value as? String, "id123", "key kept")
        let saved = app.textFields["adzuna.appId"]; saved.click(); saved.typeKey("a", modifierFlags: .command); saved.typeKey(.delete, modifierFlags: [])
        app.buttons["onboarding.done"].click()
        app.terminate()

        app = launch(home: home, seed: "sources"); openSearch()
        XCTAssertTrue(app.descendants(matching: .any)["source.adzuna"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["adzuna.appId"].exists, "clearing the key switched Adzuna off")
        app.terminate()
    }

    /// v4 P4.4: signed out, Sync offers only sign-in and says the data is encrypted before it leaves.
    func testSyncSectionSignedOut() throws {
        let app = launch(home: NSTemporaryDirectory() + "offerlane-ui-" + UUID().uuidString)
        app.outlines.staticTexts["Settings"].click()
        let signIn = app.buttons["sync.signIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), "Sync is in Settings")
        let says = { (t: String) in app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", t, t)).firstMatch.exists }
        XCTAssertTrue(says("servers can't read it"), "it says the data is encrypted before it leaves")
        XCTAssertFalse(app.buttons["sync.now"].exists, "nothing syncs before sign-in")
        XCTAssertFalse(app.buttons["sync.create"].exists)
        app.terminate()
    }
}
