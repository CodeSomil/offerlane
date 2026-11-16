import XCTest

/// Pipeline → People: add a contact with a follow-up date, mark them contacted. Nothing is sent.
@MainActor final class ContactsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testAddContactAndMarkContacted() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-contacts-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = "applications"
        app.launch()
        app.outlines.staticTexts["Pipeline"].click()
        app.descendants(matching: .any)["applications.mode"].radioButtons["People"].click()

        let add = app.buttons["contacts.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.click()
        for (id, text) in [("contact.name", "Ana Ruiz"), ("contact.company", "Initech")] {
            let f = app.textFields[id]; XCTAssertTrue(f.waitForExistence(timeout: 5), id)
            f.click(); f.typeText(text + "\t")
        }
        app.checkBoxes["contact.remind"].click()
        app.buttons["contact.save"].click()

        let row = app.descendants(matching: .any)["contacts.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["contacts.followUp"].waitForExistence(timeout: 3), "a follow-up date is shown")
        app.buttons["contacts.contacted"].click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'last contacted' OR value CONTAINS 'last contacted'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Send"].exists, "tracker only: the user sends")

        // Remove asks first: Cancel keeps the contact, confirming deletes it.
        app.buttons["contacts.remove"].click()
        let confirm = app.buttons["contacts.remove.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "remove asks before deleting")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), "Esc closes the dialog")
        RunLoop.current.run(until: Date().addingTimeInterval(1))   // give a wrongly-wired delete time to land
        XCTAssertTrue(row.exists, "cancel keeps the contact")
        app.buttons["contacts.remove"].click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(app.staticTexts["No contacts yet. Add someone you're talking to and when to follow up."].waitForExistence(timeout: 5), "confirm deletes it")
        app.terminate()
    }
}
