import SwiftUI
import UserNotifications
import LocalAuthentication
import WebKit
import OfferlaneCore

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    // Raw values stay stable (accessibility identifiers, saved state); titles are what users see.
    // Declared in sidebar order: ⌘-numbers and the menu follow it.
    case home, find, review, applications, interview, goals, skills, resumes, connectAI, settings
    var id: String { rawValue }
    /// The five v4 sidebar groups (mockup D5).
    enum Group: String, CaseIterable { case today = "Today", find = "Find", pipeline = "Pipeline", grow = "Grow", profile = "Profile" }
    var group: Group {
        switch self {
        case .home: .today
        case .find, .review: .find
        case .applications, .interview: .pipeline
        case .goals, .skills: .grow
        case .resumes, .connectAI, .settings: .profile
        }
    }
    var title: String {
        switch self {
        case .home: "Today"
        case .find: "Discover"
        case .review: "Review"
        case .applications: "Pipeline"
        case .goals: "Goals"
        case .skills: "Skills"
        case .interview: "Interview Prep"
        case .resumes: "Resumes"
        case .connectAI: "Connect AI"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .home: "sun.max"
        case .find: "sparkle.magnifyingglass"
        case .review: "checklist"
        case .applications: "rectangle.split.3x1"
        case .goals: "flag"
        case .skills: "graduationcap"
        case .interview: "person.wave.2"
        case .resumes: "doc.text"
        case .connectAI: "cpu"
        case .settings: "gearshape"
        }
    }
    /// ⌘1…⌘9 then ⌘0 in sidebar order.
    var shortcut: KeyEquivalent { KeyEquivalent(Character("\(((SidebarItem.allCases.firstIndex(of: self) ?? 0) + 1) % 10)")) }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var isError = false
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil
    init(message: String, undoLabel: String? = nil, undo: (() -> Void)? = nil) {
        self.message = message; actionLabel = undoLabel; action = undo
    }
    /// An error with a way out ("Try again" / "Fix it").
    static func error(_ message: String, _ label: String, _ action: @escaping () -> Void) -> Toast {
        var t = Toast(message: message, undoLabel: label, undo: action); t.isError = true; return t
    }
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

struct Notice: Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
    let date = Date()
}

/// Edits a screen hasn't saved yet; navigation asks before throwing them away.
struct UnsavedWork {
    let message: String
    var save: (() -> Void)? = nil
    let discard: () -> Void
}

enum PendingNavigation: Equatable { case item(SidebarItem), back }

/// Everything the main window shows, read off the main thread in one go.
struct DataSnapshot: Sendable {
    var jobs: [Job] = []
    var hiddenCount = 0
    var search = SearchConfig()
    var versions: [ResumeVersion] = []
    var tracked: [Job] = []
    var removed: [Job] = []
    var events: [JobEvent] = []
    var usage: [UsageDay] = []
    var accounts: [SiteAccount] = []
    var contacts: [Contact] = []

    static func load(_ store: Store) -> DataSnapshot {
        var s = DataSnapshot()
        let all = (try? store.jobs()) ?? []
        s.jobs = all.filter { !$0.status.isHidden }
        s.hiddenCount = all.count - s.jobs.count
        s.search = (try? store.search()) ?? SearchConfig()
        s.versions = (try? store.resumeVersions()) ?? []
        s.tracked = all.filter { JobStatus.tracked.contains($0.status) }.sorted { $0.updated > $1.updated }
        s.removed = all.filter { [.rejected, .withdrawn].contains($0.status) }.sorted { $0.updated > $1.updated }
        s.events = (try? store.events(limit: 400)) ?? []
        s.usage = (try? store.usage(days: 30)) ?? []
        s.accounts = (try? store.accounts()) ?? []
        s.contacts = (try? Contacts.load(store)) ?? []
        return s
    }
}

/// App-wide state shared by windows, the toolbar and the menu bar extra.
/// Where the app is in signing in.
enum AuthPhase: Equatable {
    case signedOut
    /// Signed in, waiting for Touch ID / the Mac password to unlock.
    case locked(LocalAccount)
    /// Just signed in for the first time and v0.1 data was found: ask before moving it.
    case claiming(LocalAccount)
    case signedIn
}

