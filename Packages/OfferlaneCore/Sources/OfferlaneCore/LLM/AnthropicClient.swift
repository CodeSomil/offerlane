import Foundation

/// Claude API with the user's key (raw HTTP; there is no official Swift SDK). The static context goes in a
/// second system block marked `cache_control` so repeated tailorings pay for the bullet bank once.
public struct AnthropicClient: LLMClient {
    public let apiKey: String
    public let modelFast: String
    public let modelSmart: String
    public let baseURL: URL
    let session: URLSession
    public var displayName: String { "Claude API" }
    public var billed: Bool { true }

    public static let defaultFast = "claude-haiku-5-5"
    public static let defaultSmart = "claude-sonnet-5-5"
    public static let apiVersion = "2026-10-21"
    /// USD per million tokens: (input, output). Cache reads bill at 10% of input, cache writes at 125%.
    public static let prices: [String: (Double, Double)] = [
        "claude-haiku-5-5": (0.10, 0.50), "claude-sonnet-5-5": (2.0, 10.0), "claude-opus-5-5": (4.0, 20.0),
    ]

    public init(apiKey: String, modelFast: String = defaultFast, modelSmart: String = defaultSmart,
                baseURL: URL = URL(string: "https://api.anthropic.com")!, session: URLSession = .shared) {
        self.apiKey = apiKey; self.modelFast = modelFast; self.modelSmart = modelSmart; self.baseURL = baseURL; self.session = session
    }

    public func body(_ r: LLMRequest) -> [String: Any] {
        var system: [[String: Any]] = [["type": "text", "text": r.system.isEmpty ? LLMRequest.defaultSystem : r.system]]
        if !r.cache.isEmpty { system.append(["type": "text", "text": r.cache, "cache_control": ["type": "ephemeral"]]) }
        // These models think adaptively; low effort keeps short JSON tasks quick, and the extra headroom
        // in max_tokens leaves room for thinking before the answer.
        return ["model": r.smart ? modelSmart : modelFast, "max_tokens": min(16000, r.maxTokens + 4000),
                "system": system, "messages": [["role": "user", "content": r.prompt]],
                "output_config": ["effort": r.smart ? "medium" : "low"]]
    }

    public func complete(_ r: LLMRequest) async throws -> LLMResponse {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"; req.timeoutInterval = 300
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body(r))
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (data, resp): (Data, URLResponse)
            do { (data, resp) = try await session.data(for: req) } catch is CancellationError { throw LLMError.cancelled } catch {
                throw LLMError.unreachable("Can't reach the Claude API (\(error.localizedDescription)). Check your internet connection.")
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if [429, 500, 502, 503, 529].contains(code), attempt < 3 {
                attempt += 1
                let wait = Double((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after") ?? "") ?? Double(8 * attempt)
                try await Task.sleep(nanoseconds: UInt64(min(wait, 60) * 1e9)); continue
            }
            let text = String(decoding: data, as: UTF8.self)
            if code == 401 { throw LLMError.notSignedIn("The Claude API key was rejected. Check it in Settings → AI.") }
            guard code == 200 else { throw LLMError.http(code, text) }
            return try Self.parse(data)
        }
    }

    public static func parse(_ data: Data) throws -> LLMResponse {
        let d = try JSONDecoder().decode(JSONValue.self, from: data)
        if d["stop_reason"]?.string == "refusal" { throw LLMError.other("Claude declined this request.") }
        let text = (d["content"]?.array ?? []).filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined()
        let model = d["model"]?.string ?? ""
        let u = d["usage"]
        let usage = LLMUsage(input: Int(u?["input_tokens"]?.double ?? 0), output: Int(u?["output_tokens"]?.double ?? 0),
                             cacheRead: Int(u?["cache_read_input_tokens"]?.double ?? 0), cacheWrite: Int(u?["cache_creation_input_tokens"]?.double ?? 0))
        return LLMResponse(text: text, usage: usage, model: model, usd: cost(model: model, usage))
    }

    public static func cost(model: String, _ u: LLMUsage) -> Double {
        guard let (pin, pout) = prices.first(where: { model.hasPrefix($0.key) })?.value else { return 0 }
        return (Double(u.input) * pin + Double(u.cacheRead) * pin * 0.1 + Double(u.cacheWrite) * pin * 1.25 + Double(u.output) * pout) / 1e6
    }

    /// A one-token-ish call to validate a pasted key.
    public func test() async throws {
        _ = try await complete(LLMRequest(prompt: "Reply with exactly {\"ok\": true}", maxTokens: 20))
    }
}
