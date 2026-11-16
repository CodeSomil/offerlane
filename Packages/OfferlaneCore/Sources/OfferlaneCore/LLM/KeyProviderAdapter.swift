import Foundation

/// Any registry provider reached with an API key over the OpenAI chat API (Gemini, OpenRouter, Cloudflare, a custom endpoint).
/// Nothing is installed; the key format, the strict-JSON test and the keychain save are done by `ProviderSetup`.
public struct KeyProviderAdapter: ProviderAdapter {
    public let spec: ProviderSpec
    /// The model the user picked; nil uses the registry's first model.
    public var model: String?
    /// Fills `{account_id}` in the registry URL (Cloudflare).
    public var accountID: String
    /// The user's base URL, for providers without one in the registry (custom endpoint).
    public var customBaseURL: String
    let session: URLSession

    public init(spec: ProviderSpec, model: String? = nil, accountID: String = "", customBaseURL: String = "", session: URLSession = .shared) {
        self.spec = spec; self.model = model; self.accountID = accountID; self.customBaseURL = customBaseURL; self.session = session
    }

    /// Providers this adapter can set up: visible, key-based and OpenAI-compatible.
    public static func supports(_ s: ProviderSpec) -> Bool { s.isVisible && s.kind == .key && s.openAICompatible }

    /// Whether the registry URL needs an account ID filled in.
    public var needsAccountID: Bool { spec.baseURL?.contains("{account_id}") == true }

    /// The endpoint to call, or nil while a required field is missing or malformed.
    public var baseURL: URL? {
        guard let raw = spec.baseURL else { return URL.web(customBaseURL.trimmingCharacters(in: .whitespaces)) }
        guard needsAccountID else { return URL(string: raw) }
        let id = accountID.trimmingCharacters(in: .whitespaces)
        // Account IDs are hex; anything else could rewrite the URL.
        guard !id.isEmpty, id.allSatisfy(\.isHexDigit) else { return nil }
        return URL(string: raw.replacingOccurrences(of: "{account_id}", with: id))
    }

    public func detect() async -> Bool { true }
    public func recommend(_ hardware: SystemCheck.Hardware) -> [String] {
        let m = model?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? spec.models : [m]
    }
    public func consent() -> InstallConsent? { nil }
    public func install(from url: URL) async throws {}

    public func configure(model: String) async throws -> ProviderConfig {
        guard let baseURL else {
            throw LLMError.other(needsAccountID ? "The \(spec.name) account ID is missing or isn't valid. Copy it from the dashboard's sidebar."
                                                : "The endpoint address isn't a valid web address. Enter it as https://…")
        }
        return ProviderConfig(providerID: spec.id, model: model, baseURL: baseURL.absoluteString)
    }

    /// The key itself is proven by the strict-JSON test that follows.
    public func authenticate(_ config: ProviderConfig, secret: String?) async throws {}

    public func client(_ config: ProviderConfig, secret: String?) -> any LLMClient {
        OpenAICompatibleClient(baseURL: URL(string: config.baseURL ?? "") ?? URL(string: "https://invalid.invalid")!,
                               modelFast: config.model, modelSmart: config.model, apiKey: secret ?? "", name: spec.name, session: session)
    }
}

/// OpenRouter's live model list with prices, for the "Show all models" list and the price line on each pick.
/// `:free` models are never listed (D6). Cached for 24 h; when both the cache and the network fail, the list is empty.
public enum OpenRouterCatalog {
    public struct Model: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        /// US dollars per million tokens; nil when OpenRouter's reply has no readable price.
        public var inPerM: Double?
        public var outPerM: Double?
        public var priceText: String {
            guard let i = inPerM, let o = outPerM else { return "price unavailable" }
            return String(format: "$%.2f in · $%.2f out per million tokens", i, o)
        }
    }
    private struct Cache: Codable { var at: Date; var models: [Model] }

    public static var cacheURL: URL { Paths.base.appendingPathComponent("openrouter-models.json") }

    public static func models(baseURL: URL, cache: URL = cacheURL, now: Date = Date(), session: URLSession = .shared) async -> [Model] {
        if let d = try? Data(contentsOf: cache), let c = try? JSONDecoder().decode(Cache.self, from: d),
           now.timeIntervalSince(c.at) >= 0, now.timeIntervalSince(c.at) < 24 * 3600 { return c.models }
        // SHORTCUT: pricing shape (`pricing.prompt`/`completion`, USD per token as strings) follows OpenRouter's documented format;
        // the 2026-11-11 live check returned no pricing at all, so unreadable prices show "price unavailable" rather than failing.
        struct List: Decodable { struct M: Decodable { struct P: Decodable { var prompt: String?; var completion: String? }; var id: String; var pricing: P? }; var data: [M] }
        guard let (data, resp) = try? await session.data(from: baseURL.appendingPathComponent("models")),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode(List.self, from: data) else { return [] }
        let perM = { (s: String?) in s.flatMap(Double.init).map { $0 * 1_000_000 } }
        let models = list.data.filter { !$0.id.hasSuffix(":free") }.sorted { $0.id < $1.id }
            .map { Model(id: $0.id, inPerM: perM($0.pricing?.prompt), outPerM: perM($0.pricing?.completion)) }
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Cache(at: now, models: models)).write(to: cache, options: .atomic)
        return models
    }
}
