import XCTest

/// Setup Center: the sidebar health indicator, friendly problem messages with Fix buttons, and Repair Everything.
final class SetupCenterTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(health: String?, dark: Bool = false, connections: String? = nil, seed: String = "matches") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OFFERLANE_HOME"] = NSTemporaryDirectory() + "offerlane-setup-" + UUID().uuidString
        app.launchEnvironment["OFFERLANE_FAKE_AI"] = "1"
        app.launchEnvironment["OFFERLANE_ONBOARDED"] = "1"
        app.launchEnvironment["OFFERLANE_SEED"] = seed
        app.launchEnvironment["OFFERLANE_APPEARANCE"] = dark ? "dark" : "light"
        if let health { app.launchEnvironment["OFFERLANE_HEALTH"] = health }
        if let connections { app.launchEnvironment["OFFERLANE_CONNECTIONS"] = connections }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch(); return app
    }

    func testProblemsShowInSidebarAndSetupCenter() throws {
        let app = launch(health: "offline,lowdisk")
        let status = app.buttons["sidebar.health"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(10) { (status.label).contains("2 things need attention") }, "sidebar shows the count: \(status.label)")
        status.click()

        let summary = app.staticTexts["setup.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "sidebar opens the Setup Center")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH \"You're offline.\"")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH 'Only 1.2 GB free.'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["health.fix.internet"].exists, "offline has a Try Again button")
        XCTAssertTrue(app.buttons["health.fix.disk"].exists, "low disk has a button")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["provider.recommended.0"].exists, "AI engine cards are in the Setup Center")
        XCTAssertTrue(any["provider.recommended.0"].label.contains("OpenRouter"), "one-click sign-in (free and paid models) leads")
        XCTAssertFalse(any["provider.recommended.1"].exists, "exactly one recommended option")
        XCTAssertTrue(app.links["provider.more"].exists, "the other options sit under More")
        XCTAssertEqual(app.links["provider.more"].label, "More options", "More starts closed")
        XCTAssertFalse(any["provider.claude"].exists, "Claude account is not offered to new users (deferred)")
        snap(app, "setup-center-problems-light")

        app.buttons["setup.repairAll"].click()
        let result = app.staticTexts["setup.repairResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 20), "Repair Everything reports what's left")
        XCTAssertEqual(result.value as? String, "2 things still need you. Use the buttons below.")

        app.buttons["Done"].click()
        XCTAssertFalse(summary.waitForExistence(timeout: 2))
        app.terminate()
    }

    func testAllGoodDark() throws {
        let app = launch(health: "ok", dark: true)
        let status = app.buttons["sidebar.health"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        status.click()
        let summary = app.staticTexts["setup.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(15) { summary.value as? String == "Everything is working" }, "\(String(describing: summary.value))")
        XCTAssertFalse(app.buttons["health.fix.ai"].exists, "test AI is connected")
        snap(app, "setup-center-dark")
        app.terminate()
    }

    /// A saved AI that isn't the recommended one keeps "More options" open, so the user sees what they picked.
    func testMoreOpensForSavedHiddenProvider() throws {
        let app = launch(health: "ok", seed: "ollama")
        let status = app.buttons["sidebar.health"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        status.click()
        XCTAssertTrue(app.staticTexts["setup.summary"].waitForExistence(timeout: 10))
        let any = app.descendants(matching: .any)
        XCTAssertFalse(any["provider.recommended.0"].label.contains("Ollama"), "precondition: Ollama sits under More, not as the recommended card")
        let more = app.links["provider.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        XCTAssertEqual(more.label, "Fewer options", "More starts open when the saved AI is under it")
        let ollama = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Ollama'")).firstMatch
        XCTAssertTrue(ollama.waitForExistence(timeout: 5), "the saved Ollama card is visible")
        more.click()
        XCTAssertEqual(more.label, "More options", "the user can still close it")
        app.terminate()
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        return condition()
    }

    /// Free API key walkthrough: numbered steps, key page button, live key-format check, privacy note before Connect.
    func testKeyProviderWalkthrough() throws {
        let app = launch(health: "offline")
        let status = app.buttons["sidebar.health"]
        XCTAssertTrue(status.waitForExistence(timeout: 10)); status.click()
        // Every key provider has its own card (no provider picker); Cloudflare may be recommended or under More options.
        let card = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Cloudflare Workers AI'")).firstMatch
        let more = app.links["provider.more"]
        if more.waitForExistence(timeout: 10), !card.exists { more.click() }
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.click()

        XCTAssertTrue(app.descendants(matching: .any)["key.steps"].waitForExistence(timeout: 5), "numbered steps")
        XCTAssertTrue(app.buttons["key.step.get"].exists, "get → paste → connect stepper")
        XCTAssertTrue(app.buttons["key.page"].exists, "button opens the provider's key page")
        XCTAssertTrue(app.descendants(matching: .any)["key.privacy"].exists, "privacy note is shown before connecting")
        XCTAssertFalse(app.popUpButtons["key.provider"].exists, "the card picks the provider")
        let connect = app.buttons["key.connect"]
        XCTAssertFalse(connect.isEnabled, "no key yet")

        let key = app.secureTextFields["key.value"]
        XCTAssertTrue(key.waitForExistence(timeout: 5)); key.click(); key.typeText("not-a-token")
        let format = app.staticTexts["key.format"]
        XCTAssertTrue(format.waitForExistence(timeout: 5))
        XCTAssertTrue((format.value as? String ?? "").hasPrefix("That doesn't look like a Cloudflare Workers AI key"), "\(format.value ?? "")")
        XCTAssertFalse(connect.isEnabled, "bad format can't be sent")
        snap(app, "key-provider-light")
        XCTAssertFalse(app.buttons["key.signIn"].exists, "Cloudflare has no sign-in flow, only a key")
        key.typeKey("a", modifierFlags: .command); key.typeText("sk-ant-api03-wrongcard")
        XCTAssertTrue(app.buttons["key.switch"].waitForExistence(timeout: 5), "a Claude key on the Cloudflare card offers to switch")

        let openRouter = app.buttons.containing(NSPredicate(format: "label CONTAINS 'OpenRouter'")).firstMatch
        if !openRouter.exists { more.click() }
        XCTAssertTrue(openRouter.waitForExistence(timeout: 5)); openRouter.click()
        XCTAssertTrue(app.buttons["key.signIn"].waitForExistence(timeout: 5), "OpenRouter offers sign-in instead of copying a key")
        XCTAssertFalse(app.secureTextFields["key.value"].exists, "sign-in comes first; the paste steps are hidden")
        app.links["key.manual"].click()
        XCTAssertTrue(app.secureTextFields["key.value"].waitForExistence(timeout: 5), "pasting a key still works")
        for tier in ["recommended", "cheaper", "advanced"] {
            XCTAssertTrue(app.buttons["key.pick.\(tier)"].waitForExistence(timeout: 5), "three curated cards (D6): \(tier)")
        }
        XCTAssertFalse(app.buttons["key.pick.recommended"].label.contains("Recommended"), "untested picks are never labelled Recommended")
        XCTAssertFalse(app.popUpButtons["key.model"].exists, "the full model list is behind the developer toggle")
        app.checkBoxes["key.showAll"].click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH 'Warning:' OR label BEGINSWITH 'Warning:'")).firstMatch
            .waitForExistence(timeout: 5), "the full list comes with a warning")
        app.checkBoxes["key.showAll"].click()
        snap(app, "key-provider-openrouter-light")
        app.terminate()
    }

    /// Connected AIs: reorder by keyboard-reachable buttons, re-test, remove with confirmation.
    func testManageConnections() throws {
        let app = launch(health: "ok", connections: "alpha,beta")
        let status = app.buttons["sidebar.health"]
        XCTAssertTrue(status.waitForExistence(timeout: 10)); status.click()
        let first = app.descendants(matching: .any)["connection.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.staticTexts["Ollama · alpha"].exists)
        XCTAssertFalse(app.buttons["connection.up.0"].isEnabled)

        app.buttons["connection.down.0"].click()
        XCTAssertTrue(app.descendants(matching: .any)["connection.0"].staticTexts["Ollama · beta"].waitForExistence(timeout: 5), "beta is primary now")

        app.buttons["connection.test.1"].click()
        XCTAssertTrue(app.staticTexts["Passed the strict JSON test."].waitForExistence(timeout: 10))

        app.buttons["connection.remove.0"].click()
        let confirm = app.buttons["Remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.click()
        XCTAssertTrue(app.descendants(matching: .any)["connection.0"].staticTexts["Ollama · alpha"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["connection.1"].exists)
        snap(app, "connections-light")
        app.terminate()
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
