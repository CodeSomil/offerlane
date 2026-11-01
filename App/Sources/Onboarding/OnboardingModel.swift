import SwiftUI
import UniformTypeIdentifiers
import OfferlaneCore

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case ai, resumes, about, search, email, notifications, finish
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .ai: "AI"
        case .resumes: "Resumes"
        case .about: "About you"
        case .search: "Search"
        case .email: "Email"
        case .notifications: "Notifications"
        case .finish: "Finish"
        }
    }
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
    var step: OnboardingStep = .ai

    // Step 1: AI
    var provider: AppSettings.Provider = .claudeCLI
    var claudeExe: URL?
    var claudeVersion: String?
    var claudeAuth: ClaudeSetup.AuthStatus?
    var claudeChecking = false
    var claudeInstalling = false
    var claudeInstallLog = ""
    var claudeError: String?
    var showClaudeSignIn = false
    var connectionTesting = false
    var connectionError: String?
    var connectedSeconds: Double?
    var apiKey = ""
    var ollamaInstalled = false
    var ollamaRunning = false
    var ollamaModels: [String] = []
    var ollamaModel = OllamaSetup.recommended().name
    var ollamaInstallProgress: Double?
    var ollamaPullProgress: Double?
    var ollamaPullStatus = ""
    var ollamaError: String?
    var askOllamaInstall = false
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
        if AppModel.isUITest || (s.onboarded && app.aiConnected) { connectedProvider = provider }
        uploads = ((try? app.store.resumeVersions()) ?? []).map(ResumeUpload.init(existing:))
        profile = (try? app.store.profile()) ?? Profile()
        search = (try? app.store.search()) ?? SearchConfig()
        drafted = !search.companies.isEmpty
        email = s.email; notify = s.notify
        if !email.user.isEmpty { emailPassword = app.keychain.get(account: Keychain.Account.imap(email.user)) ?? "" }
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
        case .email: !email.enabled || (!email.user.isEmpty && !emailPassword.isEmpty && !email.host.isEmpty)
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

    func next() {
        guard canGoNext, let i = OnboardingStep.allCases.firstIndex(of: step), i + 1 < OnboardingStep.allCases.count else { return }
        switch step {
        case .ai: saveAI()
        case .about: try? app?.store.set(.profile, profile)
        case .search: try? app?.store.set(.search, search)
        case .email: saveEmail()
        case .notifications: app?.settings.notify = notify
        default: break
        }
        step = OnboardingStep.allCases[i + 1]
        if step == .about { prefillProfile() }
        if step == .search && !drafted { draftSearch() }
    }
    func back() {
        guard let i = OnboardingStep.allCases.firstIndex(of: step), i > 0 else { return }
        step = OnboardingStep.allCases[i - 1]
    }
    /// Save whatever the current step edits (used when Settings re-opens one step and the user jumps to Finish).
    func saveCurrent() {
        switch step {
        case .ai: break
        case .about: try? app?.store.set(.profile, profile)
        case .search: try? app?.store.set(.search, search)
        case .email: saveEmail()
        case .notifications: app?.settings.notify = notify
        default: break
        }
        app?.refresh()
    }
    func go(to s: OnboardingStep) { if s.rawValue <= step.rawValue || canGoNext { step = s } }

    func finish(findNow: Bool) {
        if step != .finish { saveCurrent() }
        try? app?.store.set(.profile, profile); try? app?.store.set(.search, search); app?.settings.notify = notify; app?.refresh()
        app?.settings.onboarded = true
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

    func installClaude() {
        claudeInstalling = true; claudeError = nil; claudeInstallLog = ""
        longTask = Task {
            do {
                let exe = try await ClaudeSetup.install { chunk in Task { @MainActor in self.claudeInstallLog += chunk } }
                claudeExe = exe
                await refreshClaude()
            } catch { claudeError = error.localizedDescription }
            claudeInstalling = false
        }
    }

    func cancelLongTask() { longTask?.cancel(); longTask = nil; claudeInstalling = false; ollamaInstallProgress = nil; ollamaPullProgress = nil }

    /// Builds the client for the current choice and makes one tiny JSON call.
    func testConnection() async {
        connectionTesting = true; connectionError = nil; connectedSeconds = nil
        defer { connectionTesting = false }
        let client: (any LLMClient)?
        switch provider {
        case .claudeCLI: client = claudeExe.map { ClaudeCLIClient(executable: $0) }
        case .anthropic: client = apiKey.isEmpty ? nil : AnthropicClient(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        case .ollama: client = OpenAICompatibleClient(modelFast: ollamaModel, modelSmart: ollamaModel)
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
            connectionError = error.localizedDescription; connectedProvider = nil
        }
    }

    func refreshOllama() async {
        let o = OllamaSetup()
        ollamaInstalled = o.isInstalled
        ollamaRunning = await o.isRunning()
        ollamaModels = ollamaRunning ? ((try? await o.models()) ?? []) : []
    }

    func installOllama() {
        ollamaError = nil; ollamaInstallProgress = 0
        longTask = Task {
            do {
                try await OllamaSetup().install { p in Task { @MainActor in self.ollamaInstallProgress = p } }
                await refreshOllama()
            } catch is CancellationError {} catch { ollamaError = error.localizedDescription }
            ollamaInstallProgress = nil
        }
    }

    func startOllama() {
        ollamaError = nil
        longTask = Task {
            do { try await OllamaSetup().launch() } catch { ollamaError = error.localizedDescription }
            await refreshOllama()
        }
    }

    func pullOllamaModel() {
        ollamaError = nil; ollamaPullProgress = 0; ollamaPullStatus = "Starting download…"
        let model = ollamaModel
        longTask = Task {
            do {
                try await OllamaSetup().pull(model) { p, s in Task { @MainActor in if p >= 0 { self.ollamaPullProgress = p }; self.ollamaPullStatus = s } }
                await refreshOllama()
                await testConnection()
            } catch is CancellationError {} catch { ollamaError = error.localizedDescription }
            ollamaPullProgress = nil
        }
    }

    var ollamaHasModel: Bool { ollamaModels.contains { $0 == ollamaModel || $0 == ollamaModel + ":latest" } }

    private func saveAI() {
        guard let app else { return }
        var s = app.settings
        s.provider = provider
        switch provider {
        case .claudeCLI: s.claudePath = claudeExe?.path ?? ""; s.modelFast = "haiku"; s.modelSmart = "sonnet"
        case .anthropic:
            try? app.keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: Keychain.Account.anthropicKey)
            s.modelFast = AnthropicClient.defaultFast; s.modelSmart = AnthropicClient.defaultSmart
        case .ollama: s.modelFast = ollamaModel; s.modelSmart = ollamaModel; s.baseUrl = ""
        case .none: break
        }
        app.settings = s
        app.rebuildAI()
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
                u.state = .failed(error.localizedDescription)
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
        ProcessInfo.processInfo.environment["OFFERLANE_TEST_FILES"].map { $0.split(separator: ":").map { URL(fileURLWithPath: String($0)) } }
    }
}