/// App-wide state shared by windows, the toolbar and the menu bar extra.
@MainActor @Observable
final class AppModel {
    /// The open account's database (an empty in-memory one while signed out).
    private(set) var store: Store
    private(set) var keychain: Keychain
    var settings: AppSettings { didSet { try? store.set(.settings, settings) } }
    private(set) var ai: AI?
    var onboarding: OnboardingModel!
    var apply: ApplyController!
    /// Opens the Apply window (set by the main window; handed to each profile's ApplyController).
    @ObservationIgnored var openApplyWindow: (() -> Void)? { didSet { apply?.openWindow = openApplyWindow } }

    // Accounts
    @ObservationIgnored let accounts = AccountStore()
    @ObservationIgnored let oauthConfig = OAuthConfig.load()
    private(set) var account: LocalAccount?
    var auth: AuthPhase = .signedOut
    var authBusy = false
    var authMessage: String?
    var authError: String?
    @ObservationIgnored private var authTask: Task<Void, Never>?
    /// Gmail API tokens with the read-only scope are in Keychain for this account.
    private(set) var gmailLinked = false

    var selection: SidebarItem? = .find
    var searchText = ""
    /// Unsaved edits on the current screen, and a navigation waiting on the user's answer about them.
    var unsaved: UnsavedWork?
    var pendingNavigation: PendingNavigation?
    /// A problem opening the database, shown instead of the app.
    var fatalError: String?

    // Data (refreshed off the main thread)
    private(set) var loaded = false
    private(set) var data = DataSnapshot()
    var jobs: [Job] { data.jobs }
    var hiddenCount: Int { data.hiddenCount }
    var search: SearchConfig { data.search }
    var versions: [ResumeVersion] { data.versions }
    @ObservationIgnored private var refreshGeneration = 0
    /// Milliseconds from process start until the main window had its data (shown to perf tests).
    private(set) var launchMillis: Int?

    // Find Jobs
    var isFinding = false
    var findProgress: FindProgress? { didSet { if let m = findProgress?.message, m != findLog.last { findLog.append(m) } } }
    /// Steps of the current Find Jobs run, for the progress stream.
    private(set) var findLog: [String] = []
    var lastSummary: FindJobs.Summary?
    @ObservationIgnored private var findTask: Task<Void, Never>?

    var toast: Toast? {
        didSet {
            guard let toast, toast.id != oldValue?.id else { return }
            notices.insert(Notice(message: toast.message, isError: toast.isError), at: 0)
            if notices.count > 20 { notices.removeLast() }
            unreadNotices += 1
        }
    }
    /// This session's toasts for the notifications popover (text only: undo actions aren't replayable).
    private(set) var notices: [Notice] = []
    var unreadNotices = 0
    var showPalette = false

    // Setup Center and the sidebar health dot (AppModel+Health.swift)
    var health: [Health.Item] = []
    /// Ollama is started at most once per launch, so quitting it later isn't overridden.
    var ollamaAutoStarted = false
    var healthChecking = false
    var repairing: String?
    var repairResult: String?
    var showSetupCenter = false
    var showDiagnostics = false
    /// Index into TourStop.all while the product tour is showing.
    var tourStep: Int?
    @ObservationIgnored var healthTask: Task<Void, Never>?

    // Tailoring (background, one role at a time)
    private(set) var tailorQueue: TailorQueue
    var tailoringMessage: String?
    var reviewing: String?

    var aiConnected: Bool { ai != nil }
    nonisolated static var isUITest: Bool { TestHooks.env["OFFERLANE_FAKE_AI"] == "1" }
    private nonisolated static var env: [String: String] { TestHooks.env }
    /// Self-tests and UI tests (unless they test sign-in with OFFERLANE_AUTH=1) use the base folder without signing in.
    nonisolated static var authBypass: Bool { env["OFFERLANE_SELFTEST"] != nil || (isUITest && env["OFFERLANE_AUTH"] != "1") }

