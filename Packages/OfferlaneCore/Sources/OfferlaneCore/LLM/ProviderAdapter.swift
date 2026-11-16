import Foundation

/// The eight steps every provider goes through, in this order.
public enum SetupStep: String, CaseIterable, Sendable { case detect, recommend, consent, install, configure, authenticate, test, save }

/// What the user is asked to approve before anything is downloaded.
public struct InstallConsent: Sendable, Equatable {
    public var what: String
    public var from: URL
    public var bytes: Int64?
    public var needsAdmin: Bool
    public init(what: String, from: URL, bytes: Int64? = nil, needsAdmin: Bool = false) {
        self.what = what; self.from = from; self.bytes = bytes; self.needsAdmin = needsAdmin
    }
}

/// What a finished setup produces; the caller stores it in settings. The key itself stays in the keychain.
public struct ProviderConfig: Codable, Sendable, Equatable {
    public var providerID: String
    public var model: String
    public var baseURL: String?
    public init(providerID: String, model: String, baseURL: String? = nil) { self.providerID = providerID; self.model = model; self.baseURL = baseURL }
}

/// One provider's side of setup. `ProviderSetup` drives the steps, checks pins and keys, runs the test and saves.
public protocol ProviderAdapter: Sendable {
    var spec: ProviderSpec { get }
    /// Already installed or reachable, so consent and install are skipped.
    func detect() async -> Bool
    /// Models that suit this Mac, best first.
    func recommend(_ hardware: SystemCheck.Hardware) -> [String]
    /// The download to approve, or nil when there is nothing to install.
    func consent() -> InstallConsent?
    func install(from url: URL) async throws
    func configure(model: String) async throws -> ProviderConfig
    func authenticate(_ config: ProviderConfig, secret: String?) async throws
    func client(_ config: ProviderConfig, secret: String?) -> any LLMClient
}

public struct SetupFailure: LocalizedError, Equatable {
    public var step: SetupStep
    public var cause: String
    public var fix: String
    public var errorDescription: String? { "\(cause) \(fix)" }
}

public struct ProviderSetup: Sendable {
    public let adapter: any ProviderAdapter
    public let keychain: Keychain
    public let hardware: SystemCheck.Hardware
    public init(_ adapter: any ProviderAdapter, keychain: Keychain = Keychain(), hardware: SystemCheck.Hardware = SystemCheck.hardware) {
        self.adapter = adapter; self.keychain = keychain; self.hardware = hardware
    }

    /// As long as a real tailoring prompt (about 4,000 tokens of context), so a model that only copes with short prompts fails here, not mid-run.
    static let testPrompt = LLMRequest(prompt: "Reply with exactly this JSON and nothing else: {\"ok\": true}", system: LLMRequest.defaultSystem,
                                       cache: testContext, smart: true, maxTokens: 50)
    static let testContext = "Context (ignore it; it only sizes the request like a real resume and job posting):\n" + String(repeating:
        "- Led a cross-functional team to launch a product used by many customers; partnered with sales, legal and engineering.\n", count: 160)
    struct TestReply: Decodable { var ok: Bool }

