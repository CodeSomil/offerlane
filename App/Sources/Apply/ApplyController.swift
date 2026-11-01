import SwiftUI
import AppKit
import OfferlaneCore

/// Runs the Apply window: one application at a time, pausing for the user at every gate.
@MainActor @Observable
final class ApplyController {
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let page = WebPage()
    var currentID: String?
    var running = false
    var lastOutcome: ApplyEngine.Outcome?
    @ObservationIgnored var openWindow: (() -> Void)?
    @ObservationIgnored private var engineTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var lastApplyAt: [String: Date] = [:]
    @ObservationIgnored private var bodyHadConfirmation = false

    init(app: AppModel) { self.app = app }

    var job: Job? { currentID.flatMap { try? app?.store.job($0) } }

    /// Pick up the next approved role if nothing is in the window.
    func next() {
        guard let app, currentID == nil || job.map({ $0.status.isTracked || $0.status.isHidden }) == true else { return }
        currentID = nil
        guard let j = app.jobs(.ready).sorted(by: { $0.updated < $1.updated }).first else { return }
        start(j.id)
    }

    func start(_ id: String) {
        guard let app, let j = try? app.store.job(id) else { return }
        currentID = id; openWindow?()
        guard let url = URL(string: AnswerRules.formURL(j)) else { finish(.needsYou("This role has no application link. Open the posting yourself.")); return }
        engineTask?.cancel()
        engineTask = Task {
            // Per-site cool-down: never two applications on the same site back to back.
            if let host = url.host, let t = lastApplyAt[host], Date().timeIntervalSince(t) < 60 {
                try? await Task.sleep(nanoseconds: UInt64((60 - Date().timeIntervalSince(t)) * 1e9))
            }
            _ = try? app.store.transition(id, to: .applying, by: "browser", detail: "opened the application") { $0.autofill = "Working…" }
            app.refresh(); running = true
            await page.load(url)
            bodyHadConfirmation = false
            await runEngine(first: true)
        }
        startWatcher()
    }

    private func engine(for j: Job) -> ApplyEngine? {
        guard let app else { return nil }
        let dir = Tailor.dir(j)
        let answers = AnswerRules.parseAnswers((try? String(contentsOf: dir.appendingPathComponent("answers.md"), encoding: .utf8)) ?? "")
        let pdfURL = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).first { $0.pathExtension == "pdf" }
        let pdf = pdfURL.flatMap { u in (try? Data(contentsOf: u)).map { ($0, u.lastPathComponent) } }
        let fast = ProcessInfo.processInfo.environment["OFFERLANE_FAST_PACE"] == "1"
        return ApplyEngine(page: page, job: j, profile: (try? app.store.profile()) ?? Profile(), answers: answers, pdf: pdf,
                           vault: Vault(store: app.store, keychain: app.keychain), pace: fast ? 0.1 : 1,
                           verificationLink: { [weak app] hint in await app?.verificationLink(hint) })
    }

    private func runEngine(first: Bool) async {
        guard let j = job, let engine = engine(for: j) else { return }
        running = true
        let out = await engine.run(first: first)
        running = false
        if let host = page.url?.host { lastApplyAt[host] = Date() }
        finish(out)
    }

    private func finish(_ out: ApplyEngine.Outcome) {
        guard let app, let id = currentID, let j = job else { return }
        lastOutcome = out
        let who = "\(j.company) – \(j.title)"
        if j.status != out.status {
            _ = try? app.store.transition(id, to: out.status, by: "browser", detail: String(out.message.prefix(150))) { $0.autofill = out.message; $0.site = self.page.host }
        } else { _ = try? app.store.update(id) { $0.autofill = out.message } }
        app.refresh()
        switch out {
        case .prefilled: Notifier.post(title: "Ready for you to submit", body: "\(who): the form is filled. Check it and click Submit.", settings: app.settings, category: "OPEN_FORM")
        case .account(let m): Notifier.post(title: "Approval needed", body: m, settings: app.settings, category: "OPEN_FORM")
        case .needsYou(let m): Notifier.post(title: "Offerlane needs you", body: "\(who): \(m)", settings: app.settings, category: "OPEN_FORM")
        case .applied: app.toast = Toast(message: "Applied to \(j.company). It's now tracked under Applications."); currentID = nil; next()
        }
    }

    // MARK: user actions

    func continueApplying() {
        guard let app, let id = currentID, let j = job, [.account, .needsYou, .prefilled, .applying].contains(j.status) else { return }
        if j.status != .applying { _ = try? app.store.transition(id, to: .applying, by: "you", detail: "continue") }
        app.refresh()
        engineTask?.cancel(); engineTask = Task { await runEngine(first: false) }
    }
    func approveAccount() {
        guard let app, let j = job else { return }
        try? Vault(store: app.store, keychain: app.keychain).approve(host: page.host, company: j.company, email: (try? app.store.profile())?.personal.email ?? "")
        continueApplying()
    }
    func doItMyself() {
        guard let app, let id = currentID else { return }
        _ = try? app.store.transition(id, to: .needsYou, by: "you", detail: "creating the account myself") { $0.autofill = "Create the account (or sign in) here, then press Continue." }
        app.refresh()
    }
    func dontApply() {
        guard let app, let id = currentID else { return }
        engineTask?.cancel(); _ = try? app.store.transition(id, to: .declined, by: "you", detail: "don't apply"); app.refresh(); currentID = nil; next()
    }
    func pause() {
        engineTask?.cancel(); running = false
        guard let app, let id = currentID else { return }
        _ = try? app.store.transition(id, to: .needsYou, by: "you", detail: "paused") { $0.autofill = "Paused. Press Continue to carry on." }
        app.refresh()
    }
    func markSubmitted() {
        guard let app, let id = currentID else { return }
        _ = try? app.store.transition(id, to: .applied, by: "you", detail: "I submitted it"); app.refresh()
        app.toast = Toast(message: "Marked as applied."); currentID = nil; next()
    }
    func openInSafari() { if let u = page.url { NSWorkspace.shared.open(u) } }

    /// Open a role that is waiting on the user (from To Do) without re-running the agent.
    func show(_ id: String) {
        if currentID == id { openWindow?(); return }
        guard let j = try? app?.store.job(id), let url = URL(string: AnswerRules.formURL(j)) else { return }
        engineTask?.cancel(); currentID = id; openWindow?()
        Task { await page.load(url) }
        startWatcher()
    }

    // MARK: confirmation detection

    static func isConfirmation(body: String, url: String) -> Bool {
        Re.search(AnswerRules.doneRx, String(body.prefix(20000))) || Re.search("/(thanks|thank-you|confirmation|submitted)", url)
    }

    private func startWatcher() {
        watcher?.cancel()
        watcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let j = job, [.prefilled, .needsYou].contains(j.status), !running else { continue }
                let body = await page.string("text"), url = page.url?.absoluteString ?? ""
                if Self.isConfirmation(body: body, url: url) && !bodyHadConfirmation {
                    bodyHadConfirmation = true
                    _ = try? app?.store.transition(j.id, to: .applied, by: "browser", detail: "confirmation page detected") { $0.autofill = "" }
                    app?.refresh(); app?.toast = Toast(message: "Submitted! \(j.company) is now tracked.")
                    currentID = nil; next()
                }
            }
        }
    }
}

