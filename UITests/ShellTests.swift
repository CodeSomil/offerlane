import XCTest

/// The glass shell end to end: every sidebar screen by click and by ⌘1-⌘9 and ⌘0, in light, dark and Reduce Transparency,
/// with a screenshot of each screen attached to the report. First paint is covered by PerformanceTests.
@MainActor final class ShellTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private let screens = ["Today", "Discover", "Review", "Pipeline", "Interview Prep", "Goals", "Skills", "Resumes", "Connect AI", "Settings"]

    func testShellClickThroughAllModes() throws {
        for (mode, appearance, solid) in [("light", "light", false), ("dark", "dark", false), ("reduced-transparency", "light", true)] {
            let app = XCUIApplication()
            app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]   // never block on "reopen windows?"
            app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-shell-" + UUID().uuidString
            app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
            app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
            app.launchEnvironment["OFFERLANE_SEED"] = "matches"
            app.launchEnvironment["OFFERLANE_APPEARANCE"] = appearance
            if solid { app.launchEnvironment["OFFERLANE_REDUCE_TRANSPARENCY"] = "1" }
            app.launch()
            let role = app.staticTexts["Senior Data Scientist, Forecasting"]
            XCTAssertTrue(role.waitForExistence(timeout: 10), "[\(mode)] Discover shows real seeded data")
            let ratio = MeasuredContrast.ratio(role)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "[\(mode)] role title is AA on its surface (\(ratio))")

            for (i, screen) in screens.enumerated() {
                app.outlines.staticTexts[screen].click()
                XCTAssertTrue(waitUntil(5) { self.selected(app, screen) }, "[\(mode)] click opens \(screen)")
                snap(app, "shell-\(screen.lowercased().replacingOccurrences(of: " ", with: "-"))-\(mode)")
                // Keyboard: ⌘<n> reaches the same screen from a different one.
                let other = screens[(i + 1) % screens.count]
                app.outlines.staticTexts[other].click()
                app.typeKey(String((i + 1) % 10), modifierFlags: .command)
                XCTAssertTrue(waitUntil(5) { self.selected(app, screen) }, "[\(mode)] ⌘\((i + 1) % 10) opens \(screen)")
            }
            app.terminate()
        }
    }

    private func selected(_ app: XCUIApplication, _ screen: String) -> Bool {
        app.outlines.cells.containing(.staticText, identifier: screen).firstMatch.isSelected
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
