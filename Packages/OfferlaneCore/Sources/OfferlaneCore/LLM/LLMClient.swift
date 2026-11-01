import Foundation

public struct LLMRequest: Sendable {
    public var prompt: String
    /// Instructions (short).
    public var system: String
    /// Large static context (bullet bank, candidate brief): prompt-cached where the provider supports it.
    public var cache: String
    /// Use the stronger model (parsing, tailoring, search setup); otherwise the fast one (scoring, email).
    public var smart: Bool
    public var maxTokens: Int
    public init(prompt: String, system: String = "", cache: String = "", smart: Bool = false, maxTokens: Int = 1500) {
        self.prompt = prompt; self.system = system; self.cache = cache; self.smart = smart; self.maxTokens = maxTokens
    }
    public static let defaultSystem = "You are a precise assistant. Reply with JSON only."
}

public struct LLMUsage: Sendable, Equatable {
    public var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
}

public struct LLMResponse: Sendable {
    public var text: String
    public var usage: LLMUsage
    public var model: String
    /// Estimated spend; 0 for a subscription (Claude CLI) or a local model.
    public var usd: Double
    public init(text: String, usage: LLMUsage = .init(), model: String = "", usd: Double = 0) {
        self.text = text; self.usage = usage; self.model = model; self.usd = usd
    }
}

public protocol LLMClient: Sendable {
    /// Shown in Settings ("Claude (subscription)", "Claude API", "Ollama · qwen3:8b").
    var displayName: String { get }
    /// Whether calls cost money per token (drives the usage note in Settings).
    var billed: Bool { get }
    func complete(_ request: LLMRequest) async throws -> LLMResponse
}

public enum LLMError: LocalizedError, Equatable {
    case notConfigured
    case notInstalled(String)
    case notSignedIn(String)
    case usageLimit(String)
    case http(Int, String)
    case unreachable(String)
    case badJSON(String)
    case timedOut
    case cancelled
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "No AI is connected yet. Choose one in Settings → AI."
        case .notInstalled(let m), .notSignedIn(let m), .unreachable(let m), .other(let m): m
        case .usageLimit(let m): "Your Claude plan's usage limit was reached. It resets later; try again then, or switch to an API key or Ollama in Settings. (\(m))"
        case .http(let code, let body): "The AI service returned an error (\(code)): \(body.prefix(200))"
        case .badJSON(let t): "The AI's answer wasn't valid JSON, even after a retry: \(t.prefix(160))"
        case .timedOut: "The AI took too long to answer. Try again."
        case .cancelled: "Cancelled."
        }
    }
}
