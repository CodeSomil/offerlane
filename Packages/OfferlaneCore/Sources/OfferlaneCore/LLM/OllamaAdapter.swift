import Foundation

/// Ollama on this Mac through the eight setup steps. The checked install, model pull and launch live in `OllamaSetup`;
/// the pin check, strict-JSON test and save are done by `ProviderSetup`.
public struct OllamaAdapter: ProviderAdapter {
    public let spec: ProviderSpec
    /// The model the user picked; nil picks one by RAM and free disk.
    public var model: String?
    let setup: OllamaSetup
    let isInstalled: @Sendable () -> Bool
    let installApp: @Sendable () async throws -> Void
    /// Hears model download progress as (fraction, Ollama's status); fraction is -1 when unknown.
    let pullProgress: @Sendable (Double, String) -> Void

    public init(spec: ProviderSpec, model: String? = nil, setup: OllamaSetup = OllamaSetup(),
                isInstalled: (@Sendable () -> Bool)? = nil,
                installApp: @escaping @Sendable () async throws -> Void = { _ = try await OllamaSetup.install() },
                pullProgress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) {
        self.spec = spec; self.model = model; self.setup = setup
        self.isInstalled = isInstalled ?? { setup.isInstalled }
        self.installApp = installApp; self.pullProgress = pullProgress
    }

    public func detect() async -> Bool { await setup.isRunning() || isInstalled() }

    public func recommend(_ hw: SystemCheck.Hardware) -> [String] {
        let m = model?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? [OllamaSetup.recommended(ramBytes: hw.ramBytes, freeDisk: hw.freeDiskBytes).name] : [m]
    }

    public func consent() -> InstallConsent? {
        // shortcut: size is Ollama-darwin.zip as of v0.40.16 (229 MB), not read live; read the release's asset size if it drifts far.
        InstallConsent(what: "Ollama (free, runs AI on this Mac)", from: OllamaSetup.latestReleaseAPI, bytes: 230_000_000)
    }

    /// `ProviderSetup` has already checked `url` against the registry pins; the install itself downloads from that release only.
    public func install(from url: URL) async throws { try await installApp() }

    /// Starts Ollama if needed and downloads the model if it isn't on this Mac yet.
    public func configure(model: String) async throws -> ProviderConfig {
        if !(await setup.isRunning()) { try await setup.launch() }
        if !(try await setup.models()).contains(model) { try await setup.pull(model, progress: pullProgress) }
        return ProviderConfig(providerID: spec.id, model: model, baseURL: setup.baseURL.appendingPathComponent("v1").absoluteString)
    }

    public func authenticate(_ config: ProviderConfig, secret: String?) async throws {
        guard (try await setup.models()).contains(config.model) else {
            throw LLMError.other("Ollama doesn't have \(config.model) yet. Download it, then try again.")
        }
    }

    public func client(_ config: ProviderConfig, secret: String?) -> any LLMClient {
        OllamaClient(baseURL: setup.baseURL, modelFast: config.model, modelSmart: config.model, session: setup.session)
    }
}
