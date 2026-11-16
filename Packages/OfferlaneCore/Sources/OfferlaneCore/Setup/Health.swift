import Foundation

/// What Offerlane needs to work, checked in one place: the sidebar dot, the Setup Center list and
/// "Repair everything" all read the same report.
public enum Health {
    public enum Status: Int, Comparable, Sendable {
        case ok, info, warning, problem
        public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    /// What the "Fix it" button does. `automatic` fixes can run unattended from "Repair everything".
    public enum Fix: Equatable, Sendable {
        case chooseAI, installClaude, signInClaude, enterAPIKey, installOllama, startOllama, downloadModel(String)
        case freeDisk, recheck, rosettaHelp

        public var automatic: Bool {
            switch self {
            case .installClaude, .installOllama, .startOllama, .downloadModel, .recheck: true
            case .chooseAI, .signInClaude, .enterAPIKey, .freeDisk, .rosettaHelp: false
            }
        }
        public var label: String {
            switch self {
            case .chooseAI: "Choose an AI"
            case .installClaude: "Install Claude Code"
            case .signInClaude: "Sign In"
            case .enterAPIKey: "Add Key"
            case .installOllama: "Install Ollama"
            case .startOllama: "Start Ollama"
            case .downloadModel: "Download Model"
            case .freeDisk: "Show Storage"
            case .recheck: "Try Again"
            case .rosettaHelp: "Show Me How"
            }
        }
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var status: Status
        public var message: String
        public var fix: Fix?
    }

    /// Everything the checks look at. Gathered by `Health.gather`, or written by hand in tests.
    public struct Facts: Equatable, Sendable {
        public var provider: AppSettings.Provider = .none
        public var testAI = false
        public var claudeInstalled = false
        public var claudeSignedIn = false
        public var apiKeySaved = false
        /// The key provider's name when `provider` is `.apiKey`.
        public var providerName = ""
        public var ollamaInstalled = false
        public var ollamaRunning = false
        public var ollamaModel = ""
        public var ollamaHasModel = false
        public var online = true
        public var freeDisk: Int64 = 100_000_000_000
        public var chip: SystemCheck.Chip = .appleSilicon
        public var translated = false
        public var latexEngine = true
        public init() {}
    }

    public static let lowDisk: Int64 = 2_000_000_000
    public static let tightDisk: Int64 = 10_000_000_000

    public static func evaluate(_ f: Facts) -> [Item] {
        var items: [Item] = [ai(f)]
        items.append(f.online
            ? Item(id: "internet", title: "Internet", status: .ok, message: "Connected.", fix: nil)
            : Item(id: "internet", title: "Internet", status: f.provider == .ollama ? .warning : .problem,
                   message: f.provider == .ollama
                       ? "You're offline. Your AI still works, but finding new jobs needs the internet."
                       : "You're offline. Finding jobs and your AI both need the internet. Connect to Wi-Fi, then try again.",
                   fix: .recheck))
        let free = SystemCheck.gb(f.freeDisk)
        items.append(f.freeDisk < lowDisk
            ? Item(id: "disk", title: "Storage", status: .problem, message: "Only \(free) free. Offerlane needs at least 2 GB to save resumes and applications. Delete some files, then try again.", fix: .freeDisk)
            : f.freeDisk < tightDisk
            ? Item(id: "disk", title: "Storage", status: .warning, message: "\(free) free. That's enough for Offerlane, but not for a local AI model.", fix: .freeDisk)
            : Item(id: "disk", title: "Storage", status: .ok, message: "\(free) free.", fix: nil))
        if f.translated {
            items.append(Item(id: "mac", title: "This Mac", status: .warning,
                              message: "Offerlane is running in Rosetta compatibility mode, which makes it slower. Turn off “Open using Rosetta” for Offerlane.",
                              fix: .rosettaHelp))
        } else if f.chip == .intel {
            items.append(Item(id: "mac", title: "This Mac", status: f.provider == .ollama ? .info : .ok,
                              message: f.provider == .ollama ? "Intel Mac: Ollama works, but slowly. Claude is much faster here." : "Intel Mac. Everything is supported.",
                              fix: nil))
        } else {
            items.append(Item(id: "mac", title: "This Mac", status: .ok, message: "Apple silicon. Everything is supported.", fix: nil))
        }
        items.append(f.latexEngine
            ? Item(id: "pdf", title: "Resume PDFs", status: .ok, message: "Built in.", fix: nil)
            : Item(id: "pdf", title: "Resume PDFs", status: .info,
                   message: "LaTeX resumes use the standard layout in this copy of Offerlane. Other resumes aren't affected.", fix: nil))
        return items
    }

