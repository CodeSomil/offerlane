import Foundation

/// Onboarding helpers for "Sign in with your Claude account": find, install and check the Claude Code CLI.
public enum ClaudeSetup {
    public static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

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

    /// Runs the official installer in the background, streaming its output, then verifies the binary.
    public static func install(onOutput: @escaping @Sendable (String) -> Void) async throws -> URL {
        let out = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/bash"), ["-c", installCommand], timeout: 600, onOutput: onOutput)
        guard out.status == 0, let exe = locate(), await version(exe) != nil else {
            throw LLMError.notInstalled("The Claude installer didn't finish (\(out.stderr.suffix(200))). Check your internet connection and try again.")
        }
        return exe
    }

    /// `claude auth status --json`; nil when the CLI can't be run.
    public static func authStatus(_ exe: URL) async -> AuthStatus? {
        guard let out = try? await ProcessRunner.run(exe, ["auth", "status", "--json"], timeout: 30) else { return nil }
        return try? JSONDecoder().decode(AuthStatus.self, from: Data(out.stdout.utf8))
    }
}