    init() {
        let empty = try! Store()
        store = empty
        keychain = Keychain(service: Paths.keychainService(for: nil))
        tailorQueue = TailorQueue(store: empty)
        settings = AppSettings()
        // Placeholders until a profile opens, so every screen (and the Settings window) has something to bind to.
        onboarding = OnboardingModel(app: self)
        apply = ApplyController(app: self)
        if Self.authBypass {
            open(nil)
            if let mode = Self.env["OFFERLANE_SELFTEST"] {
                Task { @MainActor in
                    let code = mode == "real" ? await RealSiteSmoke.run(app: self)
                        : mode == "package" ? await PackageSelfTest.run(app: self) : await ApplySelfTest.run(app: self)
                    exit(code)
                }
            }
            return
        }
        // UI tests of sign-in can simulate a v0.1 install: seeded data in the base folder, waiting to be claimed.
        if Self.env["OFFERLANE_SEED"] != nil, Self.env["OFFERLANE_HOME"] != nil,
           let legacy = try? Store(url: Paths.base.appendingPathComponent("offerlane.sqlite")) { Self.seed(legacy) }
        if let s = accounts.session, let a = accounts.account(s.accountID) {
            // Locked if either copy of the setting asks for it: the Keychain one can't be edited away like a file.
            if (a.touchID || s.touchID) && !Self.isUITest { auth = .locked(a) } else { open(a) }
        }
    }

    private static func seed(_ store: Store) {
        switch env["OFFERLANE_SEED"] {
        case "matches": try? DemoData.seedMatches(store)
        case "applications": try? DemoData.seedApplications(store)
        case "followup": try? DemoData.seedFollowUp(store)
        case "sources": try? DemoData.seedSources(store)
        case "ollama": try? DemoData.seedOllama(store)
        case "many": try? DemoData.seedMany(store)
        case "showcase": try? DemoData.seedShowcase(store)
        default: break
        }
    }

    /// Opens an account's data (nil = the base folder: self-tests and UI tests).
    private func open(_ a: LocalAccount?) {
        Paths.account = a?.id
        WebPage.storeID = Paths.webStoreID(for: a?.id, legacy: a?.claimedLegacy ?? true)
        do { store = try Store.openDefault(); fatalError = nil } catch {
            store = try! Store()
            Log.error("open store: \(error)")
            fatalError = (error as? StoreError).flatMap(\.errorDescription)
                ?? "Offerlane couldn't open your data. Restart your Mac and try again. If it keeps happening, use Help → Send Diagnostics."
        }
        keychain = Keychain(service: Paths.keychainService(for: a?.id))
        tailorQueue = TailorQueue(store: store)
        if a == nil { Self.seed(store) }  // before settings are read, so a seed can set them
        settings = (try? store.settings()) ?? AppSettings()
        if Self.env["OFFERLANE_ONBOARDED"] == "1" { settings.onboarded = true }
        // UI tests: comma-separated Ollama model names become the connected AIs, in order.
        if let models = Self.env["OFFERLANE_CONNECTIONS"] {
            settings.connections = models.split(separator: ",").map { AppSettings.Connection(provider: .ollama, modelFast: String($0), modelSmart: String($0)) }
        }
        account = a
        gmailLinked = a.flatMap { accounts.googleTokens(for: $0.id) }.map { $0.has(GoogleOAuth.gmailScope) && $0.refreshToken != nil } ?? false
        loaded = false; data = DataSnapshot(); selection = .find; reviewing = nil; lastSummary = nil; unsaved = nil
        rebuildAI()
        onboarding = OnboardingModel(app: self)
        apply = ApplyController(app: self)
        apply.openWindow = openApplyWindow
        auth = .signedIn
        refresh()
        if Self.env["OFFERLANE_SELFTEST"] == nil { kickTailoring(); refreshHealth() }
        let opened = store
        Task.detached(priority: .background) { SafeDownloader.cleanup(); _ = try? opened.pruneCache(); LegacyData.removeBackups() }
    }

    // MARK: sign in / out

    var googleSignInReady: Bool { oauthConfig.isConfigured }
    var gmailAvailable: Bool { oauthConfig.gmailEnabled && oauthConfig.isConfigured }

    private func googleOAuth() -> GoogleOAuth {
        GoogleOAuth(config: oauthConfig) { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }
    }

    private func runAuth(_ message: String, _ work: @escaping @MainActor () async throws -> Void) {
        authTask?.cancel()
        authError = nil; authMessage = message; authBusy = true
        authTask = Task {
            do { try await work() }
            catch is CancellationError {}
            catch LoopbackServer.Failure.cancelled {}
            catch { authError = (error as? LocalizedError)?.errorDescription ?? error.plainMessage }
            authBusy = false; authMessage = nil
        }
    }
    func cancelAuth() { authTask?.cancel(); authBusy = false; authMessage = nil }

