import SwiftUI
import UserNotifications
import OfferlaneCore

extension OnboardingModel {
    // MARK: import (previous-version (v2))

    var legacyFolderAvailable: Bool { LegacyImporter.looksValid(LegacyImporter.defaultFolder) }

    func importLegacy(from dir: URL = LegacyImporter.defaultFolder) {
        guard let app else { return }
        importing = true; importError = nil; importReport = nil
        Task {
            do {
                let rep = try await Task.detached { try LegacyImporter(store: app.store).run(from: dir) }.value
                importReport = rep.description
                uploads = ((try? app.store.resumeVersions()) ?? []).map(ResumeUpload.init(existing:))
                profile = (try? app.store.profile()) ?? profile
                search = (try? app.store.search()) ?? search; drafted = !search.companies.isEmpty
                let s = (try? app.store.settings()) ?? app.settings
                email = s.email; notify = s.notify
                app.settings.email = s.email; app.settings.notify = s.notify
            } catch { importError = error.localizedDescription }
            importing = false
        }
    }

    // MARK: about you

    func prefillProfile() {
        guard let r = (try? app?.store.resume())??.content else { return }
        profile.prefill(from: r)
    }

    // MARK: search

    func draftSearch() {
        guard let app, let ai = app.ai, let r = try? app.store.resume() else { draftError = "Add a resume and connect an AI first."; return }
        drafting = true; draftError = nil
        let base = search, versions = (try? app.store.resumeVersions()) ?? [], profile = profile
        longTask = Task {
            do {
                search = try await SearchSetup(ai: ai).draft(base, resume: r.content, versions: versions, profile: profile)
                drafted = true
            } catch is CancellationError {} catch { draftError = error.localizedDescription }
            drafting = false
        }
    }

    /// "Add a company by name or paste a careers URL."
    func addCompany(_ input: String) -> String? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var c: SearchConfig.Company
        if t.contains(".") || t.contains("/") {
            guard let found = Careers.detect(t) else {
                return "That careers page isn't on a site Offerlane can read (Greenhouse, Lever, Ashby, Workable, SmartRecruiters or Workday). Add the company by name instead."
            }
            c = found
        } else { c = .init(name: t); c = Careers.attachWorkday([c])[0] }
        if search.companies.contains(where: { $0.name.lowercased() == c.name.lowercased() }) { return "\(c.name) is already on the list." }
        search.companies.insert(c, at: 0); return nil
    }

    // MARK: email

    func applyPreset(_ key: String) {
        email.preset = key
        if let p = MailPreset.all.first(where: { $0.key == key }), !p.host.isEmpty { email.host = p.host }
        if key == "custom" { email.host = "" }
    }

    func testEmail() {
        emailTesting = true; emailError = nil; emailResult = nil
        let host = email.host, port = UInt16(email.port), user = email.user, pw = emailPassword.replacingOccurrences(of: " ", with: "")
        Task {
            do {
                let n = try await IMAPClient.test(host: host, port: port, user: user, password: pw)
                emailResult = "Connected · \(n.formatted()) messages in your inbox."
            } catch { emailError = error.localizedDescription }
            emailTesting = false
        }
    }

    func saveEmail() {
        guard let app else { return }
        if email.enabled && !email.user.isEmpty && !emailPassword.isEmpty {
            try? app.keychain.set(emailPassword.replacingOccurrences(of: " ", with: ""), account: Keychain.Account.imap(email.user))
        }
        app.settings.email = email
    }

    // MARK: notifications

    func requestNotifications() {
        Task {
            do {
                let ok = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                notificationStatus = ok ? "Notifications are on." : "Notifications are off. You can turn them on in System Settings → Notifications → Offerlane."
            } catch { notificationStatus = "Couldn't ask for permission: \(error.localizedDescription)" }
        }
    }

    func refreshNotificationStatus() {
        Task {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            switch s.authorizationStatus {
            case .authorized, .provisional: notificationStatus = "Notifications are on."
            case .denied: notificationStatus = "Notifications are off. You can turn them on in System Settings → Notifications → Offerlane."
            default: notificationStatus = nil
            }
        }
    }

    func sendNtfyTest() {
        ntfyTestResult = nil
        let topic = notify.ntfyTopic
        Task {
            do { try await Ntfy.send(topic: topic, title: "Offerlane", message: "Phone notifications are working."); ntfyTestResult = "Sent. Check your phone." }
            catch { ntfyTestResult = error.localizedDescription }
        }
    }
}
