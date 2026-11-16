import XCTest

/// Applications board: stats, Show removed, drag a card to a new status, notes + timeline.
final class ApplicationsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Pipeline detail: the company brief shows only lines the posting supports, and the interview date drives Today's calendar export.
    @MainActor func testCompanyBriefAndInterviewDate() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-ui-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = "applications"
        app.launch()
        app.outlines.staticTexts["Pipeline"].click()
        let contoso = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Contoso,'")).firstMatch
        XCTAssertTrue(contoso.waitForExistence(timeout: 10))
        contoso.click()

        app.buttons["application.brief"].click()
        let point = app.descendants(matching: .any)["brief.point"]
        XCTAssertTrue(point.waitForExistence(timeout: 10), "the brief lists what the posting states")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "brief.point").count, 1, "the invented line is dropped")
        XCTAssertTrue(app.descendants(matching: .any)["brief.note"].exists, "the user is told a line was removed")
        XCTAssertTrue(app.descendants(matching: .any)["brief.question"].exists)
        app.sheets.sheets.buttons["Done"].click()   // the brief sits on top of the detail sheet

        // The seeded interview is dated; unscheduling it removes the calendar export from Today, rescheduling brings it back.
        let scheduled = app.checkBoxes["application.scheduled"]
        XCTAssertTrue(scheduled.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["application.interviewAt"].exists, "a dated interview shows its time")
        scheduled.click()
        app.sheets.buttons["Done"].firstMatch.click()
        app.outlines.staticTexts["Today"].click()
        XCTAssertTrue(app.descendants(matching: .any)["home.week.approved"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["home.exportCalendar"].exists, "no dated interviews, nothing to export")
        app.outlines.staticTexts["Pipeline"].click()
        XCTAssertTrue(contoso.waitForExistence(timeout: 5)); contoso.click()
        XCTAssertTrue(scheduled.waitForExistence(timeout: 5)); scheduled.click()
        app.sheets.buttons["Done"].firstMatch.click()
        app.outlines.staticTexts["Today"].click()
        XCTAssertTrue(app.buttons["home.exportCalendar"].waitForExistence(timeout: 10), "a dated interview can be exported")
        app.terminate()
    }

    func testBoardDragAndRemoved() throws {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let app = XCUIApplication()
            app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]   // never block on "reopen windows?"
            app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-ui-" + UUID().uuidString
            app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
            app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
            app.launchEnvironment["OFFERLANE_SEED"] = "applications"
            app.launchEnvironment["OFFERLANE_APPEARANCE"] = mode
            app.launch()
            app.outlines.staticTexts["Pipeline"].click()
            func card(_ c: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", c + ",")).firstMatch }
            XCTAssertTrue(card("Northwind").waitForExistence(timeout: 10))
            XCTAssertFalse(card("Tailspin").exists, "rejections are hidden from the board")
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'board.folded.'")).firstMatch.exists,
                          "empty stages fold into a strip")
            app.checkBoxes["applications.showRemoved"].click()
            XCTAssertTrue(card("Tailspin").waitForExistence(timeout: 5), "…and shown under Show removed")
            app.checkBoxes["applications.showRemoved"].click()
            snap(app, "applications-\(mode)")

            // Move via the card's context menu (the keyboard/VoiceOver alternative to dragging).
            card("Northwind").rightClick()
            app.menuItems["Move to"].hover()
            app.menuItems["Acknowledged"].click()
            card("Northwind").click()
            let status = app.descendants(matching: .any)["application.status"]
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            XCTAssertTrue(waitUntil(5) { status.title.contains("Acknowledged") || status.label.contains("Acknowledged") }, "moved from Applied to Acknowledged")
            XCTAssertTrue(app.staticTexts["moved on the board"].exists, "timeline records the change")
            snap(app, "application-detail-\(mode)")

            // The detail's Status menu changes status without dragging (keyboard and VoiceOver users).
            status.click()
            app.menuItems["Interview"].click()
            XCTAssertTrue(waitUntil(5) { status.title.contains("Interview") || status.label.contains("Interview") }, "status menu moves the application")
            app.buttons["Done"].click()
            app.terminate()
        }
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        return condition()
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
