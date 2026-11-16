import XCTest

/// Resumes → LinkedIn & Portfolio: link checks and cited suggestions the user copies (nothing is posted to LinkedIn).
@MainActor final class ProfileOptimizerTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testSuggestionsForTheSelectedVersion() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-profile-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = "matches"
        app.launch()
        app.outlines.staticTexts["Resumes"].click()
        let open = app.buttons["resumes.profile"]
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.click()

        XCTAssertTrue(app.staticTexts["Building useful tools with data"].waitForExistence(timeout: 10), "fake AI headline kept: it cites a real bullet")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "From your resume:", "From your resume:")).firstMatch.exists, "each suggestion shows its source")
        let pasted = app.textViews["profile.pasted"]
        pasted.click(); pasted.typeText("Hello")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "profile.check").firstMatch.waitForExistence(timeout: 3), "pasted text cross-checked against the resume")
        app.buttons["profile.copy"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Copied Headline. Paste it into LinkedIn yourself."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Post"].exists || app.buttons["Send"].exists, "copy only: the user updates LinkedIn")
        app.terminate()
    }
}
