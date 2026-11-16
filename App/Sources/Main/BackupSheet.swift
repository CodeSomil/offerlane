import AppKit
import OfferlaneCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Your data → Back Up… / Restore from Backup…: asks for the passphrase, then does the slow part off the main thread.
struct BackupSheet: View {
    enum Mode: Identifiable { case backup(URL), restore(URL); var id: String { "\(self)" } }
    let mode: Mode
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pass = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?
    @State private var staged: Backup.Summary?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch mode {
            case .backup(let file):
                Text("Back up to “\(file.lastPathComponent)”").font(.headline)
                Text("The backup holds your resumes, roles, applications and settings, encrypted with this passphrase. Passwords stay in your Keychain and aren't included. Without the passphrase nobody, including you, can open the backup, so write it down.")
                    .font(.callout).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                SecureField("Passphrase (at least \(Backup.minPassphrase) characters)", text: $pass).accessibilityIdentifier("backup.pass")
                SecureField("Type it again", text: $confirm).accessibilityIdentifier("backup.confirm")
            case .restore(let file):
                Text("Restore “\(file.lastPathComponent)”").font(.headline)
                if let s = staged {
                    Text("This backup\(s.created.isEmpty ? "" : " from \(s.created)") has \(s.roles) roles and \(s.resumes) resumes. Restoring replaces the data in this profile when Offerlane restarts. Your current data isn't deleted: it's kept in a “Before restore” folder in your data folder.")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    SecureField("Backup passphrase", text: $pass).accessibilityIdentifier("backup.pass")
                }
            }
            if let error { StatusLine(kind: .error, text: error) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }.keyboardShortcut(.cancelAction)
                Button(primaryTitle) { Task { await primary() } }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
                    .disabled(busy || (staged == nil && pass.isEmpty))
            }
        }
        .padding(DS.Space.xl).frame(width: 460)
    }

    private var primaryTitle: String {
        switch mode { case .backup: "Back Up"; case .restore: staged == nil ? "Check Backup" : "Restore and Restart" }
    }

    private func cancel() {
        // A checked restore only takes effect after confirmRestore; anything still staged is removed now or on the next open.
        if let s = staged { try? FileManager.default.removeItem(at: Paths.root.appendingPathComponent(s.stagedName)) }
        dismiss()
    }

    private func primary() async {
        error = nil
        let store = app.store, root = Paths.root, pass = pass
        switch mode {
        case .backup(let file):
            guard pass == confirm else { error = "The two passphrases don't match."; return }
            busy = true; defer { busy = false }
            do {
                try await Task.detached { try Backup.create(store: store, root: root, to: file, passphrase: pass) }.value
                NSWorkspace.shared.activateFileViewerSelecting([file])
                app.toast = Toast(message: "Backup saved. Keep the passphrase somewhere safe.")
                dismiss()
            } catch { self.error = (error as? BackupError)?.errorDescription ?? error.localizedDescription }
        case .restore(let file):
            if let s = staged {
                do { try Backup.confirmRestore(s, in: root); Self.relaunch() }
                catch { self.error = (error as? BackupError)?.errorDescription ?? error.localizedDescription }
                return
            }
            busy = true; defer { busy = false }
            do { staged = try await Task.detached { try Backup.stageRestore(file, passphrase: pass, into: root) }.value }
            catch { self.error = (error as? BackupError)?.errorDescription ?? error.localizedDescription }
        }
    }

    /// Quits and reopens Offerlane; the staged restore is swapped in when the profile's data opens.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    static func chooseBackupFile() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: Backup.fileExtension) ?? .data]
        panel.nameFieldStringValue = "Offerlane \(Dates.today()).\(Backup.fileExtension)"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseRestoreFile() -> URL? {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: Backup.fileExtension) ?? .data]
        panel.message = "Choose an Offerlane backup (.\(Backup.fileExtension))."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
