import XCTest

/// Interview: role questions for the seeded resume's role, STAR stories drafted from resume bullets, one mock round with feedback.
@MainActor final class InterviewTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testQuestionsStoriesAndOneMockRound() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-interview-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = "matches"
        app.launch()
        app.outlines.staticTexts["Interview Prep"].click()

        let roleQ = app.buttons["Practise: How would you design and analyse an A/B test?"]
        XCTAssertTrue(roleQ.waitForExistence(timeout: 10), "data-science role questions for the seeded role")

        app.radioButtons["STAR Stories"].click()
        app.buttons["interview.draft"].click()
        XCTAssertTrue(app.descendants(matching: .any)["interview.story"].firstMatch.waitForExistence(timeout: 10), "stories drafted")
        XCTAssertTrue(app.staticTexts["interview.note"].exists, "the invented-number draft was left out and the user is told")

        app.radioButtons["Questions"].click()
        roleQ.click()
        let answer = app.textViews["interview.answer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        answer.click(); answer.typeText("I framed the metric, ran the test for two weeks and shared the result.")
        app.buttons["interview.feedback"].click()
        XCTAssertTrue(app.descendants(matching: .any)["interview.score"].waitForExistence(timeout: 10), "feedback shown")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "40%")).firstMatch.exists, "invented number filtered")
        app.terminate()
    }
}
