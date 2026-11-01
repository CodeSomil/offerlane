import Foundation

/// Polite HTTP for career-site APIs: a Safari user agent, at most one request per host every 0.35 s,
/// 429 honoured with back-off (Retry-After when given), and one retry on network errors.
public actor HTTP {
    public static let shared = HTTP()
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    let session: URLSession
    let minInterval: TimeInterval
    private var nextSlot: [String: Date] = [:]

    public init(session: URLSession = .shared, minInterval: TimeInterval = 0.35) { self.session = session; self.minInterval = minInterval }

    public struct Response: Sendable {
        public let status: Int
        public let data: Data
        public var json: JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: data) }
    }

    public func get(_ url: URL) async -> Response? { await send(URLRequest(url: url)) }

    public func postJSON(_ url: URL, _ body: [String: Any]) async -> Response? {
        var r = URLRequest(url: url); r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await send(r)
    }

    private func waitTurn(_ host: String) async {
        let now = Date(), slot = max(now, nextSlot[host] ?? now)
        nextSlot[host] = slot.addingTimeInterval(minInterval)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
    }

    func send(_ request: URLRequest) async -> Response? {
        var req = request
        req.timeoutInterval = 25
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/html;q=0.9", forHTTPHeaderField: "Accept")
        let host = req.url?.host ?? ""
        for attempt in 0..<3 {
            if Task.isCancelled { return nil }
            await waitTurn(host)
            do {
                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 429 && attempt < 2 {
                    let after = Double((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(5 * (attempt + 1))
                    nextSlot[host] = Date().addingTimeInterval(min(after, 30))
                    continue
                }
                return Response(status: code, data: data)
            } catch {
                if Task.isCancelled || attempt >= 1 { Log.info("GET \(host) failed: \(error.localizedDescription)"); return nil }
                try? await Task.sleep(nanoseconds: UInt64((1 + Double.random(in: 0...1)) * 1e9))
            }
        }
        return nil
    }
}
