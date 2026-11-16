import SwiftUI
import UniformTypeIdentifiers
import OfferlaneCore

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case ai, resumes, about, search, email, notifications, finish
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .ai: "Connect AI"
        case .resumes: "Add resumes"
        case .about: "About you"
        case .search: "Search"
        case .email: "Email"
        case .notifications: "Notifications"
        case .finish: "Find jobs"
        }
    }
    /// First run is three screens after sign-in: connect AI → add resumes → find jobs.
    static let main: [OnboardingStep] = [.ai, .resumes, .finish]
    /// Reached from the last screen (or from Settings) only when the user wants to change something.
    var isOptional: Bool { !Self.main.contains(self) }
}

/// One file the user added in the Resumes step.
@MainActor @Observable
final class ResumeUpload: Identifiable {
    enum State: Equatable { case parsing, done, failed(String) }
    let id = UUID()
    let filename: String
    let data: Data
    var label: String
    var state: State = .parsing
    var version: ResumeVersion?
    var task: Task<Void, Never>?

    init(filename: String, data: Data, label: String) { self.filename = filename; self.data = data; self.label = label }
    init(existing v: ResumeVersion) {
        filename = v.sourceFile; data = Data(); label = v.label; version = v; state = .done
    }
    var name: String { version?.name ?? ResumeVersion.makeName(from: label) }
}

/// Everything the wizard collects. It lives as long as the app, so going Back (or reopening setup from
/// Settings) never loses what was entered.
@MainActor @Observable
final class OnboardingModel {
    @ObservationIgnored weak var app: AppModel?
    var step: OnboardingStep = .ai { didSet { if step != oldValue { setupTimer.enter("\(step)") } } }
    /// P1.6: times first run for the stranger test; one local log line on finish, nothing else.
    @ObservationIgnored private var setupTimer = SetupTimer()

    // Step 1: AI
    var provider: AppSettings.Provider = .none
    var claudeExe: URL?
    var claudeVersion: String?
    var claudeAuth: ClaudeSetup.AuthStatus?
    var claudeChecking = false
    var claudeInstalling = false
    var claudeInstallStatus = ""
    var claudeInstallProgress: Double?
    var claudeInstallLog = ""
    var claudeError: String?
    var showClaudeSignIn = false
    var connectionTesting = false
    var connectionError: String?
    var connectedSeconds: Double?
    var apiKey = ""
    // Free API key providers (registry entries KeyProviderAdapter supports)
    let keyProviders = ((try? ProviderRegistry.visible()) ?? []).filter(KeyProviderAdapter.supports)
    var keySpecID = "gemini"
    var keyValue = ""
    var keyAccountID = ""
    var keyBaseURL = ""
    var keyModel = ""
    /// OpenRouter's live paid models with prices (picks' price lines and the developer "Show all models" list).
    var keyModels: [OpenRouterCatalog.Model] = []
    /// The setup step running now, while Connect is pressed.
    var keyStep: SetupStep?
    var keySigningIn = false
    /// What the last successful Connect produced; saved by `saveAI`.
    var keyConfig: ProviderConfig?
    var ollamaInstalled = false
    var ollamaRunning = false
    var ollamaModels: [String] = []
    var ollamaModel = OllamaSetup.recommended(freeDisk: SystemCheck.freeDiskBytes()).name
    var ollamaInstallProgress: Double?
    var ollamaPullProgress: Double?
    var ollamaPullStatus = ""
    var ollamaError: String?
    var askOllamaInstall = false
    var ollamaInstallStatus = ""
    /// A cancelled Ollama download that will continue where it stopped.
    var ollamaInstallPaused = false
    /// A model whose download was cancelled; Ollama keeps the finished parts.
    var ollamaPausedModel: String?
    var ollamaWorking: String?
    var askOllamaUninstall = false
    var freeDisk: Int64 = SystemCheck.freeDiskBytes()
    @ObservationIgnored var longTask: Task<Void, Never>?
    /// The provider + settings that passed the connection test.
    var connectedProvider: AppSettings.Provider?

    // Step 2: resumes
    var uploads: [ResumeUpload] = []
    var importing = false
    var importReport: String?
    var importError: String?

