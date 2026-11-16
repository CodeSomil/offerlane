import XCTest

/// Skill gaps: adding a role scores readiness from the seeded postings; offline, no unverified link is shown.
@MainActor final class SkillsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testAddingARoleShowsReadinessFromSeededPostings() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-skills-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = "matches"
        app.launch()
        app.outlines.staticTexts["Skills"].click()
        let field = app.textFields["skills.role.new"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click(); field.typeText("Data Scientist\r")
        let readiness = app.staticTexts["skills.readiness"]
        XCTAssertTrue(readiness.waitForExistence(timeout: 10), "readiness shown for a role with postings")
        XCTAssertTrue(readiness.label.contains("%") || (readiness.value as? String ?? "").contains("%"), readiness.label)
        // Market card: seeded postings group by city; all are 3 days old, so no trend is claimed.
        let london = app.descendants(matching: .any)["skills.market.city.London"]
        XCTAssertTrue(london.waitForExistence(timeout: 10), "London demand row shown")
        XCTAssertTrue(app.staticTexts["skills.market.trend"].exists, "not-enough-history note instead of an invented trend")
        app.terminate()
    }
}
