import Foundation
import Sparkle

/// "Check for Updates" (Sparkle 2). Only runs when the user asks; never checks automatically (SUEnableAutomaticChecks
/// is false). Off unless this build has a real feed URL and an EdDSA public key, so ad-hoc builds never offer updates.
@MainActor
final class Updater {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?

    /// Why updates are unavailable in this build, or nil when the check can run.
    var unavailableReason: String? {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = info["SUFeedURL"] as? String ?? "", key = info["SUPublicEDKey"] as? String ?? ""
        if feed.isEmpty || feed.contains("example.invalid") || key.isEmpty {
            return "Update checks are off in this build. Download new versions from the Offerlane releases page."
        }
        return nil
    }

    /// Sparkle downloads the feed off the main thread and shows its own window with the result.
    func checkForUpdates() {
        guard unavailableReason == nil else { return }
        if controller == nil {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
        controller?.checkForUpdates(nil)
    }
}
