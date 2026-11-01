import Foundation

/// Onboarding helpers for Ollama: detect, install (with consent), download a model with real progress, smoke test.
public struct OllamaSetup: Sendable {
    public let baseURL: URL
    let session: URLSession
    public init(baseURL: URL = URL(string: "http://localhost:11434")!, session: URLSession = .shared) {
        self.baseURL = baseURL; self.session = session
    }

    public static let appURL = URL(fileURLWithPath: "/Applications/Ollama.app")
    public static let downloadURL = URL(string: "https://ollama.com/download/Ollama.dmg")!

    public struct ModelChoice: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public let name: String
        public let sizeGB: Double
        public let note: String
    }

    /// Instruction-tuned models with reliable JSON output, by RAM (8 GB → small, 16 GB → medium, 32 GB+ → large).
    public static let choices: [ModelChoice] = [
        // Checked against ollama.com/library on 2026-10-31 (qwen3.5 is the current Qwen family).
        ModelChoice(name: "qwen3.5:4b", sizeGB: 3.3, note: "Small · for 8 GB Macs"),
        ModelChoice(name: "qwen3.5:9b", sizeGB: 6.6, note: "Medium · for 16 GB Macs"),
        ModelChoice(name: "qwen3.5:27b", sizeGB: 17, note: "Large · for 32 GB+ Macs"),
    ]
    public static func recommended(ramBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> ModelChoice {
        let gb = Double(ramBytes) / 1_073_741_824
        return gb >= 30 ? choices[2] : gb >= 15 ? choices[1] : choices[0]
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.appURL.path)
            || ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func isRunning() async -> Bool {
        var r = URLRequest(url: baseURL.appendingPathComponent("api/version")); r.timeoutInterval = 3
        return ((try? await session.data(for: r))?.1 as? HTTPURLResponse)?.statusCode == 200
    }

    public func models() async throws -> [String] {
        let (data, _) = try await session.data(from: baseURL.appendingPathComponent("api/tags"))
        return (try JSONDecoder().decode(JSONValue.self, from: data))["models"]?.array?.compactMap { $0["name"]?.string } ?? []
    }

    /// Opens Ollama.app and waits up to 30 s for its API.
    public func launch() async throws {
        _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/open"), ["-a", Self.appURL.path], timeout: 20)
        for _ in 0..<30 { if await isRunning() { return }; try await Task.sleep(nanoseconds: 1_000_000_000) }
        throw LLMError.unreachable("Ollama didn't start. Open Ollama from your Applications folder, then try again.")
    }

    /// Downloads the official macOS build, copies Ollama.app into /Applications and launches it.
    /// The caller must have asked the user first.
    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        let dmg = try await Download.file(Self.downloadURL, session: session, progress: progress)
        defer { try? FileManager.default.removeItem(at: dmg) }
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("ollama-\(UUID().uuidString)")
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        let attach = try await ProcessRunner.run(hdiutil, ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path], timeout: 120)
        guard attach.status == 0 else { throw LLMError.other("Couldn't open the Ollama download (\(attach.stderr.prefix(160))).") }
        defer { Task { _ = try? await ProcessRunner.run(hdiutil, ["detach", mount.path, "-force"], timeout: 60) } }
        let app = mount.appendingPathComponent("Ollama.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw LLMError.other("The Ollama download didn't contain Ollama.app.") }
        let copy = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), [app.path, Self.appURL.path], timeout: 300)
        guard copy.status == 0 else { throw LLMError.other("Couldn't copy Ollama to Applications (\(copy.stderr.prefix(160))).") }
        try await launch()
    }

    /// Streams /api/pull. `progress(fraction, status)` is called as layers download.
    public func pull(_ model: String, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        var r = URLRequest(url: baseURL.appendingPathComponent("api/pull")); r.httpMethod = "POST"; r.timeoutInterval = 3600
        r.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, resp) = try await session.bytes(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LLMError.unreachable("Ollama refused the download. Is it running?") }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let d = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
            if let e = d["error"]?.string { throw LLMError.other("Ollama: \(e)") }
            let status = d["status"]?.string ?? ""
            if let total = d["total"]?.double, total > 0, let done = d["completed"]?.double { progress(done / total, status) }
            else { progress(status == "success" ? 1 : -1, status) }
            if status == "success" { return }
        }
    }

    /// One JSON call through the OpenAI-compatible endpoint.
    public func smokeTest(model: String) async throws -> TimeInterval {
        let t0 = Date()
        let client = OpenAICompatibleClient(baseURL: baseURL.appendingPathComponent("v1"), modelFast: model, modelSmart: model, session: session)
        struct OK: Decodable { var ok: Bool }
        let ok: OK = try await AI(client: client, store: nil).json(LLMRequest(prompt: "Reply with exactly {\"ok\": true}", maxTokens: 400))
        guard ok.ok else { throw LLMError.badJSON("ok was false") }
        return Date().timeIntervalSince(t0)
    }
}

/// URLSession download with byte progress.
public enum Download {
    public static func file(_ url: URL, session: URLSession = .shared, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (bytes, resp) = try await session.bytes(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LLMError.unreachable("Download failed (\(url.host ?? "")).") }
        let total = Double(resp.expectedContentLength)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let h = try FileHandle(forWritingTo: dest); defer { try? h.close() }
        var buf = Data(); buf.reserveCapacity(1 << 20); var done = 0.0, lastReport = 0.0
        for try await b in bytes {
            buf.append(b)
            if buf.count >= 1 << 20 {
                try Task.checkCancellation()
                h.write(buf); done += Double(buf.count); buf.removeAll(keepingCapacity: true)
                if total > 0, done / total - lastReport > 0.01 { lastReport = done / total; progress(lastReport) }
            }
        }
        h.write(buf); progress(1); return dest
    }
}