    /// Runs all eight steps. `approve` is asked before any install; `progress` hears each step as it starts.
    public func run(secret: String? = nil, approve: @Sendable (InstallConsent) async -> Bool,
                    progress: @Sendable (SetupStep) -> Void = { _ in }) async -> Result<ProviderConfig, SetupFailure> {
        let spec = adapter.spec
        let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        var step = SetupStep.detect
        func fail(_ cause: String, _ fix: String) -> Result<ProviderConfig, SetupFailure> {
            Log.error("AI setup \(spec.id) failed at \(step.rawValue)")
            return .failure(SetupFailure(step: step, cause: Self.hide(cause, secret), fix: fix))
        }
        do {
            progress(step)
            let installed = await adapter.detect()

            step = .recommend; progress(step)
            guard let model = adapter.recommend(hardware).first ?? spec.models.first else {
                return fail("No \(spec.name) model fits this Mac.", "Choose a different AI in Settings → AI.")
            }

            step = .consent; progress(step)
            var download: InstallConsent?
            if !installed {
                guard let c = adapter.consent() else {
                    return fail("\(spec.name) isn't installed and Offerlane can't install it.", "Install it yourself, then run setup again.")
                }
                guard await approve(c) else { return fail("You chose not to install \(c.what).", "Run setup again when you're ready.") }
                download = c
            }

            step = .install; progress(step)
            if let c = download {
                guard spec.isPinned(c.from) else {
                    return fail("The download address \(c.from.absoluteString) isn't one Offerlane trusts for \(spec.name).",
                                "Nothing was downloaded. Update Offerlane, then try again.")
                }
                try await adapter.install(from: c.from)
            }

            step = .configure; progress(step)
            let config = try await adapter.configure(model: model)

            step = .authenticate; progress(step)
            if spec.kind == .key {
                guard let secret, spec.keyLooksValid(secret) else {
                    return fail("That doesn't look like a \(spec.name) key.",
                                "Copy the whole key again\(spec.keyPageURL.map { " from \($0.absoluteString)" } ?? ""), then paste it.")
                }
            }
            try await adapter.authenticate(config, secret: secret)

            step = .test; progress(step)
            let reply = try await adapter.client(config, secret: secret).complete(Self.testPrompt)
            guard (try? AI.decode(reply.text, as: TestReply.self))?.ok == true else {
                return fail("\(spec.name) answered, but not with the strict JSON Offerlane needs.", "Choose a stronger model, then run the test again.")
            }

            step = .save; progress(step)
            if let secret, spec.kind == .key { try keychain.set(secret, account: Keychain.Account.provider(spec.id)) }
            Log.info("AI setup \(spec.id) done with \(config.model)")
            return .success(config)
        } catch {
            return fail(error.localizedDescription, Self.fix(for: step))
        }
    }

    static func fix(for step: SetupStep) -> String {
        switch step {
        case .install: "Check your internet connection and free disk space, then try again."
        case .authenticate: "Check the key or sign-in, then try again."
        case .test: "Check your internet connection, then run the test again. If it keeps failing, choose another AI."
        case .save: "Unlock your Mac's keychain, then try again."
        default: "Try again. If it keeps failing, choose another AI in Settings → AI."
        }
    }

    /// Provider errors sometimes echo the key back; it never reaches the UI or logs.
    static func hide(_ text: String, _ secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return Log.redact(text) }
        return Log.redact(text.replacingOccurrences(of: secret, with: "<key>"))
    }
}

/// A provider that needs no network or install, for tests and OFFERLANE_FAKE_AI=1 runs.
public struct FakeProviderAdapter: ProviderAdapter {
    public var spec: ProviderSpec
    public var installed: Bool
    public var download: URL
    /// When set, `authenticate` throws this message (to check failures never show the key).
    public var authError: String?
    public var reply: String
    public init(installed: Bool = false, download: URL = URL(string: "https://ollama.com/fake/Fake.dmg")!, authError: String? = nil,
                reply: String = "{\"ok\": true}") {
        self.spec = ProviderSpec(id: "fake", name: "Fake AI", kind: .key, keyFormat: "^fk-", models: ["fake-small"],
                                 steps: ["Paste the key", "Run the connection test"], privacyNote: "Nothing leaves this Mac.",
                                 pins: [.init(url: URL(string: "https://ollama.com/fake/Fake.dmg")!, verify: "test only")])
        self.installed = installed; self.download = download; self.authError = authError; self.reply = reply
    }
    public func detect() async -> Bool { installed }
    public func recommend(_ hw: SystemCheck.Hardware) -> [String] { hw.isLowMemory ? ["fake-small"] : ["fake-large", "fake-small"] }
    public func consent() -> InstallConsent? { InstallConsent(what: "Fake AI", from: download, bytes: 1_000_000) }
    public func install(from url: URL) async throws {}
    public func configure(model: String) async throws -> ProviderConfig { ProviderConfig(providerID: spec.id, model: model) }
    public func authenticate(_ config: ProviderConfig, secret: String?) async throws { if let authError { throw LLMError.other(authError) } }
    public func client(_ config: ProviderConfig, secret: String?) -> any LLMClient { FakeLLM(rules: [{ _ in reply }]) }
}
