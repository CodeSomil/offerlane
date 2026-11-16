import XCTest

/// Gate 1 on Find: approve and decline roles, undo a decline; Review and Activity reflect it. Light and dark screenshots.
final class MatchesTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func launch(dark: Bool, seed: String = "matches") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]   // never block on "reopen windows?"
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-ui-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = seed
        app.launchEnvironment["OFFERLANE_APPEARANCE"] = dark ? "dark" : "light"
        app.launch(); return app
    }

    func testTabsAndRemoteFilter() throws {
        let app = launch(dark: false)
        XCTAssertTrue(app.staticTexts["Senior Data Scientist, Forecasting"].waitForExistence(timeout: 10))
        app.checkBoxes["matches.remoteOnly"].click()
        XCTAssertFalse(app.staticTexts["Senior Data Scientist, Forecasting"].waitForExistence(timeout: 2), "London role hidden by Remote only")
        XCTAssertTrue(app.staticTexts["Machine Learning Engineer"].exists, "remote role stays")
        app.checkBoxes["matches.remoteOnly"].click()
        app.radioButtons.matching(NSPredicate(format: "label BEGINSWITH 'Stretch'")).firstMatch.click()
        XCTAssertFalse(app.staticTexts["Senior Data Scientist, Forecasting"].waitForExistence(timeout: 2), "best-fit roles aren't on the Stretch tab")
        app.terminate()
    }

    /// Adzuna's terms: each advert shows an "Adzuna" label of at least 116×23 that links to Adzuna.
    func testAdzunaResultShowsAttribution() throws {
        let app = launch(dark: false, seed: "sources")
        let discover = app.outlines.staticTexts["Discover"]; XCTAssertTrue(discover.waitForExistence(timeout: 10)); discover.click()
        let label = app.links["adzuna.attribution"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(label.frame.width, 116); XCTAssertGreaterThanOrEqual(label.frame.height, 23)
        XCTAssertEqual(label.label, "Jobs by Adzuna")
        XCTAssertEqual(label.value as? String, "www.adzuna.com.au", "the badge links to the advert's own country site")
        XCTAssertEqual(app.links.matching(identifier: "adzuna.attribution").count, 1, "only on the Adzuna advert")
        XCTAssertTrue(app.links["via Adzuna"].exists, "the advert itself links to Adzuna")
        app.terminate()
    }

    func testApproveDeclineUndo() throws {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let app = launch(dark: dark)
            XCTAssertTrue(app.staticTexts["Senior Data Scientist, Forecasting"].waitForExistence(timeout: 10), "strong match on Find, the start screen")
            XCTAssertTrue(app.staticTexts["Machine Learning Engineer"].exists)
            XCTAssertFalse(app.staticTexts["Data Analyst"].exists, "weaker matches start collapsed")
            app.buttons["matches.toggleWeaker"].click()
            XCTAssertTrue(app.staticTexts["Data Analyst"].waitForExistence(timeout: 3))
            app.buttons["matches.toggleWeaker"].click()
            snap(app, "find-\(mode)")

            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'decline.'")).element(boundBy: 1).click()
            XCTAssertTrue(app.staticTexts["Declined. It won't come back in later searches."].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["Machine Learning Engineer"].exists)
            app.buttons["Undo"].click()
            XCTAssertTrue(app.staticTexts["Machine Learning Engineer"].waitForExistence(timeout: 5), "undo restores the role")

            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'approve.'")).firstMatch.click()
            XCTAssertTrue(app.staticTexts["Approved. Offerlane will tailor your resume next."].waitForExistence(timeout: 5))
            app.outlines.staticTexts["Review"].click()
            XCTAssertTrue(app.staticTexts["Senior Data Scientist, Forecasting"].waitForExistence(timeout: 5))
            // Tailoring runs in the background straight away, so the role may already be waiting for review.
            let tailoring = app.staticTexts["Globex · Tailoring"], review = app.staticTexts["Globex · Review resume"]
            XCTAssertTrue(waitFor { tailoring.exists || review.exists }, "approved role is in progress")
            snap(app, "review-queue-\(mode)")
            app.outlines.staticTexts["Pipeline"].click()
            app.radioButtons["Activity"].click()
            XCTAssertTrue(app.staticTexts["approved role"].waitForExistence(timeout: 5))
            snap(app, "activity-\(mode)")
            app.terminate()
        }
    }

    /// Keyboard triage: J moves down the list, D declines the selected role (and Undo brings it back), A approves.
    func testKeyboardTriage() throws {
        let app = launch(dark: false)
        let first = app.staticTexts["Senior Data Scientist, Forecasting"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["matches.keys"].exists, "the key hints are on screen")
        first.click()                       // selects the top row and focuses the list
        app.typeKey("j", modifierFlags: []) // second row
        app.typeKey("d", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Declined. It won't come back in later searches."].waitForExistence(timeout: 5), "D declines")
        XCTAssertTrue(first.exists, "J moved off the top row, so the top role is still there")
        app.buttons["Undo"].click()
        first.click()
        app.typeKey("a", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Approved. Offerlane will tailor your resume next."].waitForExistence(timeout: 5), "A approves")
        XCTAssertTrue(waitFor { !first.exists }, "the approved role leaves Discover")
        app.terminate()
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
