import XCTest

/// Wizard forward and back with data preserved, resume upload success and error paths, light/dark screenshots.
final class OnboardingTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func fixture(_ name: String) -> String { Bundle(for: Self.self).path(forResource: name, ofType: nil)! }

    func launch(dark: Bool, files: [String], env: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OFFERLANE_LEGACY_DIR"] = "/nonexistent"   // never the real ~/Documents data
        app.launchEnvironment.merge(env) { $1 }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]   // never block on "reopen windows?"
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

            // Step 4 of 4: the search is drafted from the resume; Find Jobs is one click away.
            XCTAssertTrue(app.staticTexts["Ready to find jobs"].waitForExistence(timeout: 5))
            let findNow = app.buttons["onboarding.findNow"]
            XCTAssertTrue(app.staticTexts["finish.titles"].waitForExistence(timeout: 15), "titles drafted automatically")
            XCTAssertTrue(waitFor { findNow.isEnabled }, "Find Jobs ready without visiting any optional screen")
            XCTAssertFalse(next.exists, "the last step has no Next")
            snap(app, "3-ready-\(mode)")

            // Optional: About you, prefilled from the resume; edits survive leaving and coming back.
            app.buttons["finish.editAbout"].click()
            XCTAssertTrue(app.staticTexts["Used to fill application forms. We filled in what we could from your resume — check it and add the rest."].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields["First name"].value as? String, "Test")
            XCTAssertEqual(app.textFields["Email"].value as? String, "test@example.com")
            let notice = app.textFields["Notice period"]; reveal(notice, in: app); notice.click(); notice.typeText("3 months")
            snap(app, "4-about-\(mode)")
            app.buttons["onboarding.done"].click()
            XCTAssertTrue(app.staticTexts["Ready to find jobs"].waitForExistence(timeout: 5), "Done returns to the last step")

            // Back through the main steps keeps everything.
            back.click()
            XCTAssertTrue(app.staticTexts["Add your resumes"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts.matching(identifier: "upload.success").count, 2, "uploads survive going back")
            back.click()
            XCTAssertTrue(app.staticTexts["Choose your AI"].waitForExistence(timeout: 5))
            next.click(); next.click()
            XCTAssertTrue(app.staticTexts["Ready to find jobs"].waitForExistence(timeout: 5))
            app.buttons["finish.editAbout"].click()
            XCTAssertTrue(app.textFields["Notice period"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields["Notice period"].value as? String, "3 months", "edits survive Back and Next")
            back.click()

            // Optional: Search.
            app.buttons["finish.editSearch"].click()
            XCTAssertTrue(app.buttons["Remove Scale AI"].waitForExistence(timeout: 15), "AI-drafted companies shown")
            let add = app.textFields["Add company"]; reveal(add, in: app); add.click(); add.typeText("https://jobs.lever.co/acme-robotics\r")
            XCTAssertTrue(app.buttons["Remove Acme Robotics"].waitForExistence(timeout: 5), "careers URL detected")
            snap(app, "5-search-\(mode)")
            app.buttons["onboarding.done"].click()

            // Optional: Email and Notifications.
            XCTAssertTrue(app.buttons["finish.editEmail"].waitForExistence(timeout: 5))
            app.buttons["finish.editEmail"].click()
            XCTAssertTrue(app.staticTexts["Track replies by email"].waitForExistence(timeout: 5))
            snap(app, "6-email-\(mode)")
            back.click()
            app.buttons["finish.editNotifications"].click()
            XCTAssertTrue(app.staticTexts["Notifications"].firstMatch.waitForExistence(timeout: 5))
            snap(app, "7-notifications-\(mode)")
            back.click()

            XCTAssertTrue(app.staticTexts["Ready to find jobs"].waitForExistence(timeout: 5))
            app.buttons["onboarding.notNow"].click()
            XCTAssertTrue(app.outlines.staticTexts["Discover"].waitForExistence(timeout: 5), "main window after setup")
            app.terminate()
        }
    }

    /// Settings → Import, offered in the Resumes step when a previous-version (v2) folder exists.
    /// Uses a tiny synthetic v2 folder, never the real ~/Documents data (importer details: core ImporterTests).
    func testImportPreviousVersion() throws {
        let app = launch(dark: false, files: [], env: ["OFFERLANE_LEGACY_DIR": try makeLegacyFolder().path])
        app.buttons["onboarding.next"].click()
        let importButton = app.buttons["Import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5), "Import offered when the v2 folder exists")
        importButton.click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'Imported 2 resume versions'")).firstMatch.waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts.matching(identifier: "upload.success").count, 2)
        snap(app, "import-v2")
        app.buttons["onboarding.next"].click()
        app.buttons["finish.editAbout"].click()
        XCTAssertFalse((app.textFields["First name"].value as? String ?? "").isEmpty, "profile imported")
        app.terminate()
    }

    /// A slow import says so after the timeout, offers no retry while it runs, and a late finish replaces the message.
    func testImportTimeoutThenLateFinish() throws {
        let app = launch(dark: false, files: [], env: ["OFFERLANE_LEGACY_DIR": try makeLegacyFolder().path,
                                                       "OFFERLANE_IMPORT_TIMEOUT": "2", "OFFERLANE_IMPORT_STALL": "6"])
        app.buttons["onboarding.next"].click()
        XCTAssertTrue(app.buttons["Import"].waitForExistence(timeout: 5))
        app.buttons["Import"].click()
        let slow = app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH %@", "The import hasn't finished after 2 seconds")).firstMatch
        XCTAssertTrue(slow.waitForExistence(timeout: 5), "timeout explained")
        XCTAssertFalse(app.buttons["Try Again"].exists, "no retry while the import still runs")
        let done = app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'Imported 2 resume versions'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 15), "late finish shows the report")
        XCTAssertFalse(slow.exists, "timeout message cleared")
        app.terminate()
    }

    /// A minimal v2 data folder: a profile and two resume versions.
    private func makeLegacyFolder() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("offerlane-v2-" + UUID().uuidString)
        func write(_ path: String, _ text: String) throws {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("profile.json", #"{"personal": {"first_name": "Test", "last_name": "Person", "email": "test@example.com"}, "work": {}, "education": {}, "authorization": {}, "eeo": {}, "misc": {}, "prefs": {}}"#)
        try write("resumes/default.json", #"{"name": "ic"}"#)
        for (v, label) in [("ic", "Individual contributor"), ("lead", "Team lead")] {
            try write("resumes/\(v)/resume.json", #"{"variant": "\#(v)", "label": "\#(label)", "format": "html", "links": {}, "name": "Test Person", "summary": "Data scientist."}"#)
            try write("resumes/\(v)/source.txt", "Test Person\nData scientist.")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
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
