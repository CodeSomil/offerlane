import XCTest

/// Home: today's focus lists the next action from seeded data, and following it opens that screen.
@MainActor final class HomeTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        return condition()
    }

    private var home = ""

    private func launch(seed: String = "matches") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        home = NSTemporaryDirectory() + "offerlane-home-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_HOME"] = home
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = seed
        app.launch(); return app
    }

    /// An overdue contact becomes the next step; the calendar export opens a save panel and writes nothing unless the user saves.
    func testFollowUpHeroAndCalendarExport() throws {
        let app = launch(seed: "followup")
        app.outlines.staticTexts["Today"].click()
        let follow = app.buttons["home.action.followUp"]
        XCTAssertTrue(follow.waitForExistence(timeout: 10), "an overdue follow-up is a next action")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Follow up with Ana Ruiz' OR value CONTAINS 'Follow up with Ana Ruiz'")).firstMatch.exists)

        let export = app.buttons["home.exportCalendar"]
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        export.click()
        XCTAssertTrue(waitUntil(10) { app.sheets.firstMatch.exists || app.dialogs.firstMatch.exists }, "the save panel opens")
        (app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch).buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(waitUntil(5) { !app.sheets.firstMatch.exists && !app.dialogs.firstMatch.exists }, "cancel closes it")
        let written = FileManager.default.enumerator(atPath: home)?.compactMap { $0 as? String }.filter { $0.hasSuffix(".ics") } ?? []
        XCTAssertEqual(written, [], "cancel writes no calendar file")

        follow.click()
        XCTAssertTrue(app.descendants(matching: .any)["applications.mode"].waitForExistence(timeout: 10), "the action opens Pipeline")
        app.terminate()
    }

    func testHomeNextActionOpensDiscover() throws {
        let app = launch()
        app.outlines.staticTexts["Today"].click()
        XCTAssertTrue(app.descendants(matching: .any)["home.week.approved"].waitForExistence(timeout: 10), "this week's funnel is on Today")
        XCTAssertTrue(app.descendants(matching: .any)["home.readiness"].exists, "readiness ring is on Today")
        // The hero shows one action at a time; "Later" steps to the next.
        let approve = app.buttons["home.action.approve"]
        for _ in 0..<3 where !approve.waitForExistence(timeout: 3) { app.buttons["home.later"].click() }
        XCTAssertTrue(approve.exists, "seeded matches show as a next action")
        approve.click()
        XCTAssertTrue(app.descendants(matching: .any)["matches.list"].waitForExistence(timeout: 10), "the action opens Discover")
        app.terminate()
    }

    func testConnectAIShowsChooserAndConnections() throws {
        let app = launch()
        app.outlines.staticTexts["Connect AI"].click()
        XCTAssertTrue(app.descendants(matching: .any)["provider.recommended.0"].waitForExistence(timeout: 10), "AI options are on the screen")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Connected AIs")).firstMatch.exists, "connections list is on the screen")
        app.terminate()
    }
}