    // Step 3: about you
    var profile = Profile()
    var showProfileErrors = false

    // Step 4: search
    var search = SearchConfig()
    /// The user's own Adzuna key (profile Keychain only; see `saveAdzuna`).
    var adzunaId = ""
    var adzunaKey = ""
    var adzunaError: String?
    /// What was loaded, so a save only touches the Keychain when the user changed the fields (a failed read never wipes it).
    @ObservationIgnored private var adzunaLoaded = Adzuna.Keys(appId: "", appKey: "")
    var drafting = false
    var draftError: String?
    var drafted = false

    // Step 5: email
    var email = AppSettings.Email()
    var emailPassword = ""
    var emailTesting = false
    var emailResult: String?
    var emailError: String?

    // Step 6: notifications
    var notify = AppSettings.Notify()
    var notificationStatus: String?
    var ntfyTestResult: String?

    init(app: AppModel) {
        self.app = app
        let s = app.settings
        if s.provider != .none { provider = s.provider }
        if s.provider == .ollama, !s.modelSmart.isEmpty { ollamaModel = s.modelSmart }
        if s.provider == .apiKey {
            keySpecID = s.providerID; keyModel = s.modelSmart; keyBaseURL = s.baseUrl
            keyAccountID = Re.first("/accounts/([0-9a-fA-F]+)/", s.baseUrl) ?? ""
            keyValue = app.keychain.get(account: Keychain.Account.provider(s.providerID)) ?? ""
            keyConfig = ProviderConfig(providerID: s.providerID, model: s.modelSmart, baseURL: s.baseUrl)
        } else if let first = keyProviders.first { keySpecID = first.id; keyModel = first.models.first ?? "" }
        // New users start on the top pick for this Mac.
        if s.provider == .none, let r = FirstRun.recommend(SystemCheck.hardware, specs: (try? ProviderRegistry.visible()) ?? []).first {
            provider = r.provider
            if r.provider == .apiKey { keySpecID = r.providerID; keyModel = keySpec?.models.first ?? "" }
        }
        if AppModel.isUITest || (s.onboarded && app.aiConnected) { connectedProvider = provider }
        uploads = ((try? app.store.resumeVersions()) ?? []).map(ResumeUpload.init(existing:))
        profile = (try? app.store.profile()) ?? Profile()
        search = (try? app.store.search()) ?? SearchConfig()
        drafted = !search.companies.isEmpty
        if let k = Adzuna.keys(in: app.keychain) { adzunaId = k.appId; adzunaKey = k.appKey; adzunaLoaded = k }
        email = s.email; notify = s.notify
        if !email.user.isEmpty { emailPassword = app.keychain.get(account: Keychain.Account.imap(email.user)) ?? "" }
        if !s.onboarded { setupTimer.start(); setupTimer.enter("\(step)") }
    }

    // MARK: navigation

    var aiReady: Bool { AppModel.isUITest || connectedProvider == provider }
    /// At least one parsed resume, nothing still parsing, and no failed upload left unresolved (retry or remove it).
    var resumesReady: Bool { !uploads.isEmpty && uploads.allSatisfy { $0.state == .done } }

    var canGoNext: Bool {
        switch step {
        case .ai: aiReady
        case .resumes: resumesReady
        case .about: profile.validationErrors.isEmpty
        case .search: !drafting && !search.titleInclude.isEmpty && !search.companies.isEmpty
        case .email: !email.enabled || email.gmail || (!email.user.isEmpty && !emailPassword.isEmpty && !email.host.isEmpty)
        default: true
        }
    }
    var nextHint: String? {
        switch step {
        case .ai where !aiReady: "Connect an AI to continue."
        case .resumes where uploads.isEmpty: "Add at least one resume to continue."
        case .resumes where uploads.contains { $0.state == .parsing }: "Reading your resume…"
        case .resumes where !resumesReady: "Fix or remove the resume that couldn't be read."
        case .about where !profile.validationErrors.isEmpty: "Complete the highlighted fields."
        case .search where drafting: "Drafting your search…"
        case .search where search.companies.isEmpty: "Add at least one company."
        case .search where search.titleInclude.isEmpty: "Add at least one title to look for."
        case .email where !canGoNext: "Enter your email and app password, or turn tracking off."
        default: nil
        }
    }