    static func ai(_ f: Facts) -> Item {
        func item(_ s: Status, _ m: String, _ fix: Fix? = nil) -> Item { Item(id: "ai", title: "AI engine", status: s, message: m, fix: fix) }
        if f.testAI { return item(.ok, "Connected (test AI).") }
        switch f.provider {
        case .none: return item(.problem, "No AI is set up yet. Offerlane needs one to read resumes and score jobs.", .chooseAI)
        case .claudeCLI:
            if !f.claudeInstalled { return item(.problem, "Claude Code isn't installed on this Mac any more.", .installClaude) }
            if !f.claudeSignedIn { return item(.problem, "Claude is signed out. Sign in again with your Claude account.", .signInClaude) }
            return item(.ok, "Claude (your Claude account).")
        case .anthropic:
            return f.apiKeySaved ? item(.ok, "Claude API key.") : item(.problem, "Your Claude API key is missing. Paste it again.", .enterAPIKey)
        case .apiKey:
            return f.apiKeySaved ? item(.ok, "\(f.providerName) (API key).")
                                 : item(.problem, "Your \(f.providerName) API key is missing. Paste it again.", .enterAPIKey)
        case .ollama:
            if !f.ollamaInstalled { return item(.problem, "Ollama isn't installed on this Mac any more.", .installOllama) }
            if !f.ollamaRunning { return item(.problem, "Ollama isn't running.", .startOllama) }
            if !f.ollamaHasModel, !f.ollamaModel.isEmpty {
                return item(.problem, "The model \(f.ollamaModel) isn't downloaded.", .downloadModel(f.ollamaModel))
            }
            return item(.ok, "Ollama · \(f.ollamaModel).")
        }
    }

    public static func overall(_ items: [Item]) -> Status { items.map(\.status).max() ?? .ok }

    /// Sidebar wording.
    public static func summary(_ items: [Item]) -> String {
        let n = items.filter { $0.status >= .warning }.count
        return n == 0 ? "All set" : n == 1 ? "1 thing needs attention" : "\(n) things need attention"
    }

    /// Reads the real state of this Mac for `settings`. `apiKeySaved` and `testAI` come from the caller.
    public static func gather(settings: AppSettings, apiKeySaved: Bool, testAI: Bool, includeAI: Bool = true) async -> Facts {
        var f = Facts()
        f.provider = settings.provider; f.testAI = testAI; f.apiKeySaved = apiKeySaved
        if settings.provider == .apiKey {
            f.providerName = (try? ProviderRegistry.load())?.first { $0.id == settings.providerID }?.name ?? settings.providerID
        }
        f.chip = SystemCheck.chip; f.translated = SystemCheck.isTranslated
        f.freeDisk = SystemCheck.freeDiskBytes()
        f.latexEngine = LaTeXRender.tectonic != nil
        async let online = SystemCheck.isOnline()
        if includeAI, !testAI {
            switch settings.provider {
            case .claudeCLI:
                if let exe = ClaudeSetup.locate(settings.claudePath) {
                    f.claudeInstalled = true
                    f.claudeSignedIn = await ClaudeSetup.authStatus(exe)?.loggedIn ?? false
                }
            case .ollama:
                let o = OllamaSetup()
                f.ollamaInstalled = o.isInstalled
                f.ollamaRunning = await o.isRunning()
                f.ollamaModel = settings.modelSmart
                if f.ollamaRunning {
                    let models = (try? await o.models()) ?? []
                    f.ollamaHasModel = models.contains { $0 == f.ollamaModel || $0 == f.ollamaModel + ":latest" }
                }
            default: break
            }
        }
        f.online = await online
        return f
    }
}
