import XCTest

/// Goals: the seeded resume's role places the user on a ladder; "Plan Skills" makes the step the Skills role.
@MainActor final class GoalsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testNextStepFromResumeRoleBecomesTheSkillsRole() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-goals-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = "matches"
        app.launch()
        app.outlines.staticTexts["Goals"].click()
        let plan = app.buttons["Plan skills for Staff Data Scientist"]
        XCTAssertTrue(plan.waitForExistence(timeout: 10), "1-year step up from Senior Data Scientist")
        XCTAssertTrue(app.staticTexts["In about 1 year: Staff Data Scientist"].exists)
        XCTAssertTrue(app.buttons["Plan skills for Senior Machine Learning Engineer"].exists, "pivot shown")
        plan.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Readiness for Staff Data Scientist")).firstMatch.waitForExistence(timeout: 10), "Skills now plans for the goal")
        XCTAssertTrue(app.staticTexts["skills.readiness"].exists)
        app.terminate()
    }
}