    /// Opened from Settings to change one thing: Done goes straight back to the app.
    var editingFromSettings = false

    func next() {
        guard canGoNext else { return }
        if step.isOptional { done(); return }
        switch step {
        case .ai: saveAI(); step = .resumes
        case .resumes: enterFinish()
        default: break
        }
    }

    /// Leaves an optional screen (About you, Search, Email, Notifications), keeping what was entered.
    func done() {
        guard canGoNext else { return }
        saveCurrent()
        if editingFromSettings { editingFromSettings = false; app?.settings.onboarded = true; step = .finish; return }
        step = .finish
    }

    func back() {
        if step.isOptional {
            if editingFromSettings { editingFromSettings = false; app?.settings.onboarded = true; step = .finish } else { step = .finish }
            return
        }
        guard let i = OnboardingStep.main.firstIndex(of: step), i > 0 else { return }
        step = OnboardingStep.main[i - 1]
    }

    /// The last screen: fill in contact details from the resume and draft the search in the background.
    func enterFinish() {
        prefillProfile()
        try? app?.store.set(.profile, profile)
        step = .finish
        if !drafted && !drafting { draftSearch() }
    }

    /// Opens an optional screen from the last step.
    func edit(_ s: OnboardingStep) {
        if s == .about { prefillProfile() }
        if s == .search && !drafted && !drafting { draftSearch() }
        step = s
    }

    var searchReady: Bool { !drafting && !search.titleInclude.isEmpty && !search.companies.isEmpty }
    /// Save whatever the current step edits (used when Settings re-opens one step and the user jumps to Finish).
    /// Saves the Adzuna key, or removes it when a field is blank; with no key the source is switched off.
    func saveAdzuna() {
        guard let app else { return }
        let typed = Adzuna.Keys(appId: adzunaId, appKey: adzunaKey)
        if typed != adzunaLoaded {
            do { try Adzuna.save(typed, in: app.keychain); adzunaLoaded = typed; adzunaError = nil }
            catch { adzunaError = error.localizedDescription; Log.error("Adzuna key not saved: \(error.localizedDescription)"); return }
        }
        if Adzuna.keys(in: app.keychain) == nil, search.sources["adzuna"] == true { search.sources["adzuna"] = false }
    }

    func saveCurrent() {
        switch step {
        case .ai: break
        case .about: try? app?.store.set(.profile, profile)
        case .search: saveAdzuna(); try? app?.store.set(.search, search)
        case .email: saveEmail()
        case .notifications: app?.settings.notify = notify
        default: break
        }
        app?.refresh()
    }
    func go(to s: OnboardingStep) {
        guard let target = OnboardingStep.main.firstIndex(of: s) else { return }
        let current = OnboardingStep.main.firstIndex(of: step) ?? OnboardingStep.main.count - 1
        if target <= current { step = s } else if canGoNext { next() }
    }

    func finish(findNow: Bool) {
        if step != .finish { saveCurrent() }
        try? app?.store.set(.profile, profile); if !search.companies.isEmpty { try? app?.store.set(.search, search) }
        app?.settings.notify = notify; app?.refresh()
        let firstRun = !(app?.settings.onboarded ?? true) && !editingFromSettings
        app?.settings.onboarded = true
        editingFromSettings = false
        if firstRun && notificationStatus == nil && !AppModel.isUITest { requestNotifications() }
        if firstRun { app?.startTourIfNeeded() }
        if firstRun, let t = setupTimer.finish() { Log.info(t.line) }
        if findNow { app?.findJobs() }
    }

    // MARK: AI connection

    func providerChanged() {
        connectionError = nil
        switch provider {
        case .claudeCLI: Task { await refreshClaude() }
        case .ollama: Task { await refreshOllama() }
        default: break
        }
    }

