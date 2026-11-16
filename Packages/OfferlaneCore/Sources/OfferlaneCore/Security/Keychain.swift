import Foundation
import Security

/// Thin wrapper over generic-password Keychain items. Every secret the app holds lives here, never in files.
public struct Keychain: Sendable {
    public let service: String
    public let protection: Protection
    public init(service: String = "com.somilmanke.Offerlane", protection: Protection = .login) { self.service = service; self.protection = protection }

    /// Where items live. Only `.login` works today: the other two need the app signed with a Developer ID
    /// (keychain-access-groups entitlement); without it macOS returns errSecMissingEntitlement (-34018).
    // SHORTCUT: `.dataProtection`/`.biometric` are prepared and unit-tested by their queries only; switch the database key
    // to them (with a one-time move from `.login`) once the Developer ID exists (HUMAN BLOCKER).
    public enum Protection: Sendable { case login, dataProtection, biometric }

    /// The query every call starts from: class, service, account and the protection's own attributes.
    func base(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if protection != .login { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }
    /// Attributes for a new item: device-only always; Touch ID (current enrolment) for `.biometric`.
    func addAttributes() -> [String: Any] {
        guard protection == .biometric,
              let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, nil)
        else { return [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] }
        return [kSecAttrAccessControl as String: ac]
    }

    public enum Account {
        public static let anthropicKey = "anthropic-api-key"
        /// API key for a registry provider (ProviderSpec.id).
        public static func provider(_ id: String) -> String { "provider:\(id)" }
        public static func imap(_ user: String) -> String { "imap:\(user.lowercased())" }
        public static func site(host: String, email: String) -> String { "site:\(host.lowercased())|\(email.lowercased())" }
    }

    public func set(_ value: String, account: String) throws {
        let base = base(account)
        let data = Data(value.utf8)
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base.merging(addAttributes()) { $1 }; add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func add(_ value: String, account: String) throws {
        var add = base(account).merging(addAttributes()) { $1 }; add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func get(account: String) -> String? {
        let q = base(account).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    /// Account names of every item in this service.
    public func allAccounts() -> [String] {
        var q = base("")
        q[kSecAttrAccount as String] = nil; q[kSecReturnAttributes as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Copies every item from this service into `other` (used when v0.1 data moves into an account).
    public func copyAll(to other: Keychain) throws -> Int {
        var n = 0
        for a in allAccounts() { if let v = get(account: a) { try other.set(v, account: a); n += 1 } }
        return n
    }

    /// Removes every item this app stored (Settings → Delete all my data).
    public func deleteAll() {
        var q = base(""); q[kSecAttrAccount as String] = nil
        SecItemDelete(q as CFDictionary)
    }

    /// An 18-character password with lower, upper, digit and symbol, from the system CSPRNG.
    public static func strongPassword(length: Int = 18) -> String {
        let lower = Array("abcdefghijkmnopqrstuvwxyz"), upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), digits = Array("23456789"), sym = Array("!@#$%*?")
        let all = lower + upper + digits + sym
        func pick(_ set: [Character]) -> Character {
            var b: UInt32 = 0; _ = SecRandomCopyBytes(kSecRandomDefault, 4, &b); return set[Int(b % UInt32(set.count))]
        }
        while true {
            let p = String((0..<length).map { _ in pick(all) })
            if p.contains(where: lower.contains), p.contains(where: upper.contains), p.contains(where: digits.contains), p.contains(where: sym.contains) { return p }
        }
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
}

/// Career-site accounts: approval per company in the database, passwords in Keychain.
public struct Vault: Sendable {
    public let store: Store
    public let keychain: Keychain
    public init(store: Store, keychain: Keychain = Keychain()) { self.store = store; self.keychain = keychain }

    /// Approval is per company: one Workday host can serve several employers.
    public func isApproved(host: String, company: String) -> Bool {
        guard let a = try? store.account(host: host) else { return false }
        return a.approved && a.company.lowercased() == company.lowercased()
    }
    public func approve(host: String, company: String, email: String) throws {
        var a = (try store.account(host: host)) ?? SiteAccount(host: host, company: company, email: email)
        a.company = company; a.email = email; a.approved = true; a.approvedAt = Dates.now()
        try store.saveAccount(a)
    }
    /// Save the generated password BEFORE the agent clicks Create, so it is never lost.
    public func save(host: String, company: String, email: String, password: String) throws {
        try keychain.set(password, account: Keychain.Account.site(host: host, email: email))
        var a = (try store.account(host: host)) ?? SiteAccount(host: host, company: company, email: email)
        a.company = company; a.email = email; a.approved = true; a.created = Dates.now()
        try store.saveAccount(a)
    }
    public func password(host: String) -> String? {
        guard let a = try? store.account(host: host) else { return nil }
        return keychain.get(account: Keychain.Account.site(host: host, email: a.email))
    }
    public func forget(host: String) throws {
        if let a = try store.account(host: host) { keychain.delete(account: Keychain.Account.site(host: host, email: a.email)) }
        try store.deleteAccount(host: host)
    }
}
