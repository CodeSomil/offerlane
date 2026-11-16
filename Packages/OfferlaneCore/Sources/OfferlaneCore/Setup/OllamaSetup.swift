import Foundation

/// Onboarding helpers for Ollama: detect, install (with consent), download a model with real progress, smoke test,
/// remove a model, uninstall.
public struct OllamaSetup: Sendable {
    public let baseURL: URL
    let session: URLSession
    public init(baseURL: URL = URL(string: "http://localhost:11434")!, session: URLSession = .shared) {
        self.baseURL = baseURL; self.session = session
    }

    /// Where Offerlane installs Ollama: /Applications, or ~/Applications when this user can't write there.
    public static var installFolders: [URL] {
        [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }
    public static var appURL: URL {
        installFolders.map { $0.appendingPathComponent("Ollama.app") }.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? URL(fileURLWithPath: "/Applications/Ollama.app")
    }
    /// Official releases (ollama.com/download redirects here). Each release lists SHA-256 checksums in sha256sum.txt.
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/ollama/ollama/releases/latest")!
    public static func assetURL(tag: String, file: String) -> URL {
        URL(string: "https://github.com/ollama/ollama/releases/download/\(tag)/\(file)")!
    }
    public static let archiveName = "Ollama-darwin.zip"

    public struct ModelChoice: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public let name: String
        public let sizeGB: Double
        public let note: String
        public var sizeBytes: Int64 { Int64(sizeGB * 1_000_000_000) }
    }

    /// Instruction-tuned models with reliable JSON output, by RAM (8 GB → small, 16 GB → medium, 32 GB+ → large).
    public static let choices: [ModelChoice] = [
        // Checked against ollama.com/library on 2026-10-31 (qwen3.5 is the current Qwen family).
        ModelChoice(name: "qwen3.5:4b", sizeGB: 3.3, note: "Small · for 8 GB Macs"),
        ModelChoice(name: "qwen3.5:9b", sizeGB: 6.6, note: "Medium · for 16 GB Macs"),
        ModelChoice(name: "qwen3.5:27b", sizeGB: 17, note: "Large · for 32 GB+ Macs"),
    ]
    /// Space to keep free beyond the model itself.
    public static let diskMargin: Int64 = 5_000_000_000

