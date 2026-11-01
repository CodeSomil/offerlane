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
        .commands {
            CommandGroup(after: .newItem) {
                Button("Find Jobs") { model.findJobs() }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }

        Window("Apply", id: "apply") {
            ApplyWindowView().environment(model)
        }
        .defaultSize(width: 1180, height: 860)

        MenuBarExtra("Offerlane", systemImage: "road.lanes") {
            Text("To Do: \(model.todoCount)")
            if model.isFinding { Text(model.findProgress?.message ?? "Finding jobs…") }
            Button("Find Jobs") { model.findJobs() }.disabled(model.isFinding || !model.aiConnected)
            Button("Check Inbox") { model.checkInbox() }.disabled(!model.settings.email.enabled)
            Divider()
            OpenMainWindowButton()
            Button("Quit Offerlane") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

private struct OpenMainWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Offerlane") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
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
