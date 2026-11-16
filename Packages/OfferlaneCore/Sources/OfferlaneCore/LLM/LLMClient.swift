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
    /// The fallback AI that answered (its display name); empty when the primary did.
    public var source = ""
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
    /// Largest request (estimated tokens in + out) to send in one call; batch callers split above it. nil = no limit.
    var maxRequestTokens: Int? { get }
}

extension LLMClient {
    public var maxRequestTokens: Int? { nil }
}

public enum LLMError: LocalizedError, Equatable {
    case notConfigured
    case notInstalled(String)
    case notSignedIn(String)
    case usageLimit(String)
    /// The provider's rate limit; `retryAfter` (seconds) when it said how long to wait.
    case rateLimited(String, retryAfter: Double?)
    case http(Int, String)
    case unreachable(String)
    case badJSON(String)
    case timedOut
    case cancelled
    case budget(used: Int, limit: Int)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "No AI is connected yet. Choose one in Settings → AI."
        case .notInstalled(let m), .notSignedIn(let m), .unreachable(let m), .other(let m): m
        case .usageLimit(let m): "Your Claude plan's usage limit was reached. It resets later; try again then, or switch to an API key or Ollama in Settings. (\(m))"
        case .rateLimited(let m, _): m
        case .http(let code, let body) where code >= 500: "The AI service is having problems right now (error \(code)). Try again in a few minutes, or add a second AI in Settings → AI so Offerlane can switch automatically. (\(body.prefix(120)))"
        case .http(let code, let body): "The AI service refused the request (error \(code)). Check the model and key in Settings → AI, then try again. (\(body.prefix(120)))"
        // The reply itself isn't shown or logged: it can contain resume text or a job posting.
        case .badJSON: "The AI's answer couldn't be read, even after a second try. Try again; if it keeps happening, switch to a stronger model in the Setup Center."
        case .timedOut: "The AI took too long to answer. Try again."
        case .cancelled: "Cancelled."
        case .budget(_, let limit): "Offerlane stopped here to stay within your AI limit of \(limit.formatted()) tokens for one run. Nothing was lost; the rest continues next time. To allow more, raise the limit in Settings → AI."
        }
    }
}

extension LLMError {
    /// A passing failure worth retrying (and then handing to the next connected AI); a bad key or bad JSON is not.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .timedOut, .unreachable: true
        case .http(let code, _): code >= 500
        default: false
        }
    }
    /// Worth trying the next connected AI after retries: transient failures plus a used-up plan.
    public var shouldFallBack: Bool {
        if case .usageLimit = self { return true }
        return isTransient
    }
}

extension HTTPURLResponse {
    /// `retry-after` in seconds (the HTTP-date form is ignored).
    var retryAfter: Double? { value(forHTTPHeaderField: "retry-after").flatMap(Double.init) }
}