    func refreshClaude() async {
        claudeChecking = true; defer { claudeChecking = false }
        claudeExe = ClaudeSetup.locate(app?.settings.claudePath)
        guard let exe = claudeExe else { claudeVersion = nil; claudeAuth = nil; return }
        claudeVersion = await ClaudeSetup.version(exe)
        claudeAuth = await ClaudeSetup.authStatus(exe)
        if claudeAuth?.loggedIn == true, connectedProvider != .claudeCLI, !connectionTesting { await testConnection() }
    }

    func installClaude() { longTask = Task { _ = await runInstallClaude() } }

    /// Downloads, verifies and installs Claude Code. Returns true when it's installed.
    @discardableResult
    func runInstallClaude() async -> Bool {
        claudeInstalling = true; claudeError = nil; claudeInstallLog = ""; claudeInstallProgress = nil
        defer { claudeInstalling = false; claudeInstallProgress = nil }
        if AppModel.isUITest { return false }
        do {
            let exe = try await ClaudeSetup.install(phase: { p in Task { @MainActor in self.show(p) } },
                                                    onOutput: { chunk in Task { @MainActor in self.claudeInstallLog += chunk } })
            claudeExe = exe
            if app?.settings.provider == .claudeCLI { app?.settings.claudePath = exe.path; app?.rebuildAI() }
            await refreshClaude()
            return true
        } catch is CancellationError {
            claudeError = "Install cancelled. Click Install to continue where it stopped."
        } catch {
            claudeError = error.plainMessage
        }
        return false
    }

    private func show(_ p: ClaudeSetup.Phase) {
        switch p {
        case .checking: claudeInstallStatus = "Finding the latest version…"
        case .downloading(let f): claudeInstallStatus = "Downloading Claude Code…"; claudeInstallProgress = f
        case .verifying: claudeInstallStatus = "Checking it's the genuine Claude Code…"; claudeInstallProgress = nil
        case .installing: claudeInstallStatus = "Setting up…"
        }
    }

    func cancelLongTask() {
        longTask?.cancel(); longTask = nil
        if ollamaInstallProgress != nil { ollamaInstallPaused = true }
        if ollamaPullProgress != nil { ollamaPausedModel = ollamaModel }
        claudeInstalling = false; ollamaInstallProgress = nil; ollamaPullProgress = nil
    }

