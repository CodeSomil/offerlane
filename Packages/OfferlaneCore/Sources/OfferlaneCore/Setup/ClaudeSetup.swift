import Foundation

/// Onboarding helpers for "Sign in with your Claude account": find, install and check the Claude Code CLI.
public enum ClaudeSetup {
    public static let releasesURL = URL(string: "https://downloads.claude.ai/claude-code-releases")!

    public struct AuthStatus: Decodable, Sendable, Equatable {
        public var loggedIn: Bool
        public var subscriptionType: String?
        public var authMethod: String?
        /// "Claude Pro", "Claude Max", or a neutral fallback.
        public var planName: String {
            guard let s = subscriptionType, !s.isEmpty else { return "your Claude account" }
            return "Claude " + s.prefix(1).uppercased() + s.dropFirst()
        }
    }

    public static func locate(_ saved: String? = nil) -> URL? { ClaudeCLIClient.locate(extra: saved) }

    public static func version(_ exe: URL) async -> String? {
        guard let out = try? await ProcessRunner.run(exe, ["--version"], timeout: 20), out.status == 0 else { return nil }
        // "2.1.316 (Claude Code)" -> "2.1.316"
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " (Claude Code)", with: "")
    }

    /// `claude auth status --json`; nil when the CLI can't be run.
    public static func authStatus(_ exe: URL) async -> AuthStatus? {
        guard let out = try? await ProcessRunner.run(exe, ["auth", "status", "--json"], timeout: 30) else { return nil }
        return try? JSONDecoder().decode(AuthStatus.self, from: Data(out.stdout.utf8))
    }

    /// One platform's entry in the release manifest.
    public struct Release: Sendable, Equatable {
        public var version: String
        public var platform: String
        public var sha256: String
        public var size: Int64
    }

    public enum Phase: Sendable, Equatable { case checking, downloading(Double), verifying, installing }

    /// Installs Claude Code the way its official installer does, but every step is checked before anything runs:
    /// 1. read the latest version and its manifest from downloads.claude.ai;
    /// 2. download the binary for this Mac (resumable), and keep it only if its SHA-256 matches the manifest;
    /// 3. check its code signature belongs to Anthropic (Team ID);
    /// 4. only then run `claude install`, which puts it in ~/.local/bin; the downloaded copy is then deleted.
    public static func install(downloader: SafeDownloader = SafeDownloader(),
                               platform: String = SystemCheck.claudePlatform,
                               verifySignature: SignatureCheck = { try CodeSignature.verify($0, teamID: $1) },
                               locate: @Sendable () -> URL? = { ClaudeSetup.locate() },
                               phase: @escaping @Sendable (Phase) -> Void = { _ in },
                               onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        phase(.checking)
        let release = try await latestRelease(downloader: downloader, platform: platform)
        let binary = try await downloader.download(
            releasesURL.appendingPathComponent("\(release.version)/\(release.platform)/claude"),
            name: "claude-\(release.version)-\(release.platform)", sha256: release.sha256, expectedSize: release.size > 0 ? release.size : nil
        ) { done, total in phase(.downloading(total > 0 ? Double(done) / Double(total) : 0)) }
        defer { try? FileManager.default.removeItem(at: binary) }
        phase(.verifying)
        try verifySignature(binary, CodeSignature.Team.anthropic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        phase(.installing)
        let out = try await ProcessRunner.run(binary, ["install"], timeout: 600, onOutput: onOutput)
        guard out.status == 0, let exe = locate() else {
            throw LLMError.notInstalled("Claude Code couldn't finish setting itself up. Try again; if it keeps happening, restart your Mac and try once more.")
        }
        return exe
    }

    /// Latest version + this platform's checksum and size from the official manifest.
    public static func latestRelease(downloader: SafeDownloader, platform: String) async throws -> Release {
        let raw = String(decoding: try await downloader.data(releasesURL.appendingPathComponent("latest"), maxBytes: 256), as: UTF8.self)
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.range(of: #"^\d+\.\d+\.\d+[0-9A-Za-z.\-]*$"#, options: .regularExpression) != nil else {
            throw LLMError.unreachable("Claude's download service didn't answer properly. It may not be available in your region, or your network is blocking it. Try again later.")
        }
        let manifest = try await downloader.data(releasesURL.appendingPathComponent("\(version)/manifest.json"), maxBytes: 1 << 20)
        return try parseManifest(manifest, version: version, platform: platform)
    }

    public static func parseManifest(_ data: Data, version: String, platform: String) throws -> Release {
        struct Manifest: Decodable {
            struct P: Decodable { var checksum: String; var size: Int64? }
            var version: String?
            var platforms: [String: P]
        }
        guard let m = try? JSONDecoder().decode(Manifest.self, from: data), let p = m.platforms[platform],
              p.checksum.count == 64, p.checksum.allSatisfy(\.isHexDigit), m.version == nil || m.version == version else {
            throw LLMError.unreachable("Claude Code isn't available for this Mac right now. Try again later, or choose another AI.")
        }
        return Release(version: version, platform: platform, sha256: p.checksum.lowercased(), size: p.size ?? 0)
    }
}