struct ApplyWindowView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let c = app.apply!
        VStack(spacing: 0) {
            ApplyBanner(controller: c)
            Divider()
            WebHost(web: c.page.web)
                .accessibilityLabel("Application form")
        }
        .frame(minWidth: 900, minHeight: 640)
    }
}

private struct ApplyBanner: View {
    @Environment(AppModel.self) private var app
    let controller: ApplyController
    var body: some View {
        let j = controller.job
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon(j?.status)).font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(j.map { "\($0.company) – \($0.title)" } ?? "No application open").font(.headline)
                Text(text(j)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if controller.running { ProgressView().controlSize(.small); Button("Pause") { controller.pause() } }
            else if j?.status == .account {
                Button("Don't Apply", role: .destructive) { controller.dontApply() }
                Button("I'll Do It Myself") { controller.doItMyself() }
                Button("Approve") { controller.approveAccount() }.buttonStyle(.borderedProminent).accessibilityIdentifier("apply.approveAccount")
            } else if let s = j?.status, [.needsYou, .prefilled].contains(s) {
                Button("Continue") { controller.continueApplying() }.accessibilityIdentifier("apply.continue")
                if s == .prefilled { Button("I Submitted It") { controller.markSubmitted() }.buttonStyle(.borderedProminent) }
                else { Button("I Submitted It") { controller.markSubmitted() } }
            }
            Button { controller.openInSafari() } label: { Image(systemName: "safari") }.help("Open in Safari").disabled(controller.page.url == nil)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }
    private func icon(_ s: JobStatus?) -> String {
        switch s { case .prefilled: "paperplane.fill"; case .account: "person.badge.key"; case .needsYou: "hand.raised.fill"; default: "wand.and.stars" }
    }
    private func text(_ j: Job?) -> String {
        guard let j else { return "Approve a tailored resume and Offerlane opens the application here." }
        switch j.status {
        case .applying: return "Offerlane is filling the form at a human pace. You can watch, or press Pause."
        case .prefilled: return j.autofill.isEmpty ? "Everything is filled. Review it, then click the site's Submit button yourself." : j.autofill
        default: return j.autofill
        }
    }
}

private struct WebHost: NSViewRepresentable {
    let web: NSView
    func makeNSView(context: Context) -> NSView { let v = NSView(); embed(web, in: v); return v }
    func updateNSView(_ v: NSView, context: Context) { if web.superview !== v { embed(web, in: v) } }
    private func embed(_ web: NSView, in v: NSView) {
        web.removeFromSuperview(); web.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(web)
        NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo: v.leadingAnchor), web.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                                     web.topAnchor.constraint(equalTo: v.topAnchor), web.bottomAnchor.constraint(equalTo: v.bottomAnchor)])
    }
}
