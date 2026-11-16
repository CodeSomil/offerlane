import Foundation

/// Any OpenAI-compatible server, via /v1/chat/completions (Ollama uses OllamaClient below).
public struct OpenAICompatibleClient: LLMClient {
    public let baseURL: URL
    public let modelFast: String
    public let modelSmart: String
    public let apiKey: String?
    /// The provider's name, used in the display name and error text.
    public let name: String
    public let maxRequestTokens: Int?
    let session: URLSession
    public var displayName: String { "\(name) · \(modelSmart)" }
    public var billed: Bool { false }

    public init(baseURL: URL = URL(string: "http://localhost:11434/v1")!, modelFast: String, modelSmart: String, apiKey: String? = nil,
                name: String = "Ollama", maxRequestTokens: Int? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL; self.modelFast = modelFast; self.modelSmart = modelSmart; self.apiKey = apiKey; self.name = name
        self.maxRequestTokens = maxRequestTokens; self.session = session
    }

    /// OpenRouter's own hosts (openrouter.ai and its subdomains), whatever route built this client.
    public static func isOpenRouter(_ url: URL) -> Bool {
        guard var h = url.host?.lowercased() else { return false }
        if h.hasSuffix(".") { h.removeLast() }   // "openrouter.ai." is the same host
        return h == "openrouter.ai" || h.hasSuffix(".openrouter.ai")
    }

    /// D6: OpenRouter only routes to providers that keep nothing and don't collect data; free models are refused
    /// because their providers may train on resume text.
    static let openRouterProvider: [String: Any] = ["data_collection": "deny", "zdr": true, "require_parameters": true]

    func request(_ r: LLMRequest) throws -> URLRequest {
        let model = r.smart ? modelSmart : modelFast
        let openRouter = Self.isOpenRouter(baseURL)
        if openRouter, model.hasSuffix(":free") {
            throw LLMError.other("Free OpenRouter models may keep or train on your resume, so Offerlane doesn't use them. Choose a model in Settings → AI.")
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"; req.timeoutInterval = 900
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let system = (r.system.isEmpty ? LLMRequest.defaultSystem : r.system) + (r.cache.isEmpty ? "" : "\n\n" + r.cache)
        var body: [String: Any] = [
            "model": model, "max_tokens": r.maxTokens, "temperature": 0.2,
            "messages": [["role": "system", "content": system], ["role": "user", "content": r.prompt]],
        ]
        if openRouter { body["provider"] = Self.openRouterProvider }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    public func complete(_ r: LLMRequest) async throws -> LLMResponse {
        let model = r.smart ? modelSmart : modelFast
        let req = try request(r)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) } catch is CancellationError { throw LLMError.cancelled } catch {
            throw LLMError.unreachable(apiKey == nil
                ? "Can't reach \(name) at \(baseURL.host ?? "localhost"). Is it running? Open Settings → AI to start it."
                : "Can't reach \(name). Check your internet connection.")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 401 where apiKey != nil, 403 where apiKey != nil: throw LLMError.notSignedIn("\(name) refused the API key (error \(code)). Create a new key, then paste it again.")
        case 429: throw LLMError.rateLimited("\(name)'s rate limit was reached (error 429). Wait a minute, or add another AI in Settings → AI.",
                                             retryAfter: (resp as? HTTPURLResponse)?.retryAfter)
        default: throw LLMError.http(code, String(decoding: data, as: UTF8.self))
        }
        guard let d = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw LLMError.other("\(name) sent a reply Offerlane couldn't read. Try again; if it keeps happening, choose another AI in Settings → AI.")
        }
        var text = d["choices"]?.array?.first?["message"]?["content"]?.string ?? ""
        // Reasoning models may prefix their answer with a <think> block.
        text = Re.sub("(?s)<think>.*?</think>", "", text).trimmingCharacters(in: .whitespacesAndNewlines)
        let u = d["usage"]
        return LLMResponse(text: text, usage: LLMUsage(input: Int(u?["prompt_tokens"]?.double ?? 0), output: Int(u?["completion_tokens"]?.double ?? 0)),
                           model: model, usd: 0)
    }
}

/// Ollama through its own /api/chat, which (unlike /v1) takes a context size and `think` per request,
/// so the app never needs a Modelfile.
public struct OllamaClient: LLMClient {
    /// Ollama's root, e.g. http://localhost:11434 (a trailing /v1 is dropped).
    public let baseURL: URL
    public let modelFast: String
    public let modelSmart: String
    public let contextLength: Int
    let session: URLSession
    public var displayName: String { "Ollama · \(modelSmart)" }
    public var billed: Bool { false }
    public var maxRequestTokens: Int? { contextLength }

    /// 16k fits a resume plus a posting; Macs with 8 GB or less get 8k so the model still fits in memory.
    public static func contextLength(ramBytes: UInt64) -> Int { ramBytes <= 8 << 30 ? 8192 : 16384 }

    public init(baseURL: URL = URL(string: "http://localhost:11434")!, modelFast: String, modelSmart: String,
                contextLength: Int = OllamaClient.contextLength(ramBytes: SystemCheck.ramBytes), session: URLSession = .shared) {
        self.baseURL = baseURL.lastPathComponent == "v1" ? baseURL.deletingLastPathComponent() : baseURL
        self.modelFast = modelFast; self.modelSmart = modelSmart; self.contextLength = contextLength; self.session = session
    }

    func request(_ r: LLMRequest, sendThink: Bool = true) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"; req.timeoutInterval = 900
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let system = (r.system.isEmpty ? LLMRequest.defaultSystem : r.system) + (r.cache.isEmpty ? "" : "\n\n" + r.cache)
        var body: [String: Any] = [
            "model": r.smart ? modelSmart : modelFast, "stream": false,
            "options": ["num_ctx": contextLength, "num_predict": r.maxTokens, "temperature": 0.2],
            "messages": [["role": "system", "content": system], ["role": "user", "content": r.prompt]],
        ]
        if sendThink { body["think"] = false }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    public func complete(_ r: LLMRequest) async throws -> LLMResponse {
        try await complete(r, sendThink: true)
    }

    private func complete(_ r: LLMRequest, sendThink: Bool) async throws -> LLMResponse {
        let model = r.smart ? modelSmart : modelFast
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: request(r, sendThink: sendThink)) } catch is CancellationError { throw LLMError.cancelled } catch {
            throw LLMError.unreachable("Can't reach Ollama at \(baseURL.host ?? "localhost"). Is it running? Open Settings → AI to start it.")
        }
        let d = try? JSONDecoder().decode(JSONValue.self, from: data)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let err = d?["error"]?.string ?? ""
        // Older Ollama builds or non-reasoning models may reject the `think` field: retry once without it.
        if code == 400, sendThink, err.lowercased().contains("think") { return try await complete(r, sendThink: false) }
        switch code {
        case 200: break
        case 404: throw LLMError.other("Ollama doesn't have the model \(model). Download it in Settings → AI, then try again.")
        default: throw LLMError.http(code, err.isEmpty ? String(decoding: data, as: UTF8.self) : err)
        }
        guard let d, let content = d["message"]?["content"]?.string else {
            throw LLMError.other("Ollama sent a reply Offerlane couldn't read. Try again; if it keeps happening, choose another AI in Settings → AI.")
        }
        let text = Re.sub("(?s)<think>.*?</think>", "", content).trimmingCharacters(in: .whitespacesAndNewlines)
        return LLMResponse(text: text, usage: LLMUsage(input: Int(d["prompt_eval_count"]?.double ?? 0), output: Int(d["eval_count"]?.double ?? 0)),
                           model: model, usd: 0)
    }
}
