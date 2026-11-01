import Foundation

public enum AIFactory {
    /// The client for the saved settings, or nil when no AI is configured yet.
    /// OFFERLANE_FAKE_AI=1 (UI tests) always returns the deterministic fake.
    public static func client(_ s: AppSettings, keychain: Keychain) -> (any LLMClient)? {
        if ProcessInfo.processInfo.environment["OFFERLANE_FAKE_AI"] == "1" { return FakeLLM.prototype }
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
            let base = URL(string: s.baseUrl.isEmpty ? "http://localhost:11434/v1" : s.baseUrl)!
            return OpenAICompatibleClient(baseURL: base, modelFast: s.modelFast.isEmpty ? s.modelSmart : s.modelFast, modelSmart: s.modelSmart)
        case .none:
            return nil
        }
    }
}
