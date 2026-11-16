import AppKit
import OfferlaneCore

/// Health checks, one-click fixes and "Repair everything", shared by the sidebar dot and the Setup Center.
extension AppModel {
    var healthStatus: Health.Status { health.isEmpty ? .ok : Health.overall(health) }
    var healthSummary: String { health.isEmpty ? "Checking…" : Health.summary(health) }
    var needsAttention: [Health.Item] { health.filter { $0.status >= .warning } }

    /// Re-checks in the background (skipped if a check is already running).
    func refreshHealth() {
        guard healthTask == nil else { return }
        healthTask = Task { await checkHealth(); healthTask = nil }
    }

    func checkHealth() async {
        healthChecking = true; defer { healthChecking = false }
        await autoStartOllama()
        Task.detached(priority: .background) { await Self.refreshRegistryIfDue() }
        let account = settings.provider == .apiKey ? Keychain.Account.provider(settings.providerID) : Keychain.Account.anthropicKey
        let keySaved = keychain.get(account: account).map { !$0.isEmpty } ?? false
        var facts = await Health.gather(settings: settings, apiKeySaved: keySaved, testAI: Self.isUITest)
        Self.applyTestOverrides(&facts)
        health = Health.evaluate(facts)
    }

    /// When Ollama is the chosen AI and installed but not running, start it once (the health dot then shows the result).
    private func autoStartOllama() async {
        guard settings.provider == .ollama, !ollamaAutoStarted, !Self.isUITest else { return }
        ollamaAutoStarted = true
        let o = OllamaSetup()
        if o.isInstalled, !(await o.isRunning()) { try? await o.launch() }   // a failed start shows as "Ollama isn't running" + Start
    }

    /// Fetches the provider list from OfferlaneRegistryURL (Info.plist) at most once a day. Off while the URL is a placeholder
    /// or in UI tests. Failures are silent: the bundled list keeps working, and pins never change remotely (ProviderRegistry.merge).
    nonisolated private static func refreshRegistryIfDue() async {
        guard !isUITest, let raw = Bundle.main.object(forInfoDictionaryKey: "OfferlaneRegistryURL") as? String,
              let feed = URL(string: raw), feed.host != "example.invalid" else { return }
        let dest = ProviderRegistry.refreshedURL
        let modified = (try? dest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        guard Date().timeIntervalSince(modified) > 86_400 else { return }
        do { try await ProviderRegistry.refresh(from: feed); Log.info("provider list refreshed") }
        catch { Log.info("provider list refresh skipped: \(error.plainMessage)") }
    }

    /// UI tests pin the checks with OFFERLANE_HEALTH=ok, or show problems with offline,lowdisk,rosetta,noai.
    private static func applyTestOverrides(_ f: inout Health.Facts) {
        guard isUITest, let raw = TestHooks.env["OFFERLANE_HEALTH"] else { return }
        let flags = Set(raw.split(separator: ",").map(String.init))
        if flags.contains("ok") { f.online = true; f.freeDisk = 200_000_000_000; f.translated = false; f.latexEngine = true }
        if flags.contains("offline") { f.online = false }
        if flags.contains("lowdisk") { f.freeDisk = 1_200_000_000 }
        if flags.contains("rosetta") { f.translated = true }
        if flags.contains("noai") { f.testAI = false; f.provider = .ollama; f.ollamaInstalled = true; f.ollamaRunning = false; f.ollamaModel = "qwen3.5:9b" }
    }

    /// Runs one "Fix it" action. Fixes that need the user (signing in, a key) open the right place instead.
    func perform(_ fix: Health.Fix) async {
        let setup = onboarding!
        switch fix {
        case .chooseAI, .enterAPIKey:
            if fix == .enterAPIKey { setup.provider = settings.provider == .apiKey ? .apiKey : .anthropic }
            showSetupCenter = true
        case .signInClaude:
            setup.provider = .claudeCLI; showSetupCenter = true
            await setup.refreshClaude()
            if setup.claudeExe != nil { setup.showClaudeSignIn = true }
        case .installClaude:
            setup.provider = .claudeCLI
            await setup.runInstallClaude()
        case .installOllama:
            setup.provider = .ollama
            if await setup.runInstallOllama() { await setup.refreshOllama() }
        case .startOllama:
            setup.provider = .ollama
            await setup.runStartOllama()
        case .downloadModel(let m):
            setup.provider = .ollama; setup.ollamaModel = m
            if !setup.ollamaRunning { await setup.runStartOllama() }
            await setup.runPullModel()
        case .freeDisk:
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") { NSWorkspace.shared.open(url) }
        case .rosettaHelp:
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            toast = Toast(message: "In the Finder window, select Offerlane, choose File → Get Info, untick “Open using Rosetta”, then reopen Offerlane.")
        case .recheck:
            break
        }
        await checkHealth()
    }

    /// Runs every fix that doesn't need the user, one after another, then reports what's left.
    func repairEverything() async {
        repairResult = nil
        let fixes = needsAttention.compactMap { item in item.fix.map { (item.title, $0) } }.filter { $0.1.automatic }
        for (title, fix) in fixes {
            repairing = "Fixing \(title.lowercased())…"
            await perform(fix)
        }
        repairing = "Tidying up old downloads…"
        _ = await Task.detached { SafeDownloader.cleanup() }.value
        repairing = "Checking everything again…"
        await checkHealth()
        repairing = nil
        let left = needsAttention.count
        repairResult = left == 0 ? "Everything is working." : left == 1 ? "1 thing still needs you. Use its button below." : "\(left) things still need you. Use the buttons below."
    }
}
