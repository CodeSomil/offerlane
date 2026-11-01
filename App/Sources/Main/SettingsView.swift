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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ai
                profileAndSearch
                GroupBox("Email tracking") {
                    VStack(alignment: .leading, spacing: 10) {
                        EmailStepView(model: app.onboarding, showsHeader: false)
                        HStack { Spacer(); Button("Save Email Settings") { app.onboarding.saveEmail(); message = "Email settings saved." } }
                    }.padding(8)
                }
                GroupBox("Notifications") {
                    VStack(alignment: .leading, spacing: 10) {
                        NotificationsStepView(model: app.onboarding, showsHeader: false)
                        HStack { Spacer(); Button("Save Notification Settings") { app.settings.notify = app.onboarding.notify; message = "Notification settings saved." } }
                    }.padding(8)
                }
                accounts
                data
                if let message { StatusLine(kind: .ok, text: message) }
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev").foregroundStyle(.secondary)
            }
            .padding(24).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Settings")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r {
                let access = url.startAccessingSecurityScopedResource()
                app.onboarding.importLegacy(from: url)
                if access { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { url.stopAccessingSecurityScopedResource() } }
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
            Button("Forget", role: .destructive) { if let a = forget { try? Vault(store: app.store, keychain: app.keychain).forget(host: a.host) }; forget = nil }
        } message: { Text("Offerlane deletes the saved password. The account itself stays on the career site.") }
    }

    private var ai: some View {
        GroupBox("AI") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    StatusLine(kind: app.aiConnected ? .ok : .error, text: app.ai?.client.displayName ?? "Not connected")
                    Spacer()
                    Button("Change AI…") { reopen(.ai) }
                }
                let usage = (try? app.store.usage(days: 30)) ?? []
                if usage.isEmpty { Text("No AI calls yet.").foregroundStyle(.secondary) }
                else {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                        GridRow { Text("Day"); Text("Calls"); Text("Tokens in / out"); Text("Cached"); Text("Est. cost") }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8)
        }
    }

    private var profileAndSearch: some View {
        GroupBox("You and your search") {
            HStack(spacing: 10) {
                Button("Edit Resumes…") { reopen(.resumes) }
                Button("Edit About You…") { reopen(.about) }
                Button("Edit Search…") { reopen(.search) }
                Spacer()
                Text("\(app.search.companies.count) companies · score \(app.search.minScore)+").foregroundStyle(.secondary)
            }.padding(8)
        }
    }

    private var accounts: some View {
        GroupBox("Career-site accounts") {
            let list = (try? app.store.accounts()) ?? []
            VStack(alignment: .leading, spacing: 8) {
                if list.isEmpty { Text("None yet. Offerlane asks before creating an account on any career site.").foregroundStyle(.secondary) }
                ForEach(list) { a in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.company.isEmpty ? a.host : a.company).font(.headline)
                            Text("\(a.host) · \(a.email)" + (a.created.map { " · created \($0.prefix(10))" } ?? (a.approved ? " · approved" : ""))).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show Password") { Task { await reveal(a) } }.disabled(a.created == nil)
                        Button("Forget", role: .destructive) { forget = a }
                    }
                }
            }.padding(8)
        }
    }

    private var data: some View {
        GroupBox("Your data") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Everything stays on this Mac in \(Paths.root.path). Only resume text and job descriptions go to your AI provider, and only form answers go to career sites.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Import Previous Version…") { importing = true }
                    Button("Export Everything…") { export() }
                    Button("Show Logs") { NSWorkspace.shared.open(Paths.logs) }
                    Spacer()
                    Button("Delete All My Data…", role: .destructive) { confirmDelete = true }
                }
                if let r = app.onboarding.importReport { StatusLine(kind: .ok, text: r) }
                if let e = app.onboarding.importError { StatusLine(kind: .error, text: e) }
            }.padding(8)
        }
    }

    private func reopen(_ step: OnboardingStep) { app.onboarding.step = step; app.settings.onboarded = false }

    private func reveal(_ a: SiteAccount) async {
        let ctx = LAContext(); var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { message = "Your Mac can't confirm it's you (\(err?.localizedDescription ?? ""))."; return }
        do {
            guard try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show the saved password for \(a.company)") else { return }
            shownPassword = (a.company.isEmpty ? a.host : a.company, Vault(store: app.store, keychain: app.keychain).password(host: a.host) ?? "(not found in Keychain)")
        } catch { message = "Not shown: \(error.localizedDescription)" }
    }

    private func export() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Export Here"
        panel.message = "Choose where to save a copy of everything (passwords are not included)."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do { let out = try DataTools.export(store: app.store, to: dir); NSWorkspace.shared.activateFileViewerSelecting([out]); message = "Exported to \(out.path)." }
        catch { message = "Export failed: \(error.localizedDescription)" }
    }

    private func deleteAll() async {
        do {
            try DataTools.deleteAll(store: app.store, keychain: app.keychain)
            try? await WKWebsiteDataStore.remove(forIdentifier: UUID(uuidString: "6A0B3C1E-5D2F-4E8A-9B7C-1F2E3D4C5B6A")!)
            app.settings = AppSettings(); app.rebuildAI(); app.refresh()
            app.onboarding = OnboardingModel(app: app)
        } catch { message = "Couldn't delete everything: \(error.localizedDescription)" }
    }
}
