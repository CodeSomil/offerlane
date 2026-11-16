import Foundation

public enum AIFactory {
    /// The client for the saved settings, or nil when no AI is configured yet.
    /// OFFERLANE_FAKE_AI=1 (UI tests) always returns the deterministic fake.
    public static func client(_ s: AppSettings, keychain: Keychain) -> (any LLMClient)? {
        if TestHooks.env["OFFERLANE_FAKE_AI"] == "1" { return FakeLLM.prototype }
        guard let primary = single(s, keychain: keychain) else { return nil }
        // A fallback that can't be built (key removed, model missing) is skipped, never fatal.
        let rest = s.fallbacks.compactMap { c -> (any LLMClient)? in var f = s; f.connection = c; return single(f, keychain: keychain) }
        return ResilientClient(chain: [primary] + rest)
    }

    /// The one client for these settings, without retries.
    static func single(_ s: AppSettings, keychain: Keychain) -> (any LLMClient)? {
        switch s.provider {
        case .claudeCLI:
            guard let exe = ClaudeCLIClient.locate(extra: s.claudePath) else { return nil }
            return ClaudeCLIClient(executable: exe, modelFast: s.modelFast.isEmpty ? "haiku" : s.modelFast,
                                   modelSmart: s.modelSmart.isEmpty ? "sonnet" : s.modelSmart)
        case .anthropic:
            guard let key = keychain.get(account: Keychain.Account.anthropicKey), !key.isEmpty else { return nil }
            return AnthropicClient(apiKey: key, modelFast: s.modelFast.isEmpty ? AnthropicClient.defaultFast : s.modelFast,
                                   modelSmart: s.modelSmart.isEmpty ? AnthropicClient.defaultSmart : s.modelSmart)
        case .ollama:
            guard !s.modelSmart.isEmpty else { return nil }
            // A mistyped address must never crash the app at launch: fall back to the standard local one.
            let base = URL.web(s.baseUrl) ?? URL(string: "http://localhost:11434/v1")!
            return OllamaClient(baseURL: base, modelFast: s.modelFast.isEmpty ? s.modelSmart : s.modelFast, modelSmart: s.modelSmart)
        case .apiKey:
            guard let base = URL.web(s.baseUrl), !s.modelSmart.isEmpty,
                  let key = keychain.get(account: Keychain.Account.provider(s.providerID)), !key.isEmpty else { return nil }
            // D6: a free OpenRouter model saved before v4 counts as not connected, so the app asks for a new pick instead of
            // failing every call (OpenAICompatibleClient refuses ":free" for OpenRouter).
            if OpenAICompatibleClient.isOpenRouter(base), [s.modelSmart, s.modelFast].contains(where: { $0.hasSuffix(":free") }) { return nil }
            let spec = (try? ProviderRegistry.load())?.first { $0.id == s.providerID }
            return OpenAICompatibleClient(baseURL: base, modelFast: s.modelFast.isEmpty ? s.modelSmart : s.modelFast, modelSmart: s.modelSmart,
                                          apiKey: key, name: spec?.name ?? s.providerID, maxRequestTokens: spec?.maxRequestTokens)
        case .none:
            return nil
        }
    }
}
