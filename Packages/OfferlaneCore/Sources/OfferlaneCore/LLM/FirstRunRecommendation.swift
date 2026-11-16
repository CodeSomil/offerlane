import Foundation

/// AI options ranked for this Mac's hardware from the registry; the first-run screen leads with the top one (P1.6).
public enum FirstRun {
    public struct Option: Sendable, Equatable {
        public let providerID: String
        public let name: String
        public let reason: String
        /// Which settings provider this option sets up (key providers share `.apiKey`).
        public var provider: AppSettings.Provider { providerID == "ollama" ? .ollama : providerID == "anthropic" ? .anthropic : .apiKey }
    }

    /// The first three of `options`.
    public static func recommend(_ hw: SystemCheck.Hardware, specs: [ProviderSpec]) -> [Option] { Array(options(hw, specs: specs).prefix(3)) }

    /// Every verified provider, easiest first: one-click sign-in (no key to copy), then local when the Mac can run a medium model,
    /// otherwise free keys.
    /// Providers missing from the preferred order (custom endpoint, new registry entries) follow in registry order.
    public static func options(_ hw: SystemCheck.Hardware, specs: [ProviderSpec]) -> [Option] {
        let model = OllamaSetup.recommended(ramBytes: hw.ramBytes, freeDisk: hw.freeDiskBytes)
        let localOK = hw.chip == .appleSilicon && !hw.isLowMemory && OllamaSetup.fits(model, freeDisk: hw.freeDiskBytes)
        let order = localOK ? ["openrouter", "ollama", "gemini", "anthropic", "groq", "cloudflare"]
                            : ["openrouter", "gemini", "anthropic", "groq", "cloudflare", "ollama"]
        let visible = specs.filter(\.isVisible)
        let rank = { (i: Int, s: ProviderSpec) in (order.firstIndex(of: s.id) ?? order.count, i) }  // index keeps it stable
        let ranked = visible.enumerated().sorted { rank($0.offset, $0.element) < rank($1.offset, $1.element) }.map(\.element)
        return ranked.map { Option(providerID: $0.id, name: $0.name, reason: reason($0, hw, model, localOK)) }
    }

    /// Short card text; numbers and training facts come from the registry, never hard-coded.
    private static func reason(_ spec: ProviderSpec, _ hw: SystemCheck.Hardware, _ m: OllamaSetup.ModelChoice, _ localOK: Bool) -> String {
        if spec.kind == .local {
            let ram = "\(hw.ramBytes >> 30) GB RAM"
            // shortcut: assumes 100 Mbit/s, upgrade to a measured speed if users report wrong estimates.
            let minutes = max(1, Int((m.sizeGB * 8_000 / 100 / 60).rounded()))
            return localOK ? "\(ram): runs \(m.name) on this Mac. Free and private. \(String(format: "%.1f", m.sizeGB)) GB download, about \(minutes) min."
                           : "Runs on this Mac, but slow with \(ram)\(hw.chip == .intel ? " on Intel" : "")."
        }
        if spec.id == "custom" { return "Your own OpenAI-compatible server or key." }
        if spec.pkceSignIn != nil {
            return "Sign in, no key to copy. Free models, or paid ones from many AI companies once you add credit."
                + (spec.trainsOnData == true ? " Some free models may train on prompts." : "")
        }
        let cost = spec.free ? "Free daily limit, nothing to install." : "Paid per use, nothing to install."
        let data = spec.trainsOnData == true ? " Free-tier prompts may be used for training." : " Not used for training."
        return cost + data
    }
}
