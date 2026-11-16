import XCTest

/// Pipeline → a role → Draft outreach: referral ideas and an editable draft the user copies (never sent).
@MainActor final class NetworkingTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testOutreachDraftForARole() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-network-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = "applications"
        app.launch()
        app.outlines.staticTexts["Pipeline"].click()
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Northwind,")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.click()
        let open = app.buttons["application.outreach"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "networking.idea").firstMatch.waitForExistence(timeout: 5), "who-to-ask ideas shown")
        let body = app.textViews["networking.body"]
        XCTAssertTrue(waitUntil(10) { ((body.value as? String) ?? "").hasPrefix("Hi [Name]") }, "draft greets a placeholder, not a guessed name")
        let copy = app.buttons["networking.copy"]
        XCTAssertTrue(copy.isEnabled)
        copy.click()
        XCTAssertTrue(app.staticTexts["Copied. Paste it into your email or message app."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Send"].exists, "drafts only: the user sends")
        app.terminate()
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        return condition()
    }
}
