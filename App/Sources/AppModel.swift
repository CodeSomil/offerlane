import SwiftUI
import UserNotifications
import OfferlaneCore

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case todo, matches, resumes, applications, activity, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .todo: "To Do"
        case .matches: "Matches"
        case .resumes: "Resumes"
        case .applications: "Applications"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .todo: "checklist"
        case .matches: "sparkle.magnifyingglass"
        case .resumes: "doc.text"
        case .applications: "rectangle.split.3x1"
        case .activity: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var undoLabel: String? = nil
    var undo: (() -> Void)? = nil
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// App-wide state shared by windows, the toolbar and the menu bar extra.
@MainActor @Observable
final class AppModel {
    let store: Store
    let keychain = Keychain()
    var settings: AppSettings { didSet { try? store.set(.settings, settings) } }
    private(set) var ai: AI?
    var onboarding: OnboardingModel!
    var apply: ApplyController!

    var selection: SidebarItem? = .todo
    var searchText = ""
    /// A problem opening the database, shown instead of the app.
    var fatalError: String?

    // Data
    private(set) var jobs: [Job] = []
    private(set) var hiddenCount = 0
    private(set) var search = SearchConfig()
    private(set) var versions: [ResumeVersion] = []

    // Find Jobs
    var isFinding = false
    var findProgress: FindProgress?
    var lastSummary: FindJobs.Summary?
    @ObservationIgnored private var findTask: Task<Void, Never>?

    var toast: Toast?

    // Tailoring (background, one role at a time)
    let tailorQueue: TailorQueue
    var tailoringMessage: String?
    var reviewing: String?

    var aiConnected: Bool { ai != nil }
    nonisolated static var isUITest: Bool { ProcessInfo.processInfo.environment["OFFERLANE_FAKE_AI"] == "1" }

    init() {
        let store: Store
        do { store = try Store.openDefault() } catch {
            store = try! Store()
            fatalError = "Offerlane couldn't open its data in \(Paths.root.path): \(error.localizedDescription)"
        }
        self.store = store
        tailorQueue = TailorQueue(store: store)
        settings = (try? store.settings()) ?? AppSettings()
        if ProcessInfo.processInfo.environment["OFFERLANE_ONBOARDED"] == "1" { settings.onboarded = true }
        if ProcessInfo.processInfo.environment["OFFERLANE_SEED"] == "matches" { try? DemoData.seedMatches(store) }
        if ProcessInfo.processInfo.environment["OFFERLANE_SEED"] == "applications" { try? DemoData.seedApplications(store) }
        rebuildAI()
        onboarding = OnboardingModel(app: self)
        apply = ApplyController(app: self)
        refresh()
        if let mode = ProcessInfo.processInfo.environment["OFFERLANE_SELFTEST"] {
            Task { @MainActor in
                let code = mode == "real" ? await RealSiteSmoke.run(app: self)
                    : mode == "package" ? await PackageSelfTest.run(app: self) : await ApplySelfTest.run(app: self)
                exit(code)
            }
            return
        }
        kickTailoring()
    }

    func rebuildAI() {
        ai = AIFactory.client(settings, keychain: keychain).map { AI(client: $0, store: store) }
    }

    /// Tailor whatever is waiting (also resumes work left over from a quit or crash).
    func kickTailoring() {
        let queue = tailorQueue, ai = ai
        Task {
            await queue.configure(ai: ai) { msg in Task { @MainActor in self.tailoringMessage = msg; self.refresh() } }
            let made = await queue.kick()
            refresh()
            if made > 0 {
                Notifier.post(title: "Ready for your review", body: made == 1 ? "A tailored resume is ready for your review." : "\(made) tailored resumes are ready for your review.",
                              settings: settings, category: "REVIEW")
            }
        }
    }

    func refresh() {
        let all = (try? store.jobs()) ?? []
        jobs = all.filter { !$0.status.isHidden }
        hiddenCount = all.count - jobs.count
        search = (try? store.search()) ?? SearchConfig()
        versions = (try? store.resumeVersions()) ?? []
    }

    // MARK: derived lists

