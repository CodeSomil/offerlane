import XCTest

/// Pipeline → Offers: enter an offer, see its totals, draft a negotiation reply and copy it. Never sends.
@MainActor final class OffersTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testEnterOfferAndDraftNegotiation() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-offers-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = "applications"
        app.launch()
        app.outlines.staticTexts["Pipeline"].click()
        app.descendants(matching: .any)["applications.mode"].radioButtons["Offers"].click()

        let add = app.buttons["offers.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.click()
        for (id, text) in [("offer.company", "Initech"), ("offer.title", "Data Scientist"), ("offer.base", "100000"), ("offer.signOn", "20000")] {
            let f = app.textFields[id]; XCTAssertTrue(f.waitForExistence(timeout: 5), id)
            f.click(); f.typeKey("a", modifierFlags: .command); f.typeText(text + "\t")
        }
        app.buttons["offer.save"].click()

        let total = app.staticTexts["offers.firstYear"]
        XCTAssertTrue(total.waitForExistence(timeout: 5))
        XCTAssertTrue(((total.value as? String) ?? total.label).contains("120,000"), "first year = base + sign-on")
        app.buttons["offers.negotiate"].click()
        let body = app.textViews["negotiation.body"]
        XCTAssertTrue(waitUntil(10) { ((body.value as? String) ?? "").hasPrefix("Hi [Name]") }, "script greets a placeholder")
        app.buttons["negotiation.copy"].click()
        XCTAssertTrue(app.staticTexts["Copied. Paste it into your reply."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Send"].exists, "scripts only: the user sends")
        app.terminate()
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        return condition()
    }
}
