import SwiftUI
import UserNotifications
import OfferlaneCore

@main
struct OfferlaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Offerlane", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Find Jobs") { model.findJobs() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.isFinding || !model.settings.onboarded)
                Button("Check Inbox") { model.checkInbox() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(model.checkingInbox || !model.settings.onboarded)
            }
            CommandGroup(after: .appSettings) {
                Button("Setup Center…") { model.showSetupCenter = true }
                    .disabled(model.account == nil && !AppModel.authBypass)
                Button("Sign Out") { model.signOut() }
                    .disabled(model.account == nil)
            }
            CommandGroup(replacing: .help) { HelpCommands(model: model) }
            CommandMenu("Go") {
                Button("Command Palette…") { model.showPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(!model.settings.onboarded || model.auth != .signedIn)
                Divider()
                ForEach(SidebarItem.allCases) { item in
                    Button(item.title) { model.navigate(to: item) }
                        .keyboardShortcut(item.shortcut, modifiers: .command)
                        .disabled(!model.settings.onboarded)
                }
            }
        }

        Window("Offerlane Help", id: "help") {
            HelpView().environment(model)
        }
        .defaultSize(width: 900, height: 600)

        Window("Apply", id: "apply") {
            ApplyWindowView().environment(model)
        }
        .defaultSize(width: 1180, height: 860)

        MenuBarExtra {
            Text(model.reviewCount == 0 ? "Nothing waiting for you" : "Waiting for you: \(model.reviewCount)")
            if model.isFinding { Text(model.findProgress?.message ?? "Finding jobs…") }
            Button("Find Jobs") { model.findJobs() }.disabled(model.isFinding || !model.aiConnected)
            Button("Check Inbox") { model.checkInbox() }.disabled(!model.settings.email.enabled)
            Divider()
            OpenMainWindowButton()
            Button("Quit Offerlane") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            // The lane glyph, with a count when something is waiting.
            HStack(spacing: 2) {
                Image(systemName: "road.lanes")
                if model.reviewCount > 0 { Text("\(model.reviewCount)").monospacedDigit() }
            }
            .accessibilityLabel(model.reviewCount > 0 ? "Offerlane, \(model.reviewCount) waiting" : "Offerlane")
        }

        Settings {
            Group {
                if model.auth == .signedIn { SettingsView() }
                else { EmptyState(title: "Sign in first", symbol: "person.crop.circle", message: "Settings belong to your profile. Sign in from the main window.") }
            }
            .environment(model).frame(minWidth: 560, minHeight: 360)
        }
    }
}

/// Brings the main window forward, opening one only if none is open (openWindow on a WindowGroup always adds one).
@MainActor func showMainWindow(_ openWindow: OpenWindowAction) {
    if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) { w.makeKeyAndOrderFront(nil) }
    else { openWindow(id: "main") }
    NSApp.activate(ignoringOtherApps: true)
}

private struct HelpCommands: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Offerlane Help") { openWindow(id: "help") }.keyboardShortcut("?", modifiers: .command)
        Button("Take the Tour") { showMainWindow(openWindow); model.startTour() }
            .disabled(!model.settings.onboarded || model.auth != .signedIn)
        Divider()
        Button("Send Diagnostics…") { showMainWindow(openWindow); model.showDiagnostics = true }
            .disabled(model.auth != .signedIn)
    }
}

private struct OpenMainWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Offerlane") { showMainWindow(openWindow) }
    }
}

/// Actionable notifications: "Review" and "Open Form" bring the right screen forward.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var onAction: ((String) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let c = UNUserNotificationCenter.current(); c.delegate = self
        c.setNotificationCategories([
            UNNotificationCategory(identifier: "REVIEW", actions: [UNNotificationAction(identifier: "REVIEW", title: "Review", options: [.foreground])], intentIdentifiers: []),
            UNNotificationCategory(identifier: "OPEN_FORM", actions: [UNNotificationAction(identifier: "OPEN", title: "Open Form", options: [.foreground])], intentIdentifiers: []),
        ])
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        let category = r.notification.request.content.categoryIdentifier
        await MainActor.run { AppDelegate.onAction?(category) }
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
