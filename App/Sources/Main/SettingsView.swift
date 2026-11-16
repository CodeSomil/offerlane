import SwiftUI
import LocalAuthentication
import WebKit
import OfferlaneCore

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var importing = false
    @State private var confirmDelete = false
    @State private var shownPassword: (String, String)?
    @State private var forget: SiteAccount?
    @State private var message: String?
    /// The email settings as last saved, to tell when there are unsaved edits.
    @State private var savedEmail: (AppSettings.Email, String)?
    @State private var crashReports = AppModel.crashReportsSince != nil
    @State private var backupSheet: BackupSheet.Mode?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                ScreenHeader(title: "Settings") { EmptyView() }.padding(.horizontal, -DS.Space.xl)
                if app.account != nil { accountSection }
                ai
                ClaudeSection()
                profileAndSearch
                SectionCard(title: "Email tracking", subtitle: "Reads replies from employers and updates each application.", symbol: "envelope") {
                    VStack(alignment: .leading, spacing: 10) {
                        EmailStepView(model: app.onboarding, showsHeader: false)
                        HStack {
                            if emailDirty { Text("Unsaved changes").font(DS.Font.caption).foregroundStyle(DS.Palette.warning) }
                            Spacer()
                            Button("Save Email Settings") { saveEmail() }.buttonStyle(.dsPrimary).disabled(!emailDirty && savedEmail != nil)
                        }
                    }
                }
                SectionCard(title: "Notifications", subtitle: "Changes save automatically.", symbol: "bell") {
                    NotificationsStepView(model: app.onboarding, showsHeader: false)
                }
                accounts
                data
                if let message { StatusLine(kind: .ok, text: message) }
                HStack {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev").foregroundStyle(DS.Palette.textSecondary)
                    Spacer()
                    Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                        .disabled(Updater.shared.unavailableReason != nil)
                        .help(Updater.shared.unavailableReason ?? "Checks once for a newer version of Offerlane.")
                        .accessibilityIdentifier("settings.checkUpdates")
                }
                if let why = Updater.shared.unavailableReason { Text(why).font(.caption).foregroundStyle(DS.Palette.textSecondary) }
            }
            .padding(.horizontal, DS.Space.xl).padding(.bottom, DS.Space.xl).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onAppear { savedEmail = (app.settings.email, app.onboarding.emailPassword) }
        .onChange(of: app.onboarding.notify) { _, n in app.settings.notify = n }
        .onChange(of: emailDirty, initial: true) { _, dirty in
            app.unsaved = dirty ? UnsavedWork(message: "Your email tracking changes haven't been saved.", save: { saveEmail() },
                                              discard: { [app, savedEmail] in
                                                  if let s = savedEmail { app.onboarding.email = s.0; app.onboarding.emailPassword = s.1 }
                                              }) : nil
        }
        .onDisappear { app.unsaved = nil }
        .sheet(item: $backupSheet) { BackupSheet(mode: $0, app: app) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r {
                let access = url.startAccessingSecurityScopedResource()
                // Keep access to the chosen folder until the import ends, however long it takes.
                app.onboarding.importLegacy(from: url) { if access { url.stopAccessingSecurityScopedResource() } }
                message = "Importing from \(url.lastPathComponent)…"
            }
        }
        .alert("Delete all your data?", isPresented: $confirmDelete) {
            Button("Delete Everything", role: .destructive) { Task { await deleteAll() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes your resumes, roles, applications, saved career-site passwords and settings from this Mac. It can't be undone. Export first if you want a copy.") }
        .alert(shownPassword.map { "Password for \($0.0)" } ?? "", isPresented: Binding(get: { shownPassword != nil }, set: { if !$0 { shownPassword = nil } })) {
            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(shownPassword?.1 ?? "", forType: .string) }
            Button("Done", role: .cancel) {}
        } message: { Text(shownPassword?.1 ?? "") }
        .confirmationDialog("Forget this account?", isPresented: Binding(get: { forget != nil }, set: { if !$0 { forget = nil } })) {
            Button("Forget", role: .destructive) { if let a = forget { try? Vault(store: app.store, keychain: app.keychain).forget(host: a.host); app.refresh() }; forget = nil }
        } message: { Text("Offerlane deletes the saved password. The account itself stays on the career site.") }
    }

    @State private var confirmSignOut = false
    private var accountSection: some View {
        SectionCard(title: "Your profile", subtitle: "Stored only on this Mac. You stay signed in until you sign out.", symbol: "person.crop.circle.badge.checkmark") {
            if let a = app.account {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name.isEmpty ? a.email : a.name).font(DS.Font.headline)
                            Text(a.kind == .google ? "\(a.email) · signed in with Google" : "\(a.email) · email and password")
                                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                        }
                        Spacer()
                        Button("Sign Out…") { confirmSignOut = true }.buttonStyle(.dsSecondary).accessibilityIdentifier("settings.signOut")
                    }
                    if TouchID.available {
                        Toggle("Unlock with Touch ID when Offerlane opens", isOn: Binding(get: { app.account?.touchID ?? false }, set: { app.setTouchID($0) }))
                            .help("Stops other people using this Mac account from opening your profile in Offerlane. Files on disk aren't encrypted; use FileVault for that.")
                            .toggleStyle(.switch)
                    }
                }
                .confirmationDialog("Sign out of Offerlane?", isPresented: $confirmSignOut) {
                    Button("Sign Out") { app.signOut() }.accessibilityIdentifier("settings.confirmSignOut")
                } message: { Text("Your data stays on this Mac and comes back when you sign in again. Gmail, if connected, will need connecting again.") }
            }
        }
    }

    private var emailDirty: Bool {
        guard let s = savedEmail else { return false }
        // Gmail connects and saves itself; only IMAP fields count as unsaved edits.
        var saved = s.0, current = app.onboarding.email
        saved.gmail = false; current.gmail = false
        return saved != current || s.1 != app.onboarding.emailPassword
    }
    private func saveEmail() {
        app.onboarding.saveEmail(); savedEmail = (app.onboarding.email, app.onboarding.emailPassword)
        message = "Email settings saved."
    }

    private var ai: some View {
        SectionCard(title: "AI", symbol: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    StatusLine(kind: app.aiConnected ? .ok : .error, text: app.ai?.client.displayName ?? "Not connected")
                    Spacer()
                    Button("Setup Center…") { app.showSetupCenter = true }.buttonStyle(.dsSecondary)
                        .accessibilityIdentifier("settings.setupCenter")
                    Button("Change AI…") { reopen(.ai) }.buttonStyle(.dsSecondary)
                }
                limits
                let usage = app.data.usage
                if usage.isEmpty { Text("No AI calls yet.").foregroundStyle(DS.Palette.textSecondary) }
                else {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                        GridRow { Text("Day"); Text("Calls"); Text("Tokens in / out"); Text("Cached"); Text("Est. cost") }.font(.caption.weight(.semibold)).foregroundStyle(DS.Palette.textSecondary)
                        ForEach(usage.prefix(14), id: \.day) { u in
                            GridRow {
                                Text(u.day); Text("\(u.calls)").monospacedDigit()
                                Text("\(u.inputTokens.formatted()) / \(u.outputTokens.formatted())").monospacedDigit()
                                Text(u.cachedTokens.formatted()).monospacedDigit()
                                Text(u.usd > 0 ? u.usd.formatted(.currency(code: "USD")) : "–").monospacedDigit()
                            }.font(.callout)
                        }
                    }
                    Text(app.ai?.client.billed == true ? "Estimated from the API's published per-token prices." :
                            "Your plan or local model isn't billed per token; Claude subscription calls count toward your plan's usage limits.")
                        .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                }
            }
        }
    }

    private var profileAndSearch: some View {
        SectionCard(title: "You and your search", subtitle: "\(app.search.companies.count) companies · score \(app.search.minScore)+", symbol: "person.crop.circle") {
            HStack(spacing: 10) {
                Button("Edit About You…") { reopen(.about) }.buttonStyle(.dsSecondary)
                Button("Edit Search…") { reopen(.search) }.buttonStyle(.dsSecondary)
                Spacer()
            }
        }
    }

    private var accounts: some View {
        SectionCard(title: "Career-site accounts", symbol: "key") {
            let list = app.data.accounts
            VStack(alignment: .leading, spacing: 8) {
                if list.isEmpty { Text("None yet. Offerlane asks before creating an account on any career site.").foregroundStyle(DS.Palette.textSecondary) }
                ForEach(list) { a in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.company.isEmpty ? a.host : a.company).font(.headline)
                            Text("\(a.host) · \(a.email)" + (a.created.map { " · created \($0.prefix(10))" } ?? (a.approved ? " · approved" : ""))).font(.caption).foregroundStyle(DS.Palette.textSecondary)
                        }
                        Spacer()
                        Button("Show Password") { Task { await reveal(a) } }.disabled(a.created == nil)
                        Button("Forget", role: .destructive) { forget = a }
                    }
                }
            }
        }
    }

    private var data: some View {
        SectionCard(title: "Your data", symbol: "externaldrive") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Everything stays on this Mac. Only resume text and job descriptions go to your AI provider, and only form answers go to career sites.")
                Button("Show My Data in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.root]) }.buttonStyle(.dsSecondary)
                    .font(.callout).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Import Previous Version…") { importing = true }
                    Button("Back Up…") { if let f = BackupSheet.chooseBackupFile() { backupSheet = .backup(f) } }
                        .accessibilityIdentifier("settings.backup")
                    Button("Restore from Backup…") { if let f = BackupSheet.chooseRestoreFile() { backupSheet = .restore(f) } }
                        .accessibilityIdentifier("settings.restore")
                    Button("Export Everything…") { export() }
                    Button("Show Logs") { NSWorkspace.shared.open(Paths.logs) }
                    Spacer()
                    Button("Delete All My Data…", role: .destructive) { confirmDelete = true }
                }
                Toggle("Save crash reports", isOn: Binding(get: { crashReports }, set: { on in
                    AppModel.crashReportsSince = on ? Date() : nil; crashReports = on
                })).accessibilityIdentifier("settings.crashReports")
                Text("Off by default. When Offerlane quits unexpectedly, it saves a short technical report on this Mac: app and macOS version and where in the code it stopped. Never your resume, jobs, emails, names or keys. Nothing is sent anywhere; you can read every report and share one yourself.")
                    .font(.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                if crashReports {
                    Button("Show Crash Reports") {
                        try? FileManager.default.createDirectory(at: CrashReports.outbox, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(CrashReports.outbox)
                    }
                }
                if let r = app.onboarding.importReport { StatusLine(kind: .ok, text: r) }
                if let e = app.onboarding.importError { StatusLine(kind: .error, text: e) }
            }
        }
    }

    /// Hard stops for AI use: a run (Find Jobs) and one tailored resume.
    private var limits: some View {
        @Bindable var app = app
        let options = [10_000, 25_000, 50_000, 100_000, 250_000, 0]
        let name = { (n: Int) in n == 0 ? "No limit" : "\(UsageMeter.short(n)) tokens" }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DS.Space.l) {
                Picker("Limit per Find Jobs run", selection: $app.settings.runTokenLimit) { ForEach(options, id: \.self) { Text(name($0)).tag($0) } }
                    .fixedSize().accessibilityIdentifier("settings.runLimit")
                Picker("Limit per tailored resume", selection: $app.settings.tailorTokenLimit) { ForEach(options, id: \.self) { Text(name($0)).tag($0) } }
                    .fixedSize().accessibilityIdentifier("settings.tailorLimit")
            }
            Text("A run of 25 postings usually needs 5k–10k tokens; one tailored resume 3k–8k. If a limit is reached, Offerlane stops and keeps what's done. Answers it already gave are reused, so repeats cost nothing.")
                .font(.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reopen(_ step: OnboardingStep) {
        app.onboarding.editingFromSettings = step.isOptional
        app.onboarding.step = step; app.settings.onboarded = false
    }

    private func reveal(_ a: SiteAccount) async {
        let ctx = LAContext(); var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { app.toast = Toast(message: "This Mac can't confirm it's you, so the password stays hidden. Set up a Mac login password or Touch ID in System Settings, then try again."); _ = err; return }
        do {
            guard try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show the saved password for \(a.company)") else { return }
            shownPassword = (a.company.isEmpty ? a.host : a.company, Vault(store: app.store, keychain: app.keychain).password(host: a.host) ?? "(not found in Keychain)")
        } catch { app.toast = .error("The password wasn't shown because Touch ID or your Mac password wasn't confirmed.", "Try again") { Task { await reveal(a) } } }
    }

    private func export() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Export Here"
        panel.message = "Choose where to save a copy of everything (passwords are not included)."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do { let out = try DataTools.export(store: app.store, to: dir); NSWorkspace.shared.activateFileViewerSelecting([out]); message = "Exported \(out.lastPathComponent). It's selected in the Finder." }
        catch { Log.error("export: \(error)"); app.toast = .error("The export couldn't be saved there. Choose another folder, such as Desktop.", "Try again") { export() } }
    }

    private func deleteAll() async {
        if let problem = await app.deleteEverything() { app.toast = .error(problem, "Try again") { Task { await deleteAll() } } }
        else { app.toast = Toast(message: "Everything was deleted from this Mac.") }
    }
}