    func jobs(_ statuses: JobStatus...) -> [Job] { jobs.filter { statuses.contains($0.status) } }
    var matches: [Job] { jobs(.found).sorted { $0.score > $1.score } }
    var strongMatches: [Job] { matches.filter { ($0.llmScore ?? -1) >= search.minScore } }
    var weakerMatches: [Job] { matches.filter { ($0.llmScore ?? -1) < search.minScore } }

    var todoCount: Int {
        jobs(.prefilled, .needsYou, .account, .review).count + strongMatches.count
    }

    // MARK: Find Jobs

    func findJobs() {
        guard !isFinding else { return }
        guard let ai else { toast = Toast(message: "Connect an AI first (Settings → Run Setup Again)."); return }
        isFinding = true; findProgress = FindProgress("Starting…", 0)
        let store = store
        findTask = Task {
            do {
                let summary = try await FindJobs(store: store, ai: ai, tracking: tracking()).run { p in Task { @MainActor in self.findProgress = p } }
                lastSummary = summary
                refresh()
                let good = summary.ranking.good
                let text = good > 0 ? "\(good) new role\(good == 1 ? "" : "s") match you. Open Offerlane to approve the ones to apply for."
                                    : "Search finished. No strong new matches this time."
                toast = Toast(message: "Checked \(summary.discovery.checked) career sites: \(summary.discovery.new) new, \(good) strong matches.")
                Notifier.post(title: "Offerlane", body: text, settings: settings)
                if !summary.errors.isEmpty { toast = Toast(message: summary.errors.joined(separator: " ")) }
            } catch is CancellationError {
                toast = Toast(message: "Find Jobs stopped.")
                refresh()
            } catch {
                toast = Toast(message: "Find Jobs failed: \(error.localizedDescription)")
            }
            isFinding = false; findProgress = nil
        }
    }

    func cancelFind() { findTask?.cancel() }

    // MARK: email

    /// The inbox reader, when email tracking is on and the app password is in Keychain.
    func tracking() -> Tracking? {
        let e = settings.email
        guard e.enabled, !e.user.isEmpty, let pw = keychain.get(account: Keychain.Account.imap(e.user)) else { return nil }
        let host = e.host, port = UInt16(e.port), user = e.user
        return Tracking(store: store, ai: ai) { try await Tracking.imapFetch(host: host, port: port, user: user, password: pw) }
    }
    var checkingInbox = false
    func checkInbox() {
        guard let t = tracking() else { toast = Toast(message: "Turn on email tracking in Settings → Email first."); return }
        checkingInbox = true
        Task {
            do { let r = try await t.run(); toast = Toast(message: "Checked \(r.checked) emails: \(r.updates) status update\(r.updates == 1 ? "" : "s").") }
            catch { toast = Toast(message: "Couldn't check your inbox: \(error.localizedDescription)") }
            checkingInbox = false; refresh()
        }
    }
    /// Polls the inbox for a career-site verification link (Workday sign-up), up to 90 seconds.
    func verificationLink(_ hint: String) async -> String? {
        let e = settings.email
        guard e.enabled, let pw = keychain.get(account: Keychain.Account.imap(e.user)) else { return nil }
        for _ in 0..<9 {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if let mails = try? await Tracking.imapFetch(host: e.host, port: UInt16(e.port), user: e.user, password: pw, days: 1, bodyBytes: 20000),
               let v = Tracking.verification(in: mails, hint: hint) ?? Tracking.verification(in: mails, hint: "workday"), let link = v.link { return link }
        }
        return nil
    }

    // MARK: applications board

    var allTracked: [Job] { ((try? store.jobs(JobStatus.tracked)) ?? []).sorted { $0.updated > $1.updated } }
    var removed: [Job] { ((try? store.jobs([.rejected, .withdrawn])) ?? []).sorted { $0.updated > $1.updated } }
    func move(_ id: String, to s: JobStatus) {
        do { try store.transition(id, to: s, by: "you", detail: "moved on the board"); refresh() }
        catch { toast = Toast(message: error.localizedDescription) }
    }
    func saveNotes(_ id: String, _ notes: String) { _ = try? store.update(id) { $0.notes = notes } }

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
