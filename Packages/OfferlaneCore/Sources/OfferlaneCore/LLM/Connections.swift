import Foundation

/// The ordered list of connected AIs (primary first, then fallbacks) as the management page edits it.
extension AppSettings {
    public var connections: [Connection] {
        get { (provider == .none ? [] : [connection]) + fallbacks }
        set {
            connection = newValue.first ?? Connection(provider: .none)
            fallbacks = Array(newValue.dropFirst())
        }
    }

    /// Adds `c` as the last fallback (or the primary when none is connected); a duplicate isn't added twice.
    public mutating func addBackup(_ c: Connection) {
        guard !connections.contains(c) else { return }
        connections.append(c)
    }

    /// Removes the connection at `index`. Returns the keychain account to delete when no remaining connection uses it.
    @discardableResult
    public mutating func removeConnection(at index: Int) -> String? {
        var list = connections
        guard list.indices.contains(index) else { return nil }
        let gone = list.remove(at: index)
        connections = list
        guard let account = gone.keychainAccount, !list.contains(where: { $0.keychainAccount == account }) else { return nil }
        return account
    }
}

extension AppSettings.Connection {
    /// Where this connection's secret lives, if it has one.
    public var keychainAccount: String? {
        switch provider {
        case .anthropic: Keychain.Account.anthropicKey
        case .apiKey: Keychain.Account.provider(providerID)
        default: nil
        }
    }

    /// Short label for the management list ("Ollama · qwen3.5:9b", "gemini · gemini-2.5-flash").
    public var label: String {
        switch provider {
        case .claudeCLI: "Claude Code"
        case .anthropic: "Claude API" + (modelSmart.isEmpty ? "" : " · \(modelSmart)")
        case .ollama: "Ollama · \(modelSmart)"
        case .apiKey: "\((try? ProviderRegistry.load())?.first { $0.id == providerID }?.name ?? providerID) · \(modelSmart)"
        case .none: "None"
        }
    }
}

extension ProviderSetup {
    /// The same strict-JSON test Connect runs, against an already-saved AI. nil = passed; otherwise cause and fix in plain words.
    public static func retest(_ client: any LLMClient) async -> String? {
        do {
            let reply = try await client.complete(testPrompt)
            if (try? AI.decode(reply.text, as: TestReply.self))?.ok == true { return nil }
            return "\(client.displayName) answered, but not with the strict JSON Offerlane needs. Choose a stronger model."
        } catch {
            return error.localizedDescription
        }
    }
}
