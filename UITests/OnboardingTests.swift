import XCTest

/// Wizard forward and back with data preserved, resume upload success and error paths, light/dark screenshots.
final class OnboardingTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func fixture(_ name: String) -> String { Bundle(for: Self.self).path(forResource: name, ofType: nil)! }

    func launch(dark: Bool, files: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-ui-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_TEST_FILES"] = files.map(fixture).joined(separator: ":")
        app.launchEnvironment["OFFERLANE_APPEARANCE"] = dark ? "dark" : "light"
        app.launch()
        return app
    }

    func testWizardForwardBackAndUploads() throws {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let app = launch(dark: dark, files: ["Test_Person_Resume.txt", "broken.pdf", "Manager.tex"])
            let next = app.buttons["onboarding.next"], back = app.buttons["onboarding.back"]

            XCTAssertTrue(app.staticTexts["Choose your AI"].waitForExistence(timeout: 10))
            XCTAssertFalse(back.isEnabled, "no Back on the first step")
            snap(app, "1-ai-\(mode)")
            next.click()

            XCTAssertTrue(app.staticTexts["Add your resumes"].waitForExistence(timeout: 5))
            XCTAssertFalse(next.isEnabled, "can't continue without a resume")
            app.buttons["resumes.choose"].click()
            XCTAssertTrue(app.descendants(matching: .any)["upload.error"].waitForExistence(timeout: 20), "bad file shows an error")
            XCTAssertTrue(app.staticTexts["Couldn't open that PDF. Try exporting it again, or add the .docx."].exists)
            // The identifier lands on both the icon and the text of each status line; count the texts.
            let successes = app.staticTexts.matching(identifier: "upload.success")
            XCTAssertTrue(successes.firstMatch.waitForExistence(timeout: 20))
            XCTAssertTrue(waitFor { successes.count == 2 }, "both good files parsed")
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'your LaTeX design is kept'")).firstMatch.exists)
            XCTAssertFalse(next.isEnabled, "a failed upload blocks Next until fixed or removed")
            snap(app, "2-resumes-\(mode)")

            app.buttons["Remove broken"].click()
            app.buttons["Remove"].firstMatch.click()
            XCTAssertTrue(waitFor { next.isEnabled })
            next.click()

            // About you: prefilled from the resume; an edit survives Back.
            XCTAssertTrue(app.staticTexts["Used to fill application forms. We filled in what we could from your resume — check it and add the rest."].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields["First name"].value as? String, "Test")
            XCTAssertEqual(app.textFields["Email"].value as? String, "test@example.com")
            let notice = app.textFields["Notice period"]; reveal(notice, in: app); notice.click(); notice.typeText("3 months")
            snap(app, "3-about-\(mode)")
            back.click()
            XCTAssertTrue(app.staticTexts["Add your resumes"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts.matching(identifier: "upload.success").count, 2, "uploads survive going back")
            back.click()
            XCTAssertTrue(app.staticTexts["Choose your AI"].waitForExistence(timeout: 5))
            next.click(); next.click()
            XCTAssertTrue(app.textFields["Notice period"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields["Notice period"].value as? String, "3 months", "edits survive Back and Next")

            // Search: drafted by the AI on arrival.
            next.click()
            XCTAssertTrue(app.buttons["Remove Scale AI"].waitForExistence(timeout: 15), "AI-drafted companies shown")
            XCTAssertTrue(waitFor { next.isEnabled })
            let add = app.textFields["Add company"]; reveal(add, in: app); add.click(); add.typeText("https://jobs.lever.co/acme-robotics\r")
            XCTAssertTrue(app.buttons["Remove Acme Robotics"].waitForExistence(timeout: 5), "careers URL detected")
            snap(app, "4-search-\(mode)")

            next.click()
            XCTAssertTrue(app.staticTexts["Track replies by email"].waitForExistence(timeout: 5))
            snap(app, "5-email-\(mode)")
            next.click()
            XCTAssertTrue(app.staticTexts["Notifications"].firstMatch.waitForExistence(timeout: 5))
            snap(app, "6-notifications-\(mode)")
            next.click()
            XCTAssertTrue(app.staticTexts["You're all set"].waitForExistence(timeout: 5))
            snap(app, "7-finish-\(mode)")
            app.buttons["onboarding.notNow"].click()
            XCTAssertTrue(app.outlines.staticTexts["Matches"].waitForExistence(timeout: 5), "main window after setup")
            app.terminate()
        }
    }

    /// Settings → Import, offered in the Resumes step when the previous-version (v2) folder is on this Mac.
    func testImportPreviousVersion() throws {
        // The test runner is sandboxed and can't see ~/Documents; the app can, and offers Import only when the folder exists.
        let app = launch(dark: false, files: [])
        app.buttons["onboarding.next"].click()
        let importButton = app.buttons["Import"]
        try XCTSkipUnless(importButton.waitForExistence(timeout: 5), "previous-version (v2) data isn't on this Mac")
        importButton.click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'Imported 2 resume versions'")).firstMatch.waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts.matching(identifier: "upload.success").count, 2)
        snap(app, "import-v2")
        app.buttons["onboarding.next"].click()
        XCTAssertFalse((app.textFields["First name"].value as? String ?? "").isEmpty, "profile imported")
        app.terminate()
    }

    /// Scroll the wizard until `e` sits clear of the bottom button bar.
    private func reveal(_ e: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        for _ in 0..<12 where e.frame.maxY > window.maxY - 90 {
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -120)
        }
    }

    private func waitFor(_ timeout: TimeInterval = 15, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        return cond()
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