    /// Builds the client for the current choice and makes one tiny JSON call.
    func testConnection() async {
        connectionTesting = true; connectionError = nil; connectedSeconds = nil
        defer { connectionTesting = false }
        let client: (any LLMClient)?
        switch provider {
        case .claudeCLI: client = claudeExe.map { ClaudeCLIClient(executable: $0) }
        case .apiKey: await connectKey(); return
        case .anthropic: client = apiKey.isEmpty ? nil : AnthropicClient(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        case .ollama: await connectOllama(); return
        case .none: client = nil
        }
        guard let client else { connectionError = "Finish the steps above first."; return }
        struct OK: Decodable { var ok: Bool }
        let t0 = Date()
        do {
            let r: OK = try await AI(client: client, store: nil).json(LLMRequest(prompt: "Reply with exactly {\"ok\": true}", maxTokens: 400))
            guard r.ok else { throw LLMError.badJSON("ok was false") }
            connectedSeconds = Date().timeIntervalSince(t0); connectedProvider = provider
        } catch {
            connectionError = error.plainMessage; connectedProvider = nil
        }
    }

    var keySpec: ProviderSpec? { keyProviders.first { $0.id == keySpecID } }
    var keyAdapter: KeyProviderAdapter? {
        keySpec.map { KeyProviderAdapter(spec: $0, model: keyModel, accountID: keyAccountID, customBaseURL: keyBaseURL) }
    }

    /// Any edit to the key provider's fields means the last test no longer applies.
    func keyFieldsChanged() {
        keyConfig = nil; connectionError = nil
        if connectedProvider == .apiKey { connectedProvider = nil }
    }

    /// The provider a pasted key really belongs to, when it was pasted on another provider's card (e.g. a Claude key on Gemini).
    var keyBelongsElsewhere: ProviderSpec? {
        let owner = ProviderSpec.keyOwner(keyValue, among: (try? ProviderRegistry.visible()) ?? [])
        return owner?.id == keySpecID ? nil : owner
    }

    /// Moves the pasted key to the card it belongs to and tests it there.
    func moveKey(to spec: ProviderSpec) {
        let key = keyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if spec.id == "anthropic" { apiKey = key; provider = .anthropic }
        else { keySpecID = spec.id; keyProviderChanged(); keyValue = key; provider = .apiKey }
        providerChanged()
        Task { await testConnection() }
    }

    func keyProviderChanged() {
        keyModel = keySpec?.picks?.first?.id ?? keySpec?.models.first ?? ""; keyValue = ""; keyModels = []; keyFieldsChanged()
    }

    /// "Sign in with <provider>": the browser hands back a key, which then goes through the same test-and-save steps as a pasted one.
    func signInForKey() {
        guard let endpoints = keySpec?.pkceSignIn else { return }
        longTask?.cancel(); connectionError = nil; keySigningIn = true
        longTask = Task {
            defer { keySigningIn = false }
            do {
                keyValue = try await PKCESignIn(endpoints: endpoints) { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }.authorize()
                keyFieldsChanged()
                await testConnection()
            } catch LoopbackServer.Failure.cancelled {
            } catch { connectionError = error.plainMessage }
        }
    }

    /// OpenRouter's prices change often, so they're read live (cached 24 h). Empty on failure: cards say "price unavailable".
    func loadModels() async {
        guard keySpecID == "openrouter", !AppModel.isUITest, let base = keyAdapter?.baseURL else { return }
        keyModels = await OpenRouterCatalog.models(baseURL: base)
        if keyModel.isEmpty { keyModel = keySpec?.picks?.first?.id ?? keyModels.first?.id ?? "" }
    }

    /// The scoring model for a chosen pick: its `fast` model only when OpenRouter's live list confirms it exists;
    /// otherwise the tested main model (the connection test only tries that one).
    func fastModel(for smart: String) -> String {
        guard let fast = keySpec?.picks?.first(where: { $0.id == smart })?.fast else { return smart }
        return keyModels.contains { $0.id == fast } ? fast : smart
    }

    /// Runs the eight setup steps for the chosen key provider; the key is saved to the keychain only if the strict-JSON test passes.
    func connectKey() async {
        guard let app, let adapter = keyAdapter else { connectionError = "Choose a provider first."; return }
        let t0 = Date()
        let r = await ProviderSetup(adapter, keychain: app.keychain).run(secret: keyValue, approve: { _ in false },
                                                                         progress: { s in Task { @MainActor in self.keyStep = s } })
        keyStep = nil
        switch r {
        case .success(let c): keyConfig = c; connectedSeconds = Date().timeIntervalSince(t0); connectedProvider = .apiKey
        case .failure(let f): connectionError = f.errorDescription; connectedProvider = nil
        }
    }

    /// Runs the eight setup steps for Ollama, ending with the tailoring-sized strict-JSON test. Installing is left to the
    /// Install button (its own consent), so the driver is never allowed to install here.
    func connectOllama() async {
        guard let spec = try? ProviderRegistry.load().first(where: { $0.id == "ollama" }) else {
            connectionError = "Offerlane's provider list is damaged. Reinstall Offerlane, then try again."; return
        }
        let t0 = Date()
        switch await ProviderSetup(OllamaAdapter(spec: spec, model: ollamaModel)).run(approve: { _ in false }) {
        case .success: connectedSeconds = Date().timeIntervalSince(t0); connectedProvider = .ollama
        case .failure(let f): connectionError = f.errorDescription; connectedProvider = nil
        }
    }

    func refreshOllama() async {
        let o = OllamaSetup()
        ollamaInstalled = o.isInstalled
        ollamaRunning = await o.isRunning()
        ollamaModels = ollamaRunning ? ((try? await o.models()) ?? []) : []
        freeDisk = SystemCheck.freeDiskBytes()
    }

    func installOllama() { longTask = Task { _ = await runInstallOllama() } }

    /// Downloads the official release, checks its checksum and signature, installs and starts it.
    @discardableResult
    func runInstallOllama() async -> Bool {
        ollamaError = nil; ollamaInstallProgress = 0; ollamaInstallStatus = "Finding the latest version…"
        defer { ollamaInstallProgress = nil }
        if AppModel.isUITest { return false }
        do {
            _ = try await OllamaSetup.install(phase: { p in Task { @MainActor in self.show(p) } })
            ollamaInstallPaused = false
            await refreshOllama()
            return true
        } catch is CancellationError {
            ollamaInstallPaused = true
        } catch {
            ollamaError = error.plainMessage
        }
        return false
    }

    private func show(_ p: OllamaSetup.InstallPhase) {
        guard ollamaInstallProgress != nil else { return }
        switch p {
        case .checking: ollamaInstallStatus = "Finding the latest version…"
        case .downloading(let f): ollamaInstallStatus = "Downloading Ollama…"; ollamaInstallProgress = f
        case .verifying: ollamaInstallStatus = "Checking it's the genuine Ollama…"; ollamaInstallProgress = 1
        case .installing: ollamaInstallStatus = "Putting Ollama in Applications…"
        case .starting: ollamaInstallStatus = "Starting Ollama…"
        }
    }

    func startOllama() { longTask = Task { await runStartOllama() } }

    @discardableResult
    func runStartOllama() async -> Bool {
        ollamaError = nil; ollamaWorking = "Starting Ollama…"; defer { ollamaWorking = nil }
        do { try await OllamaSetup().launch() } catch { ollamaError = error.plainMessage }
        await refreshOllama()
        return ollamaRunning
    }

    func pullOllamaModel() { longTask = Task { _ = await runPullModel() } }

    /// Downloads the chosen model (continuing a cancelled download), then tests it.
    @discardableResult
    func runPullModel() async -> Bool {
        let model = ollamaModel
        if let c = OllamaSetup.choices.first(where: { $0.name == model }), !OllamaSetup.fits(c, freeDisk: SystemCheck.freeDiskBytes()) {
            ollamaError = "\(model) needs about \(SystemCheck.gb(c.sizeBytes + OllamaSetup.diskMargin)) free, and this Mac has \(SystemCheck.gb(SystemCheck.freeDiskBytes())). Free some space or pick a smaller model, then try again."
            return false
        }
        ollamaError = nil; ollamaPullProgress = 0; ollamaPullStatus = ollamaPausedModel == model ? "Continuing download…" : "Starting download…"
        defer { ollamaPullProgress = nil }
        do {
            try await OllamaSetup().pull(model) { p, s in Task { @MainActor in if p >= 0 { self.ollamaPullProgress = p }; self.ollamaPullStatus = Self.pullStatus(s) } }
            ollamaPausedModel = nil
            await refreshOllama()
            await testConnection()
            return true
        } catch is CancellationError {
            ollamaPausedModel = model
        } catch {
            ollamaError = error.plainMessage
        }
        return false
    }

    /// Ollama reports "pulling 6a0746a1ec1a", "verifying sha256 digest"…; show something friendlier.
    nonisolated static func pullStatus(_ s: String) -> String {
        if s.hasPrefix("pulling") { return "Downloading…" }
        if s.contains("verifying") { return "Checking the download…" }
        if s.contains("writing") || s.contains("manifest") { return "Finishing…" }
        if s == "success" { return "Done" }
        return "Downloading…"
    }

    func removeModel(_ name: String) {
        ollamaWorking = "Removing \(name)…"; ollamaError = nil
        longTask = Task {
            do { try await OllamaSetup().deleteModel(name) } catch { ollamaError = error.plainMessage }
            if ollamaPausedModel == name { ollamaPausedModel = nil }
            await refreshOllama(); ollamaWorking = nil
            if name == ollamaModel { connectedProvider = connectedProvider == .ollama ? nil : connectedProvider }
            app?.refreshHealth()
        }
    }

    func uninstallOllama(removeModels: Bool) {
        ollamaWorking = "Removing Ollama…"; ollamaError = nil
        longTask = Task {
            do { try await OllamaSetup.uninstall(removeModels: removeModels) } catch { ollamaError = error.plainMessage }
            if connectedProvider == .ollama { connectedProvider = nil }
            await refreshOllama(); ollamaWorking = nil
            app?.refreshHealth()
        }
    }

    var ollamaHasModel: Bool { ollamaModels.contains { $0 == ollamaModel || $0 == ollamaModel + ":latest" } }

    /// Saves the connected AI as the one Offerlane uses, or (`asBackup`) adds it after the others as a fallback.
    func saveAI(asBackup: Bool = false) {
        guard let app else { return }
        var s = app.settings
        s.provider = provider
        switch provider {
        case .claudeCLI: s.claudePath = claudeExe?.path ?? ""; s.modelFast = "haiku"; s.modelSmart = "sonnet"
        case .anthropic:
            try? app.keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: Keychain.Account.anthropicKey)
            s.modelFast = AnthropicClient.defaultFast; s.modelSmart = AnthropicClient.defaultSmart
        case .ollama: s.modelFast = ollamaModel; s.modelSmart = ollamaModel; s.baseUrl = ""
        case .apiKey:
            guard let c = keyConfig else { return }
            s.providerID = c.providerID; s.modelFast = fastModel(for: c.model); s.modelSmart = c.model; s.baseUrl = c.baseURL ?? ""
        case .none: break
        }
        if asBackup {
            var base = app.settings
            if provider == .claudeCLI { base.claudePath = s.claudePath }
            base.addBackup(s.connection)
            s = base
        }
        app.settings = s
        app.rebuildAI()
        app.refreshHealth()
    }