    /// The biggest model this Mac's memory can run that also fits on its disk (smallest if none fits).
    public static func recommended(ramBytes: UInt64 = SystemCheck.ramBytes, freeDisk: Int64? = nil) -> ModelChoice {
        let gb = Double(ramBytes) / 1_073_741_824
        let byRAM = gb >= 30 ? 2 : gb >= 15 ? 1 : 0
        guard let freeDisk else { return choices[byRAM] }
        return choices[...byRAM].last { $0.sizeBytes + diskMargin <= freeDisk } ?? choices[0]
    }
    public static func fits(_ c: ModelChoice, freeDisk: Int64) -> Bool { c.sizeBytes + diskMargin <= freeDisk }

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
        throw LLMError.unreachable("Ollama didn't start. Click Start Ollama to try again, or restart your Mac.")
    }

    public enum InstallPhase: Sendable, Equatable { case checking, downloading(Double), verifying, installing, starting }

    /// Installs the official Ollama release. Nothing is opened or copied until it has passed both checks:
    /// SHA-256 against the release's sha256sum.txt, then the code signature (Ollama's Team ID).
    /// The caller must have asked the user first.
    public static func install(downloader: SafeDownloader = SafeDownloader(),
                               folders: [URL] = OllamaSetup.installFolders,
                               verifySignature: SignatureCheck = { try CodeSignature.verify($0, teamID: $1) },
                               launch: @Sendable () async throws -> Void = { try await OllamaSetup().launch() },
                               phase: @escaping @Sendable (InstallPhase) -> Void = { _ in }) async throws -> URL {
        phase(.checking)
        let tag = try await latestTag(downloader: downloader)
        let sums = try await downloader.data(assetURL(tag: tag, file: "sha256sum.txt"), maxBytes: 64 << 10)
        guard let sha = checksum(in: String(decoding: sums, as: UTF8.self), for: archiveName) else {
            throw LLMError.unreachable("Ollama's download couldn't be checked right now, so it wasn't installed. Try again later.")
        }
        let zip = try await downloader.download(assetURL(tag: tag, file: archiveName), name: "Ollama-\(tag).zip", sha256: sha) { done, total in
            phase(.downloading(total > 0 ? Double(done) / Double(total) : 0))
        }
        defer { try? FileManager.default.removeItem(at: zip) }

        phase(.verifying)
        let unpacked = downloader.directory.appendingPathComponent("ollama-unpacked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
        let x = try await ProcessRunner.run(ditto, ["-x", "-k", zip.path, unpacked.path], timeout: 300)
        let app = unpacked.appendingPathComponent("Ollama.app")
        guard x.status == 0, FileManager.default.fileExists(atPath: app.path) else {
            throw LLMError.other("The Ollama download couldn't be opened. Try again.")
        }
        try verifySignature(app, CodeSignature.Team.ollama)

        phase(.installing)
        let fm = FileManager.default
        guard let folder = folders.first(where: { (try? fm.createDirectory(at: $0, withIntermediateDirectories: true)) != nil && fm.isWritableFile(atPath: $0.path) }) else {
            throw LLMError.other("Offerlane can't write to your Applications folder. Ask the Mac's administrator to install Ollama, or choose another AI.")
        }
        let dest = folder.appendingPathComponent("Ollama.app")
        if fm.fileExists(atPath: dest.path) { try? fm.trashItem(at: dest, resultingItemURL: nil) }
        let copy = try await ProcessRunner.run(ditto, [app.path, dest.path], timeout: 300)
        guard copy.status == 0 else { throw LLMError.other("Ollama couldn't be copied to Applications. Check there's free space, then try again.") }
        try verifySignature(dest, CodeSignature.Team.ollama)   // the copy is what will run

        phase(.starting)
        try await launch()
        return dest
    }

    static func latestTag(downloader: SafeDownloader) async throws -> String {
        let data = try await downloader.data(latestReleaseAPI, maxBytes: 2 << 20)
        guard let tag = (try? JSONDecoder().decode(JSONValue.self, from: data))?["tag_name"]?.string,
              tag.range(of: #"^v?\d+\.\d+\.\d+[0-9A-Za-z.\-]*$"#, options: .regularExpression) != nil else {
            throw LLMError.unreachable("Couldn't find the latest Ollama release. Try again later.")
        }
        return tag
    }

    /// Finds a file's checksum in `sha256sum` output ("<hex>  ./name" lines).
    public static func checksum(in sums: String, for file: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let name = parts[1].hasPrefix("./") ? String(parts[1].dropFirst(2)) : String(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")))
            let hex = parts[0].lowercased()
            if name == file, hex.count == 64, hex.allSatisfy(\.isHexDigit) { return hex }
        }
        return nil
    }

    /// Streams /api/pull. `progress(fraction, status)` is called as layers download.
    /// Ollama keeps finished parts, so pulling again after a cancel continues where it stopped.
    public func pull(_ model: String, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        var r = URLRequest(url: baseURL.appendingPathComponent("api/pull")); r.httpMethod = "POST"; r.timeoutInterval = 3600
        r.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, resp) = try await session.bytes(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LLMError.unreachable("Ollama didn't accept the download. Click Start Ollama, then try again.") }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let d = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
            if let e = d["error"]?.string { throw LLMError.other(Self.friendly(e)) }
            let status = d["status"]?.string ?? ""
            if let total = d["total"]?.double, total > 0, let done = d["completed"]?.double { progress(done / total, status) }
            else { progress(status == "success" ? 1 : -1, status) }
            if status == "success" { return }
        }
    }

    static func friendly(_ ollamaError: String) -> String {
        let e = ollamaError.lowercased()
        if e.contains("no space") || e.contains("disk") { return "Your Mac ran out of space while downloading the model. Free some space, then try again." }
        if e.contains("not found") || e.contains("file does not exist") { return "That model isn't available from Ollama right now. Pick another one, then try again." }
        if e.contains("connection") || e.contains("dial tcp") || e.contains("timeout") { return "The model download lost its connection. Try again; it continues where it left off." }
        return "Ollama couldn't download the model. Try again."
    }

    /// Deletes a downloaded model to free its disk space.
    public func deleteModel(_ model: String) async throws {
        var r = URLRequest(url: baseURL.appendingPathComponent("api/delete")); r.httpMethod = "DELETE"; r.timeoutInterval = 60
        r.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
        let (_, resp) = try await session.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 404 else { throw LLMError.other("Ollama couldn't remove \(model). Make sure Ollama is running, then try again.") }
    }

    /// Size of Ollama's model folder (~/.ollama/models).
    public static var modelsFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models") }

    /// Quits Ollama and moves Ollama.app (and, if asked, its downloaded models) to the Trash, so it can be undone.
    public static func uninstall(removeModels: Bool) async throws {
        for name in ["Ollama", "ollama"] { _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/killall"), ["-TERM", name], timeout: 10) }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let fm = FileManager.default
        for folder in installFolders {
            let app = folder.appendingPathComponent("Ollama.app")
            if fm.fileExists(atPath: app.path) {
                do { try fm.trashItem(at: app, resultingItemURL: nil) }
                catch { throw LLMError.other("Ollama couldn't be moved to the Trash. Quit Ollama from the menu bar, then try again.") }
            }
        }
        // The command-line link Ollama adds points into the app; remove it if it's now dangling and ours to remove.
        let link = "/usr/local/bin/ollama"
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link), dest.contains("Ollama.app"), !fm.fileExists(atPath: dest) { try? fm.removeItem(atPath: link) }
        if removeModels, fm.fileExists(atPath: modelsFolder.path) { try? fm.trashItem(at: modelsFolder, resultingItemURL: nil) }
    }

    /// One JSON call with the same settings real runs use.
    public func smokeTest(model: String) async throws -> TimeInterval {
        let t0 = Date()
        let client = OllamaClient(baseURL: baseURL, modelFast: model, modelSmart: model, session: session)
        struct OK: Decodable { var ok: Bool }
        let ok: OK = try await AI(client: client, store: nil).json(LLMRequest(prompt: "Reply with exactly {\"ok\": true}", maxTokens: 400))
        guard ok.ok else { throw LLMError.badJSON("ok was false") }
        return Date().timeIntervalSince(t0)
    }
}
