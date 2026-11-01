import Foundation

/// Claude Pro/Max through the official Claude Code CLI (consumer subscriptions are only usable via Claude's own apps).
/// Each call runs `claude -p` from an empty temp folder with no tools, MCP servers, settings or session persistence.
public struct ClaudeCLIClient: LLMClient {
    public let executable: URL
    public let modelFast: String
    public let modelSmart: String
    public let timeout: TimeInterval
    public var displayName: String { "Claude (subscription)" }
    public var billed: Bool { false }

    public init(executable: URL, modelFast: String = "haiku", modelSmart: String = "sonnet", timeout: TimeInterval = 900) {
        self.executable = executable; self.modelFast = modelFast; self.modelSmart = modelSmart; self.timeout = timeout
    }

    /// The usual install locations, in order. The official installer puts it in ~/.local/bin.
    public static func locate(extra: String? = nil) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [extra, "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.compactMap { $0 }.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func arguments(model: String, systemFile: URL) -> [String] {
        ["-p", "--output-format", "json", "--model", model, "--tools", "", "--strict-mcp-config", "--setting-sources", "",
         "--no-session-persistence", "--system-prompt-file", systemFile.path]
    }

    public func complete(_ r: LLMRequest) async throws -> LLMResponse {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("offerlane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sys = tmp.appendingPathComponent("system.txt")
        try ((r.system.isEmpty ? LLMRequest.defaultSystem : r.system) + (r.cache.isEmpty ? "" : "\n\n" + r.cache)).write(to: sys, atomically: true, encoding: .utf8)
        let model = r.smart ? modelSmart : modelFast
        let out = try await ProcessRunner.run(executable, arguments(model: model, systemFile: sys), stdin: r.prompt, cwd: tmp, timeout: timeout)
        return try Self.parse(stdout: out.stdout, stderr: out.stderr, model: model)
    }

    /// `--output-format json` prints one JSON object (the last line) with `result`, `is_error` and `usage`.
    public static func parse(stdout: String, stderr: String, model: String) throws -> LLMResponse {
        let line = stdout.split(separator: "\n").last.map(String.init) ?? ""
        guard let d = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), d.object != nil else {
            let msg = (stderr.isEmpty ? stdout : stderr).suffix(300)
            if Re.search("not (logged|signed) in|login|authenticat|credential|/login", String(msg)) {
                throw LLMError.notSignedIn("Claude isn't signed in. Open Settings → AI and click Sign in.")
            }
            throw LLMError.other("Claude Code failed: \(msg)")
        }
        let result = d["result"]?.string ?? ""
        if case .bool(true) = d["is_error"] ?? .null {
            if Re.search("limit|quota|usage", result) { throw LLMError.usageLimit(String(result.prefix(200))) }
            if Re.search("login|auth|credential|token", result) {
                throw LLMError.notSignedIn("Claude isn't signed in (\(result.prefix(120))). Open Settings → AI and click Sign in.")
            }
            throw LLMError.other("Claude Code: \(result.prefix(300))")
        }
        let u = d["usage"]
        let usage = LLMUsage(input: Int(u?["input_tokens"]?.double ?? 0), output: Int(u?["output_tokens"]?.double ?? 0),
                             cacheRead: Int(u?["cache_read_input_tokens"]?.double ?? 0), cacheWrite: Int(u?["cache_creation_input_tokens"]?.double ?? 0))
        return LLMResponse(text: result, usage: usage, model: model, usd: 0)
    }
}

/// Runs a subprocess off the main thread with stdin, a timeout and cancellation.
public enum ProcessRunner {
    public struct Output: Sendable { public var status: Int32; public var stdout: String; public var stderr: String }

    public static func run(_ exe: URL, _ args: [String], stdin: String? = nil, cwd: URL? = nil, env: [String: String]? = nil,
                           timeout: TimeInterval = 300, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> Output {
        let p = Process()
        p.executableURL = exe; p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var environment = ProcessInfo.processInfo.environment
        // GUI apps start with a minimal PATH; the CLI and its installer expect the usual locations.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        for (k, v) in env ?? [:] { environment[k] = v }
        p.environment = environment
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        let outBuf = DataBox(), errBuf = DataBox()
        outPipe.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; outBuf.append(d); onOutput?(String(decoding: d, as: UTF8.self)) }
        errPipe.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; errBuf.append(d); onOutput?(String(decoding: d, as: UTF8.self)) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
                let once = Once()
                p.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil; errPipe.fileHandleForReading.readabilityHandler = nil
                    outBuf.append(outPipe.fileHandleForReading.readDataToEndOfFile()); errBuf.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    once.run { cont.resume(returning: Output(status: proc.terminationStatus, stdout: outBuf.string, stderr: errBuf.string)) }
                }
                do { try p.run() } catch {
                    once.run { cont.resume(throwing: LLMError.notInstalled("Couldn't start \(exe.lastPathComponent): \(error.localizedDescription)")) }
                    return
                }
                if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? inPipe.fileHandleForWriting.close()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning { p.terminate(); once.run { cont.resume(throwing: LLMError.timedOut) } }
                }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }

    final class DataBox: @unchecked Sendable {
        private var data = Data(); private let lock = NSLock()
        func append(_ d: Data) { lock.withLock { data.append(d) } }
        var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
    final class Once: @unchecked Sendable {
        private var done = false; private let lock = NSLock()
        func run(_ f: () -> Void) { let go = lock.withLock { () -> Bool in if done { return false }; done = true; return true }; if go { f() } }
    }
}
