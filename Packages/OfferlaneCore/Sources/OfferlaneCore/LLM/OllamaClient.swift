import Foundation

/// Ollama (free, local) or any OpenAI-compatible server, via /v1/chat/completions.
public struct OpenAICompatibleClient: LLMClient {
    public let baseURL: URL
    public let modelFast: String
    public let modelSmart: String
    public let apiKey: String?
    let session: URLSession
    public var displayName: String { "Ollama · \(modelSmart)" }
    public var billed: Bool { false }

    public init(baseURL: URL = URL(string: "http://localhost:11434/v1")!, modelFast: String, modelSmart: String, apiKey: String? = nil,
                session: URLSession = .shared) {
        self.baseURL = baseURL; self.modelFast = modelFast; self.modelSmart = modelSmart; self.apiKey = apiKey; self.session = session
    }

    public func complete(_ r: LLMRequest) async throws -> LLMResponse {
        let model = r.smart ? modelSmart : modelFast
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"; req.timeoutInterval = 900
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let system = (r.system.isEmpty ? LLMRequest.defaultSystem : r.system) + (r.cache.isEmpty ? "" : "\n\n" + r.cache)
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": r.maxTokens, "temperature": 0.2,
            "messages": [["role": "system", "content": system], ["role": "user", "content": r.prompt]],
        ])
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) } catch is CancellationError { throw LLMError.cancelled } catch {
            throw LLMError.unreachable("Can't reach Ollama at \(baseURL.host ?? "localhost"). Is it running? Open Settings → AI to start it.")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LLMError.http(code, String(decoding: data, as: UTF8.self)) }
        let d = try JSONDecoder().decode(JSONValue.self, from: data)
        var text = d["choices"]?.array?.first?["message"]?["content"]?.string ?? ""
        // Reasoning models may prefix their answer with a <think> block.
        text = Re.sub("(?s)<think>.*?</think>", "", text).trimmingCharacters(in: .whitespacesAndNewlines)
        let u = d["usage"]
        return LLMResponse(text: text, usage: LLMUsage(input: Int(u?["prompt_tokens"]?.double ?? 0), output: Int(u?["completion_tokens"]?.double ?? 0)),
                           model: model, usd: 0)
    }
}
