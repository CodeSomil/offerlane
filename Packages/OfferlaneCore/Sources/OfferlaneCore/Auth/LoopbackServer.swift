import Foundation
import Network

/// One-shot HTTP listener on 127.0.0.1 (random port) that receives the OAuth redirect from the browser.
/// It binds to the loopback interface only, answers exactly one `/callback` request, then stops.
public final class LoopbackServer: @unchecked Sendable {
    public private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "offerlane.oauth.loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    public enum Failure: Error, LocalizedError {
        case couldNotListen, timedOut, cancelled
        public var errorDescription: String? {
            switch self {
            case .couldNotListen: "Offerlane couldn't receive the sign-in answer on this Mac. Try again."
            case .timedOut: "Sign-in took too long, so Offerlane stopped waiting. Try again."
            case .cancelled: "Sign-in was cancelled."
            }
        }
    }

    public init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        guard let l = try? NWListener(using: params) else { throw Failure.couldNotListen }
        listener = l
    }

    /// Starts listening and returns the redirect URI to give the provider. `host` only names the loopback address
    /// in that URI (some providers accept only "localhost"); the listener stays on 127.0.0.1.
    public func start(host: String = "127.0.0.1") async throws -> URL {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            // State updates arrive on `queue` (serial), so this flag is only touched there.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !once.done else { return }
                switch state {
                case .ready: once.done = true; self.port = self.listener.port?.rawValue ?? 0; c.resume()
                case .failed, .cancelled: once.done = true; c.resume(throwing: Failure.couldNotListen)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
        }
        return URL(string: "http://\(host):\(port)/callback")!
    }

    /// Waits for the browser's redirect; returns its query parameters.
    public func waitForCallback(timeout: TimeInterval = 300) async throws -> [String: String] {
        let timer = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            self?.finish(.failure(Failure.timedOut))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                lock.lock()
                if let result { lock.unlock(); c.resume(with: result); return }
                continuation = c; lock.unlock()
            }
        } onCancel: { [weak self] in self?.finish(.failure(Failure.cancelled)) }
    }

    public func stop() { listener.cancel() }

    private func finish(_ r: Result<[String: String], Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r; let c = continuation; continuation = nil
        lock.unlock()
        c?.resume(with: r)
        listener.cancel()
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let line = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET", let comps = URLComponents(string: String(parts[1])), comps.path == "/callback" else {
                self.respond(conn, status: "404 Not Found", body: "Not found"); return
            }
            var q: [String: String] = [:]
            for item in comps.queryItems ?? [] { q[item.name] = item.value ?? "" }
            let ok = q["error"] == nil
            self.respond(conn, status: "200 OK", body: Self.page(ok: ok))
            self.finish(.success(q))
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\n\r\n"
        conn.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in conn.cancel() })
    }

    static func page(ok: Bool) -> String {
        let title = ok ? "You're signed in" : "Sign-in didn't finish"
        let text = ok ? "You can close this tab and go back to Offerlane." : "Go back to Offerlane and try again."
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Offerlane</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;display:grid;place-items:center;height:100vh;margin:0;background:#F5F5FA;color:#111827}
        main{text-align:center}h1{font-size:24px;margin:0 0 8px}p{color:#4B5563}</style></head>
        <body><main><h1>\(title)</h1><p>\(text)</p></main></body></html>
        """
    }
}