    func signInWithGoogle() {
        runAuth("Finish signing in with Google in your browser…") { [self] in
            let grant = try await googleOAuth().authorize()
            finishSignIn(try accounts.googleAccount(for: grant.identity))
        }
    }

    func createProfile(name: String, email: String, password: String, touchID: Bool) {
        runAuth("Creating your profile…") { [self] in
            let accounts = accounts
            var a = try await Task.detached { try accounts.createPasswordAccount(email: email, name: name, password: password) }.value
            if touchID { a.touchID = true; try accounts.save(a) }
            finishSignIn(a)
        }
    }

    func signIn(email: String, password: String) {
        runAuth("Signing in…") { [self] in
            let accounts = accounts
            finishSignIn(try await Task.detached { try accounts.signIn(email: email, password: password) }.value)
        }
    }

    private func finishSignIn(_ a: LocalAccount) {
        if LegacyData.available(accounts: accounts) { auth = .claiming(a); return }
        try? accounts.startSession(a)
        open(a)
    }

    /// The answer to "Claim existing data?".
    func resolveLegacy(claim: Bool) {
        guard case .claiming(let a) = auth else { return }
        runAuth(claim ? "Moving your existing data (a backup is made first)…" : "Setting up…") { [self] in
            var message: String?
            if claim {
                let accounts = accounts, id = a.id
                let r = try await Task.detached { try LegacyData.claim(into: id, accounts: accounts) }.value
                message = "Your existing data is now in this profile (\(r.roles) role\(r.roles == 1 ? "" : "s")). A backup copy is kept for \(LegacyData.keepDays) days."
            } else {
                try LegacyData.decline(accounts: accounts)
            }
            try? accounts.startSession(a)
            open(accounts.account(a.id) ?? a)
            if let message { toast = Toast(message: message) }
        }
    }

    /// Touch ID (or the Mac password) to unlock a profile that asks for it.
    func unlock() {
        guard case .locked(let a) = auth else { return }
        runAuth("Waiting for Touch ID…") { [self] in
            let ctx = LAContext()
            ctx.localizedCancelTitle = "Not Now"
            guard try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock your Offerlane profile") else { return }
            open(a)
        }
    }

    func setTouchID(_ on: Bool) {
        guard var a = account else { return }
        a.touchID = on; try? accounts.save(a); account = a
        try? accounts.setSessionTouchID(on)
    }

    /// Sign out: tokens leave memory and Keychain; the profile's data stays on this Mac.
    func signOut() {
        findTask?.cancel(); authTask?.cancel()
        apply.stopForSignOut()
        // Cancel Gmail access at Google too, not just the local copy: a copied token would otherwise stay valid.
        if let a = account, let t = accounts.googleTokens(for: a.id) {
            let oauth = googleOAuth(), token = t.refreshToken ?? t.accessToken
            Task.detached { await oauth.revoke(token) }
        }
        accounts.signOut()
        Paths.account = nil
        store = try! Store(); keychain = Keychain(service: "com.somilmanke.Offerlane.signed-out")
        tailorQueue = TailorQueue(store: store)
        settings = AppSettings(); ai = nil; account = nil; gmailLinked = false
        loaded = false; data = DataSnapshot(); toast = nil; notices = []; unreadNotices = 0; unsaved = nil; reviewing = nil
        isFinding = false; findProgress = nil
        auth = .signedOut
    }

