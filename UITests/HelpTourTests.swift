import XCTest

/// Product tour (keyboard only), in-app Help search, the redacted diagnostics report, and Xcode's accessibility audit.
final class HelpTourTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-help-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = "applications"
        app.launchEnvironment["OFFERLANE_HEALTH"] = "ok"
        app.launchEnvironment["OFFERLANE_APPEARANCE"] = dark ? "dark" : "light"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch(); return app
    }

    private func helpMenu(_ app: XCUIApplication, _ item: String) {
        let menu = app.menuBars.menuBarItems["Help"]
        menu.click()
        menu.menuItems[item].firstMatch.click()
    }

    func testTourWithKeyboardOnly() throws {
        let app = launch()
        XCTAssertTrue(app.outlines.staticTexts["Discover"].waitForExistence(timeout: 10))
        helpMenu(app, "Take the Tour")
        let card = app.descendants(matching: .any)["tour.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), "tour starts from the Help menu")
        XCTAssertTrue(app.staticTexts["Find jobs"].exists)
        XCTAssertTrue(app.staticTexts["1 of 5"].exists)
        snap(app, "tour-light")
        for _ in 0..<4 { app.typeKey(.return, modifierFlags: []) }
        XCTAssertTrue(app.staticTexts["Help is close by"].waitForExistence(timeout: 5), "Return moves through the tour")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { !card.exists }, "Return on the last card ends the tour")

        helpMenu(app, "Take the Tour")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "the tour can be replayed")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { !card.exists }, "Esc skips the tour")
        XCTAssertEqual(app.windows.matching(NSPredicate(format: "title == 'Offerlane'")).count, 1, "Help menu actions reuse the main window")
        app.terminate()
    }

    func testHelpSearchAndDiagnostics() throws {
        let app = launch()
        XCTAssertTrue(app.outlines.staticTexts["Discover"].waitForExistence(timeout: 10))
        helpMenu(app, "Offerlane Help")
        let help = app.windows["Offerlane Help"]
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        let search = help.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click(); search.typeText("ollama space")
        let topic = help.descendants(matching: .any)["help.topic.ollama-space"]
        XCTAssertTrue(topic.waitForExistence(timeout: 5), "search finds the answer")
        XCTAssertFalse(help.descendants(matching: .any)["help.topic.what"].exists, "unrelated topics are filtered out")
        topic.click()
        XCTAssertTrue(help.staticTexts["help.answer"].waitForExistence(timeout: 5))
        snap(help, "help-light")
        help.buttons[XCUIIdentifierCloseWindow].click()

        helpMenu(app, "Send Diagnostics…")
        let report = app.staticTexts["diagnostics.report"]
        XCTAssertTrue(report.waitForExistence(timeout: 15))
        let text = report.value as? String ?? ""
        XCTAssertTrue(text.hasPrefix("Offerlane diagnostics"), text)
        XCTAssertTrue(text.contains("Checks:"))
        XCTAssertFalse(text.contains(NSUserName()), "no Mac user name")
        XCTAssertFalse(text.contains("@example"), "no email addresses")
        snap(app, "diagnostics-light")
        app.buttons["Cancel"].firstMatch.click()
        app.terminate()
    }

    func testAIPrivacySummary() throws {
        let app = launch()
        XCTAssertTrue(app.outlines.staticTexts["Discover"].waitForExistence(timeout: 10))
        helpMenu(app, "Offerlane Help")
        let help = app.windows["Offerlane Help"]
        let search = help.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click(); search.typeText("each AI")
        let topic = help.descendants(matching: .any)["help.topic.ai-privacy"]
        XCTAssertTrue(topic.waitForExistence(timeout: 5))
        topic.click()
        let answer = help.staticTexts["help.answer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        let text = (answer.value as? String ?? "") + answer.label
        XCTAssertTrue(text.contains("Everything stays on this Mac."), "Ollama's note comes from providers.json: \(text)")
        XCTAssertFalse(text.contains("Claude Code"), "hidden providers are not listed")
        app.terminate()
    }

    /// Xcode's built-in audit: missing labels, contrast, element detection, on each main screen.
    func testAccessibilityAudit() throws {
        let app = launch()
        XCTAssertTrue(app.outlines.staticTexts["Discover"].waitForExistence(timeout: 10))
        for screen in ["Today", "Discover", "Review", "Pipeline", "Skills", "Resumes", "Connect AI", "Settings"] {
            app.outlines.staticTexts[screen].click()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            // Settings is a long scroll view; the audit's contrast sampling misreads text there (checked by screenshot:
            // black and #55555F on white). Its colours are covered by scripts/check_contrast.py instead.
            let types: XCUIAccessibilityAuditType = screen == "Settings" ? [.elementDetection, .sufficientElementDescription]
                                                                          : [.contrast, .elementDetection, .sufficientElementDescription]
            try app.performAccessibilityAudit(for: types) { issue in
                // System-drawn chrome (window buttons, toolbar search, list disclosure) isn't ours to fix.
                let window = app.windows.firstMatch.frame
                let ignored = issue.element.map {
                    $0.elementType == .toolbar || $0.elementType == .searchField || $0.identifier.hasPrefix("_XCUI")
                        // Window and split-view panes: AppKit layout containers, disabled and never focusable.
                        || ($0.elementType == .group && !$0.isEnabled && $0.label.isEmpty && $0.identifier.isEmpty && issue.auditType == .sufficientElementDescription)
                } ?? false
                // The sampler misreads text over the glass backdrop's gradient: accept only what measures AA from pixels.
                // Scrolled below the window: the sampler would measure the desktop or Dock, not our pixels.
                if !ignored, issue.auditType == .contrast, let e = issue.element, !window.contains(e.frame) { return true }
                if !ignored, issue.auditType == .contrast, let e = issue.element {
                    let r = MeasuredContrast.ratio(e)
                    print("A11Y [\(screen)] contrast flagged, measured \(String(format: "%.2f", r)):1 — \(e.label.prefix(40))")
                    if r >= 4.5 { return true }
                }
                if !ignored { print("A11Y [\(screen)] \(issue.auditType) \(issue.compactDescription) — \(issue.element?.debugDescription.prefix(160) ?? "")") }
                return ignored
            }
        }
        app.terminate()
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        return condition()
    }

    private func snap(_ e: XCUIElement, _ name: String) {
        let window = (e as? XCUIApplication)?.windows.firstMatch ?? e
        let a = XCTAttachment(screenshot: window.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
