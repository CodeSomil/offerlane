import SwiftUI
import UniformTypeIdentifiers
import OfferlaneCore

/// Help → Send Diagnostics…: builds a redacted report, shows all of it, and lets the user copy or save it.
/// Nothing is sent anywhere by Offerlane.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var report: String?
    @State private var copied = false
    @State private var saveError: String?

    var body: some View {
        DSSheet(title: "Diagnostics Report", primary: "Save…", primaryDisabled: report == nil, onCancel: { dismiss() }, onPrimary: save) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("This report helps someone work out what's wrong. Names, emails, phone numbers, web addresses, passwords and keys have been removed, and your resumes, jobs and answers aren't included. Read it below, then save or copy it to share it yourself. Offerlane doesn't send it anywhere.")
                    .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                if let report {
                    ScrollView {
                        Text(report).font(.callout.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(DS.Space.s)
                            .accessibilityIdentifier("diagnostics.report")
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.s))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.s).strokeBorder(Color.secondary.opacity(0.3)))
                    HStack {
                        Button(copied ? "Copied" : "Copy to Clipboard") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report, forType: .string); copied = true
                        }
                        .buttonStyle(.dsSecondary).accessibilityIdentifier("diagnostics.copy")
                        if let saveError { ErrorRow(text: saveError, action: "Try Again", perform: save) }
                    }
                    if let reply = app.ai?.lastReply {
                        DisclosureGroup("Last AI reply, from \(reply.from)") {
                            Text("Shown exactly as the AI sent it. It stays on this Mac and isn't part of the report.")
                                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                            ScrollView {
                                Text(reply.text.isEmpty ? "(empty reply)" : reply.text).font(.callout.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(DS.Space.s)
                            }
                            .frame(maxHeight: 180)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.s))
                        }
                        .accessibilityIdentifier("diagnostics.lastReply")
                    }
                } else {
                    StatusLine(kind: .working, text: "Putting the report together…")
                    SkeletonList(rows: 6, label: "Building report")
                }
            }
            .padding(DS.Space.xl)
        }
        .frame(minWidth: 680, minHeight: 520)
        .task { report = await app.diagnosticsReport() }
    }

    private func save() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Offerlane diagnostics \(Dates.now().prefix(10)).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.write(to: url, atomically: true, encoding: .utf8); saveError = nil; dismiss(); app.toast = Toast(message: "Diagnostics report saved.") }
        catch { saveError = "The report couldn't be saved there. Pick another folder, such as Desktop." }
    }
}

extension AppModel {
    func diagnosticsReport() async -> String {
        await checkHealth()
        var i = Diagnostics.Info()
        i.provider = settings.provider == .none ? "" : settings.provider == .apiKey ? settings.providerID : settings.provider.rawValue
        i.model = settings.provider == .ollama || settings.provider == .apiKey ? settings.modelSmart : ""
        i.signIn = account.map { $0.kind.rawValue } ?? "none"
        i.emailTracking = !settings.email.enabled ? "off" : settings.email.gmail ? "gmail" : "imap"
        i.counts = ["roles": data.jobs.count, "applications": data.tracked.count + data.removed.count, "resumes": data.versions.count]
        i.health = health
        let info = i, known = personalStrings
        return await Task.detached { Diagnostics.report(info, log: Diagnostics.logTail(), known: known) }.value
    }

    /// Strings that must never appear in a diagnostics or crash report.
    var personalStrings: [String] {
        let p = (try? store.profile()) ?? Profile()
        return [p.personal.fullName, p.personal.firstName, p.personal.lastName, p.personal.email, p.personal.phone,
                account?.email ?? "", account?.name ?? "", settings.email.user, NSFullUserName(), NSUserName()]
            // Which employers someone is applying to is personal too.
            + Array(Set((data.jobs + data.tracked + data.removed).map(\.company) + data.search.companies.map(\.name)))
    }

    /// When the user opted in to crash reports (app-wide, not per profile); nil = off, the default.
    static var crashReportsSince: Date? {
        get { UserDefaults.standard.object(forKey: "crashReportsSince") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "crashReportsSince") }
    }

    /// Turns crashes since opting in into reports in the local outbox (nothing is uploaded).
    func collectCrashReports() {
        guard let since = Self.crashReportsSince else { return }
        let known = personalStrings
        Task.detached(priority: .utility) {
            if !CrashReports.collect(since: since, known: known).isEmpty {
                await MainActor.run { self.toast = Toast(message: "Offerlane quit unexpectedly last time. A crash report without personal details was saved; you can read it in Settings → Your data → Show Crash Reports.") }
            }
        }
    }
}