    // MARK: resumes

    static let resumeTypes: [UTType] = [.pdf, .plainText, UTType(filenameExtension: "docx"), UTType(filenameExtension: "tex"), UTType(filenameExtension: "md")]
        .compactMap { $0 }

    func add(urls: [URL]) {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = (try? Data(contentsOf: url)) ?? Data()
            let base = url.deletingPathExtension().lastPathComponent
            let label = uploads.isEmpty ? "Main" : base.replacingOccurrences(of: "_", with: " ")
            let u = ResumeUpload(filename: url.lastPathComponent, data: data, label: uniqueLabel(label))
            uploads.append(u); parse(u)
        }
    }

    private func uniqueLabel(_ l: String) -> String {
        var label = l, n = 2
        while uploads.contains(where: { $0.name == ResumeVersion.makeName(from: label) }) { label = "\(l) \(n)"; n += 1 }
        return label
    }

    func parse(_ u: ResumeUpload) {
        guard let app else { return }
        u.state = .parsing; u.task?.cancel()
        guard let ai = app.ai else { u.state = .failed("Connect an AI first (step 1)."); return }
        let name = ResumeVersion.makeName(from: u.label), label = u.label
        u.task = Task {
            do {
                var v = try await ResumeParser(ai: ai).parse(filename: u.filename, data: u.data, name: name, label: label)
                if let old = try? app.store.resume(name), old.name == name { v.isDefault = old.isDefault }
                try app.store.saveResume(v)
                u.version = (try? app.store.resume(name)) ?? v; u.state = .done
            } catch is CancellationError {
            } catch {
                u.state = .failed(error.plainMessage)
            }
        }
    }

    func remove(_ u: ResumeUpload) {
        u.task?.cancel()
        if let v = u.version { try? app?.store.deleteResume(v.name) }
        uploads.removeAll { $0.id == u.id }
        refreshVersions()
    }

    func makeDefault(_ u: ResumeUpload) {
        guard let v = u.version else { return }
        try? app?.store.setDefaultResume(v.name); refreshVersions()
    }

    /// Persist quick edits made in the review card.
    func save(_ u: ResumeUpload) {
        guard var v = u.version else { return }
        v.label = u.label; v.content.label = u.label
        try? app?.store.saveResume(v); u.version = v
    }

    private func refreshVersions() {
        let all = (try? app?.store.resumeVersions()) ?? []
        for u in uploads { if let v = u.version, let fresh = all.first(where: { $0.name == v.name }) { u.version = fresh } }
    }

    /// UI tests can't drive the open panel; they pass files through OFFERLANE_TEST_FILES (colon-separated paths).
    var testFiles: [URL]? {
        TestHooks.env["OFFERLANE_TEST_FILES"].map { $0.split(separator: ":").map { URL(fileURLWithPath: String($0)) } }
    }
}