    /// "Forgot password": erase that local profile entirely.
    func eraseProfile(email: String) {
        guard let a = accounts.account(email: email, kind: .password) else { authError = AccountStore.AuthFailure.unknownEmail.errorDescription; return }
        // Erasing needs the Mac's owner (Touch ID or the Mac password), not just someone at the sign-in screen.
        runAuth("Confirm it's you…") { [self] in
            let ctx = LAContext()
            guard try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "erase the Offerlane profile for \(a.email)") else { return }
            let storeID = Paths.webStoreID(for: a.id, legacy: a.claimedLegacy)
            do { try accounts.erase(a.id) } catch {
                Log.error("erase: \(error)")
                authError = "That profile couldn't be fully erased. Quit Offerlane, reopen it, then try again."; return
            }
            if (try? await WKWebsiteDataStore.remove(forIdentifier: storeID)) == nil {
                Log.error("erase: career-site sign-ins not removed")
            }
            authError = nil; authMessage = nil; toast = Toast(message: "That profile was erased, including its saved career-site sign-ins. You can create a new one.")
        }
    }

    /// Settings → Delete All My Data: database, Keychain secrets, files, logs, v0.1 backups and career-site sign-ins.
    /// Returns what couldn't be removed (nil when everything went).
    func deleteEverything() async -> String? {
        apply.stopForSignOut()
        apply = ApplyController(app: self); apply.openWindow = openApplyWindow   // drop the browser using this profile's data
        do { try DataTools.deleteAll(store: store, keychain: keychain) } catch {
            Log.error("deleteAll: \(error)"); return "Some of your data couldn't be deleted. Quit other apps that might be using it, then try again."
        }
        if account?.claimedLegacy == true || account == nil { LegacyData.removeBackups(olderThanDays: 0) }
        var problem: String?
        do { try await WKWebsiteDataStore.remove(forIdentifier: WebPage.storeID) }
        catch { Log.error("deleteAll: web data: \(error)"); problem = "Your data was deleted, but saved career-site sign-ins couldn't be cleared yet. Quit and reopen Offerlane, then delete again." }
        settings = AppSettings(); rebuildAI(); refresh()
        Self.crashReportsSince = nil   // the opt-in goes with the data; the outbox lives in Logs, already removed
        onboarding = OnboardingModel(app: self)
        return problem
    }

    // MARK: Gmail (Testing-mode preview)

    func connectGmail() {
        guard let a = account else { return }
        if gmailLinked { settings.email.gmail = true; settings.email.enabled = true; return }   // already granted: reuse the token
        runAuth("Finish connecting Gmail in your browser…") { [self] in
            let grant = try await googleOAuth().authorize(scopes: GoogleOAuth.signInScopes + [GoogleOAuth.gmailScope],
                                                          loginHint: a.kind == .google ? a.email : nil)
            guard grant.tokens.has(GoogleOAuth.gmailScope), grant.tokens.refreshToken != nil else {
                throw GmailConnectError.scopeNotGranted
            }
            // A Google profile can only connect its own Gmail.
            if a.kind == .google, let sub = a.googleSub, sub != grant.identity.sub {
                await googleOAuth().revoke(grant.tokens.refreshToken ?? grant.tokens.accessToken)
                throw GmailConnectError.otherAccount(a.email)
            }
            try accounts.saveGoogleTokens(grant.tokens, for: a.id)
            gmailLinked = true
            settings.email.gmail = true; settings.email.enabled = true
            toast = Toast(message: "Gmail connected as \(grant.identity.email). Offerlane will read replies from employers (read-only).")
        }
    }

    func disconnectGmail() {
        guard let a = account else { return }
        if let t = accounts.googleTokens(for: a.id) {
            let oauth = googleOAuth(), token = t.refreshToken ?? t.accessToken
            Task.detached { await oauth.revoke(token) }
        }
        accounts.deleteGoogleTokens(for: a.id)
        gmailLinked = false; settings.email.gmail = false
    }

    private func gmailClient() -> GmailClient? {
        guard settings.email.gmail, gmailLinked, let a = account else { return nil }
        let provider = GoogleTokenProvider(oauth: googleOAuth(), accounts: accounts, accountID: a.id)
        return GmailClient { try await provider.token() }
    }

    /// Gmail stopped accepting the token: say so plainly and offer to reconnect.
    private func gmailRevoked() {
        gmailLinked = false
        toast = .error("Offerlane's access to Gmail has expired or was removed (preview access lasts 7 days).", "Fix it") { [weak self] in
            self?.navigate(to: .settings)
        }
    }

    func rebuildAI() {
        ai = AIFactory.client(settings, keychain: keychain).map { AI(client: $0, store: store) }
    }

    /// Tailor whatever is waiting (also resumes work left over from a quit or crash).
    func kickTailoring() {
        let queue = tailorQueue, ai = ai
        Task {
            await queue.configure(ai: ai, tokenLimit: settings.tailorTokenLimit) { msg in Task { @MainActor in self.tailoringMessage = msg; self.refresh() } }
            let made = await queue.kick()
            refresh()
            if made > 0 {
                Notifier.post(title: "Ready for your review", body: made == 1 ? "A tailored resume is ready for your review." : "\(made) tailored resumes are ready for your review.",
                              settings: settings, category: "REVIEW")
            }
        }
    }

    /// One notification per due follow-up date; the date is recorded so later refreshes stay quiet.
    /// The body carries a count only: names are third parties' data and ntfy (if on) is a public server.
    private func remindFollowUps(_ contacts: [Contact]) {
        let due = Contacts.toRemind(contacts)
        guard !due.isEmpty else { return }
        Notifier.post(title: "Time to follow up", body: due.count == 1 ? "1 follow-up is due today." : "\(due.count) follow-ups are due today.", settings: settings)
        do { data.contacts = try Contacts.change(store) { $0 = Contacts.markReminded($0) } } catch { Log.error("contacts: couldn't record reminders: \(error.plainMessage)") }
    }

    /// Re-read everything on a background thread; the newest read wins.
    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration, store = store
        Task.detached(priority: .userInitiated) {
            let snapshot = DataSnapshot.load(store)
            await MainActor.run {
                guard generation == self.refreshGeneration else { return }
                self.data = snapshot
                self.remindFollowUps(snapshot.contacts)
                if !self.loaded {
                    self.loaded = true
                    self.launchMillis = ProcessClock.millisSinceLaunch()
                    self.collectCrashReports()
                    if snapshot.jobs.contains(where: { Self.reviewStatuses.contains($0.status) }) && self.selection == .find { self.selection = .review }
                    if (try? store.corruptBackups())?.contains(where: { $0.hasSuffix(Dates.today()) }) == true {
                        self.toast = Toast(message: "Some saved settings couldn't be read, so they were reset to defaults. Offerlane kept a copy of the old data. Check Settings and your profile.")
                    }
                }
            }
        }
    }

    // MARK: navigation

    /// Go to a sidebar screen, asking first if the current screen has unsaved edits.
    func navigate(to item: SidebarItem) {
        guard item != selection || reviewing != nil else { return }
        if unsaved != nil { pendingNavigation = .item(item); return }
        withDSAnimation { reviewing = nil; selection = item }
    }
    /// Leave the resume review, asking first about unsaved edits.
    func closeReview() {
        if unsaved != nil { pendingNavigation = .back; return }
        withDSAnimation { reviewing = nil }
    }
    /// The user's answer to "you have unsaved changes".
    func resolvePendingNavigation(save: Bool) {
        if let u = unsaved { save ? u.save?() : u.discard() }
        unsaved = nil
        let target = pendingNavigation; pendingNavigation = nil
        withDSAnimation {
            switch target {
            case .item(let i): reviewing = nil; selection = i
            case .back: reviewing = nil
            case nil: break
            }
        }
    }

    // MARK: derived lists

    func jobs(_ statuses: JobStatus...) -> [Job] { jobs.filter { statuses.contains($0.status) } }
    var matches: [Job] { jobs(.found).sorted { $0.score > $1.score } }
    var strongMatches: [Job] { matches.filter { ($0.llmScore ?? -1) >= search.minScore } }
    var weakerMatches: [Job] { matches.filter { ($0.llmScore ?? -1) < search.minScore } }

    static let reviewStatuses: [JobStatus] = [.prefilled, .needsYou, .account, .review]
    /// Roles waiting on the user (the Review badge and the menu bar count).
    var reviewCount: Int { jobs.filter { Self.reviewStatuses.contains($0.status) }.count }

    // MARK: Find Jobs

    func findJobs() {
        guard !isFinding else { return }
        guard let ai else {
            toast = .error("Offerlane needs an AI to score roles, and none is connected yet.", "Fix it") { [weak self] in self?.navigate(to: .settings) }
            return
        }
        if selection != .find { navigate(to: .find) }
        isFinding = true; findLog = []; findProgress = FindProgress("Starting…", 0)
        let store = store, sources = JobSources.configured(keychain: keychain, search: search)
        findTask = Task { [self] in  // explicit: the toast closures below capture self weakly
            do {
                let summary = try await FindJobs(store: store, ai: ai, tracking: tracking(), tokenLimit: settings.runTokenLimit, sources: sources).run { p in Task { @MainActor in self.findProgress = p } }
                lastSummary = summary
                refresh()
                let good = summary.ranking.good
                let text = good > 0 ? "\(good) new role\(good == 1 ? "" : "s") match you. Open Offerlane to approve the ones to apply for."
                                    : "Search finished. No strong new matches this time."
                toast = Toast(message: "Checked \(summary.discovery.checked) career sites" + summary.discovery.sourcesChecked.map { " + " + $0 }.joined() + ": \(summary.discovery.new) new, \(good) strong matches."
                              + (summary.fallback.isEmpty ? "" : " Your main AI was busy, so \(summary.fallback) answered."))
                Notifier.post(title: "Offerlane", body: text, settings: settings)
                if !summary.errors.isEmpty {
                    let n = summary.errors.count
                    Log.error("find: " + summary.errors.joined(separator: " | "))
                    toast = .error("\(n) career site\(n == 1 ? "" : "s") couldn't be checked this time. The rest were checked.", "Try again") { [weak self] in self?.findJobs() }
                }
                if let stop = summary.budgetStop {
                    toast = .error(stop, "Change Limit") { [weak self] in self?.navigate(to: .settings) }
                }
            } catch is CancellationError {
                toast = Toast(message: "Find Jobs stopped.")
                refresh()
            } catch {
                toast = .error("Find Jobs stopped early: \(error.plainMessage)", "Try again") { self.findJobs() }
            }
            isFinding = false; findProgress = nil
        }
    }

    func cancelFind() { findTask?.cancel() }

    // MARK: email

    /// The inbox reader: Gmail when connected (preview), otherwise IMAP with the app password from Keychain.
    func tracking() -> Tracking? {
        let e = settings.email
        guard e.enabled else { return nil }
        if let g = gmailClient() {
            return Tracking(store: store, ai: ai) { try await g.fetch(days: 4) { _ in false } }
        }
        guard !e.user.isEmpty, let pw = keychain.get(account: Keychain.Account.imap(e.user)) else { return nil }
        let host = e.host, port = UInt16(clamping: e.port), user = e.user
        return Tracking(store: store, ai: ai) { try await Tracking.imapFetch(host: host, port: port, user: user, password: pw) }
    }
    var checkingInbox = false
    func checkInbox() {
        guard let t = tracking() else {
            toast = .error("Email tracking is off, so Offerlane can't read replies yet.", "Fix it") { [weak self] in self?.navigate(to: .settings) }
            return
        }
        checkingInbox = true
        Task {
            do { let r = try await t.run(); toast = Toast(message: "Checked \(r.checked) emails: \(r.updates) status update\(r.updates == 1 ? "" : "s").") }
            catch OAuthError.revoked { gmailRevoked() }
            catch { toast = .error("Couldn't check your inbox: \(error.plainMessage)", "Try again") { self.checkInbox() } }
            checkingInbox = false; refresh()
        }
    }
    /// Polls the inbox for a career-site verification link (Workday sign-up), up to 90 seconds. Only a link on `site`
    /// (or Workday) from a sender on `site` (or Workday) is returned; see Tracking.verification.
    func verificationLink(_ hint: String, site: String) async -> String? {
        let e = settings.email
        if let g = gmailClient() {
            for _ in 0..<9 {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                // Gmail lists newest first; verification() wants oldest first.
                if let newest = try? await g.fetch(days: 1, limit: 30, needsBody: { Re.search("verif|activat|confirm", $0.subject) }) {
                    let mails = Array(newest.reversed())
                    if let v = Tracking.verification(in: mails, hint: hint, site: site) ?? Tracking.verification(in: mails, hint: "workday", site: site), let link = v.link { return link }
                }
            }
            return nil
        }
        guard e.enabled, let pw = keychain.get(account: Keychain.Account.imap(e.user)) else { return nil }
        for _ in 0..<9 {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if let mails = try? await Tracking.imapFetch(host: e.host, port: UInt16(clamping: e.port), user: e.user, password: pw, days: 1, bodyBytes: 20000),
               let v = Tracking.verification(in: mails, hint: hint, site: site) ?? Tracking.verification(in: mails, hint: "workday", site: site), let link = v.link { return link }
        }
        return nil
    }

    // MARK: applications board

    var allTracked: [Job] { data.tracked }
    var removed: [Job] { data.removed }
    func move(_ id: String, to s: JobStatus) {
        let old = data.tracked.first { $0.id == id }?.status ?? data.removed.first { $0.id == id }?.status
        do {
            try store.transition(id, to: s, by: "you", detail: "moved on the board"); refresh()
            if let old, [.rejected, .withdrawn].contains(s) {
                toast = Toast(message: "Moved to \(s.rawValue.capitalized). It's hidden from the board; tick Show removed to see it.", undoLabel: "Undo") { [weak self] in
                    self?.restoreStatus(id, to: old)
                }
            }
        } catch {
            toast = Toast(message: "An application can't move straight to \(s.rawValue.capitalized) from where it is now. Open it to change its status step by step.")
        }
    }

    /// Undo for status changes: a normal transition when allowed, otherwise put the old status back directly.
    func restoreStatus(_ id: String, to old: JobStatus) {
        if (try? store.transition(id, to: old, by: "you", detail: "undo")) == nil { _ = try? store.update(id) { $0.status = old } }
        refresh(); toast = Toast(message: "Restored.")
    }
    func saveNotes(_ id: String, _ notes: String) { _ = try? store.update(id) { $0.notes = notes } }
    /// Saves only a real change, and doesn't touch `updated` (card age and analytics read it).
    func saveInterviewAt(_ id: String, _ date: Date?) {
        let value = date.map { Dates.now($0) }
        do {
            guard var j = try store.job(id), j.interviewAt != value else { return }
            j.interviewAt = value; try store.save(j); refresh()
        } catch {
            toast = .error("Couldn't save the interview time: \(error.plainMessage).", "Try Again") { [weak self] in self?.saveInterviewAt(id, date) }
        }
    }

    // MARK: decisions (gate 1)

    func approve(_ ids: Set<String>) {
        var n = 0
        for id in ids where (try? store.transition(id, to: .tailoring, by: "you", detail: "approved role") { $0.error = "" }) != nil { n += 1 }
        refresh(); kickTailoring()
        toast = Toast(message: n == 1 ? "Approved. Offerlane will tailor your resume next." : "Approved \(n) roles. Offerlane will tailor your resumes next.")
    }

    func decline(_ ids: Set<String>) {
        var done: [String] = []
        for id in ids where (try? store.transition(id, to: .declined, by: "you", detail: "declined")) != nil { done.append(id) }
        refresh()
        guard !done.isEmpty else { return }
        toast = Toast(message: done.count == 1 ? "Declined. It won't come back in later searches." : "Declined \(done.count) roles.", undoLabel: "Undo") { [weak self] in
            guard let self else { return }
            // The description was dropped on decline; it returns on the next search.
            for id in done { _ = try? self.store.transition(id, to: .found, by: "you", detail: "undo decline") }
            self.refresh(); self.toast = Toast(message: "Restored.")
        }
    }

    func retryTailoring(_ id: String) {
        _ = try? store.update(id) { $0.error = "" }; refresh(); kickTailoring()
    }

    func setVariant(_ id: String, _ name: String) {
        _ = try? store.update(id) { $0.variant = name }; refresh()
    }
}

/// Mac notifications (and ntfy when enabled).
enum Notifier {
    static func post(title: String, body: String, settings: AppSettings, category: String? = nil) {
        if settings.notify.desktop && !AppModel.isUITest {
            let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
            if let category { c.categoryIdentifier = category }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
        if settings.notify.ntfy && !AppModel.isUITest {
            let topic = settings.notify.ntfyTopic
            Task { try? await Ntfy.send(topic: topic, title: title, message: body) }
        }
    }
}

/// Process start time, for the launch-to-interactive measurement.
enum ProcessClock {
    static func millisSinceLaunch() -> Int? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return Int((Date().timeIntervalSince1970 - started) * 1000)
    }
}

enum GmailConnectError: LocalizedError {
    case scopeNotGranted
    case otherAccount(String)
    var errorDescription: String? {
        switch self {
        case .scopeNotGranted: "Gmail wasn't connected because read access wasn't allowed. Try again and tick the Gmail box on Google's page, or keep using IMAP."
        case .otherAccount(let email): "That was a different Google account. Connect the Gmail for \(email), the account this profile signs in with."
        }
    }
}
