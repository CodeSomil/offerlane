import Foundation

/// One entry of the provider registry. Field meanings are in docs/PROVIDERS.md.
public struct ProviderSpec: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case cli, key, local }
    public enum Status: String, Codable, Sendable { case verified, unverified, retired, dropped }
    public struct Pin: Codable, Sendable, Equatable {
        public var url: URL
        public var verify: String
    }
    public var id: String
    public var name: String
    public var kind: Kind
    public var status: Status
    public var statusReason: String?
    public var free: Bool
    /// nil when the provider does not say (unverified entries).
    public var trainsOnData: Bool?
    public var openAICompatible: Bool
    /// May hold a placeholder such as `{account_id}`, so it stays a string.
    public var baseURL: String?
    public var keyPageURL: URL?
    public var keyFormat: String?
    public var models: [String]
    public var limits: String
    public var steps: [String]
    public var privacyNote: String
    public var pins: [Pin]
    /// Largest request (tokens in + out) the provider's published limits allow; nil = no published number.
    public var maxRequestTokens: Int?
    /// App asset name of the provider's own logo; only set where the brand's published rules allow it (docs/PROVIDERS.md).
    /// Bundled only: `merge` never takes it from a downloaded registry.
    public var logo: String?
    /// "Sign in with <provider>" endpoints that hand back an API key (PKCESignIn). Bundled only, like install pins.
    public var pkceSignIn: PKCESignIn.Endpoints?
    /// Curated models shown as three cards (OpenRouter). Bundled only, like pins: a downloaded list can never add or qualify one.
    public var picks: [Pick]?

    /// One curated model choice. `id` does tailoring and parsing; `fast` (when set) does scoring and email.
    public struct Pick: Codable, Sendable, Equatable, Identifiable {
        public enum Tier: String, Codable, Sendable { case recommended, cheaper, advanced }
        public var id: String
        public var fast: String?
        public var tier: Tier
        /// Passed `offerlane-modelcheck` live. Unqualified picks are never labelled "Recommended".
        public var qualified: Bool
        public var use: String
        public var privacy: String
        public init(id: String, fast: String? = nil, tier: Tier, qualified: Bool = false, use: String, privacy: String) {
            self.id = id; self.fast = fast; self.tier = tier; self.qualified = qualified; self.use = use; self.privacy = privacy
        }
    }

    /// Only providers whose terms and flow were verified may be offered in the UI (INVARIANTS).
    public var isVisible: Bool { status == .verified }

    /// Installers may only come from a URL pinned for this provider.
    public func isPinned(_ url: URL) -> Bool { pins.contains { $0.url == url } }

    /// The provider a pasted key belongs to, judged only by published key formats (nil when no format matches).
    public static func keyOwner(_ key: String, among specs: [ProviderSpec]) -> ProviderSpec? {
        specs.first { $0.keyFormat != nil && $0.keyLooksValid(key) }
    }

    /// Whether a pasted key looks right. Providers without a published format accept any non-blank key.
    public func keyLooksValid(_ key: String) -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return false }
        guard let f = keyFormat else { return true }
        return k.range(of: f, options: .regularExpression) != nil
    }

    public init(id: String, name: String, kind: Kind, status: Status = .verified, statusReason: String? = nil, free: Bool = true,
                trainsOnData: Bool? = false, openAICompatible: Bool = true, baseURL: String? = nil, keyPageURL: URL? = nil,
                keyFormat: String? = nil, models: [String] = [], limits: String = "", steps: [String] = [], privacyNote: String = "",
                pins: [Pin] = []) {
        self.id = id; self.name = name; self.kind = kind; self.status = status; self.statusReason = statusReason; self.free = free
        self.trainsOnData = trainsOnData; self.openAICompatible = openAICompatible; self.baseURL = baseURL; self.keyPageURL = keyPageURL
        self.keyFormat = keyFormat; self.models = models; self.limits = limits; self.steps = steps; self.privacyNote = privacyNote; self.pins = pins
    }
}

/// The bundled AI provider registry (Resources/providers.json); facts and sources are in docs/PROVIDERS.md.
public enum ProviderRegistry {
    public static var bundledURL: URL? { Bundle.module.url(forResource: "Resources/providers", withExtension: "json") }

    private struct File: Decodable { var version: Int; var providers: [ProviderSpec] }

    /// The copy fetched by `refresh`. Only its limits, model lists, privacy facts and status downgrades are used (`merge`).
    public static var refreshedURL: URL { Paths.base.appendingPathComponent("providers-refresh.json") }

    /// The bundled registry, updated from the refreshed copy when there is one.
    public static func load(from url: URL? = bundledURL, refreshed: URL? = refreshedURL) throws -> [ProviderSpec] {
        guard let url else { throw LLMError.other("The AI provider list is missing from this copy of Offerlane. Reinstall Offerlane.") }
        let bundled = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        // A missing, unreadable or different-schema refresh is ignored: the bundled list always works.
        guard let refreshed, let data = try? Data(contentsOf: refreshed), let remote = try? JSONDecoder().decode(File.self, from: data),
              remote.version == bundled.version else { return bundled.providers }
        return merge(bundled.providers, remote.providers)
    }

    /// The providers the app may offer, in registry order.
    public static func visible(from url: URL? = bundledURL) throws -> [ProviderSpec] { try load(from: url).filter(\.isVisible) }

    /// Applies a downloaded registry to the bundled one. Install pins, URLs, key formats, setup steps and picks always stay bundled
    /// (INVARIANTS: installs only from pins shipped with the app). Unknown providers are ignored. A provider can be hidden,
    /// lose "free" or gain a training warning, but never become verified, free or private remotely: that needs an app update.
    static func merge(_ bundled: [ProviderSpec], _ remote: [ProviderSpec]) -> [ProviderSpec] {
        bundled.map { b in
            guard let r = remote.first(where: { $0.id == b.id }) else { return b }
            var m = b
            m.limits = r.limits; m.privacyNote = r.privacyNote; m.maxRequestTokens = r.maxRequestTokens
            if !r.models.isEmpty { m.models = r.models }
            m.free = b.free && r.free
            if r.trainsOnData != false { m.trainsOnData = r.trainsOnData }
            if r.status != .verified { m.status = r.status; m.statusReason = r.statusReason }
            return m
        }
    }

    /// Downloads the registry from `feed` (HTTPS only, at most 512 KB, must parse) and keeps it for `load`.
    public static func refresh(from feed: URL, to dest: URL = refreshedURL, session: URLSession = .shared) async throws {
        guard feed.scheme == "https" else { throw LLMError.other("The provider list can only be updated over a secure connection.") }
        var req = URLRequest(url: feed); req.timeoutInterval = 15
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, data.count <= 512 << 10,
              let file = try? JSONDecoder().decode(File.self, from: data), !file.providers.isEmpty else {
            throw LLMError.other("The updated provider list couldn't be read. Offerlane keeps using the one it has.")
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
    }
}
