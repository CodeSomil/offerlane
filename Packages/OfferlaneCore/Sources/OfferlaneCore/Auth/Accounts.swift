import Foundation

/// A local profile. Offerlane has no server: an account is a folder on this Mac plus how its owner signs in.
public struct LocalAccount: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case google, password }
    public var id: String
    public var kind: Kind
    public var email: String
    public var name: String
    public var googleSub: String?
    public var created: String
    public var lastSignIn: String?
    public var touchID = false
    /// This account claimed the v0.1 data, so it keeps the v0.1 browser storage (career-site sign-ins).
    public var claimedLegacy = false
}

/// Who is signed in. Kept in Keychain so it survives restarts and updates, until the user signs out.
public struct Session: Codable, Sendable, Equatable {
    public var accountID: String
    public var since: String
    /// Touch ID is required to reopen this session. Kept here, in Keychain, and not only in accounts.json: editing a
    /// file can't switch the lock off, and the Keychain asks the user before another program may change this item.
    public var touchID: Bool = false

    public init(accountID: String, since: String, touchID: Bool = false) { self.accountID = accountID; self.since = since; self.touchID = touchID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try c.decode(String.self, forKey: .accountID); since = try c.decode(String.self, forKey: .since)
        touchID = (try? c.decodeIfPresent(Bool.self, forKey: .touchID)) ?? false
    }
}

/// accounts.json (no secrets) + the auth Keychain service (password verifiers, Google tokens, the session).
public final class AccountStore: @unchecked Sendable {
    public let base: URL
    public let keychain: Keychain
    private let lock = NSLock()

    public static var authService: String { "com.somilmanke.Offerlane.auth" + Paths.testNamespace }
    struct File: Codable { var accounts: [LocalAccount] = []; var legacyClaimed = false }

    public init(base: URL = Paths.base, keychain: Keychain = Keychain(service: AccountStore.authService)) {
        self.base = base; self.keychain = keychain
    }

    // MARK: registry

    var fileURL: URL { base.appendingPathComponent("accounts.json") }
    func read() -> File { (try? JSONDecoder().decode(File.self, from: Data(contentsOf: fileURL))) ?? File() }
    func write(_ f: File) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(f).write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
    public var accounts: [LocalAccount] { lock.withLock { read().accounts } }
    public func account(_ id: String) -> LocalAccount? { accounts.first { $0.id == id } }
    public func account(email: String, kind: LocalAccount.Kind) -> LocalAccount? {
        accounts.first { $0.kind == kind && $0.email.lowercased() == email.lowercased() }
    }
    public func save(_ a: LocalAccount) throws {
        try lock.withLock {
            var f = read()
            if let i = f.accounts.firstIndex(where: { $0.id == a.id }) { f.accounts[i] = a } else { f.accounts.append(a) }
            try write(f)
        }
    }
    public var legacyClaimed: Bool { lock.withLock { read().legacyClaimed } }
    public func markLegacyClaimed() throws { try lock.withLock { var f = read(); f.legacyClaimed = true; try write(f) } }

    static func newID() -> String { String(Base64URL.random(bytes: 9).lowercased().filter { $0.isLetter || $0.isNumber }.prefix(12)) }

    // MARK: local (email + password) accounts

    public enum AuthFailure: Error, Equatable, LocalizedError {
        case emailTaken, weakPassword(String), unknownEmail, wrongPassword(remaining: Int), locked(until: Date)
        public var errorDescription: String? {
            switch self {
            case .emailTaken: return "There's already a profile for that email on this Mac. Sign in instead."
            case .weakPassword(let why): return why
            case .unknownEmail: return "There's no profile for that email on this Mac. Check the spelling or create one."
            case .wrongPassword(let n): return n > 0 ? "That password isn't right. \(n) more tr\(n == 1 ? "y" : "ies") before a short pause." : "That password isn't right."
            case .locked(let until):
                let s = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
                return "Too many wrong passwords. Try again in \(s < 90 ? "\(s) seconds" : "\(Int((Double(s) / 60).rounded(.up))) minutes")."
            }
        }
    }

    public func createPasswordAccount(email: String, name: String, password: String, iterations: Int = PasswordVerifier.defaultIterations) throws -> LocalAccount {
        let email = email.trimmingCharacters(in: .whitespaces).lowercased()
        if account(email: email, kind: .password) != nil { throw AuthFailure.emailTaken }
        if let p = PasswordStrength.problem(password) { throw AuthFailure.weakPassword(p) }
        let a = LocalAccount(id: Self.newID(), kind: .password, email: email, name: name, created: Dates.now())
        try saveVerifier(PasswordVerifier.make(password, iterations: iterations), for: a.id)
        try save(a)
        return a
    }

    /// Checks the password with lockout. Every attempt costs a full PBKDF2 derivation.
    public func signIn(email: String, password: String, now: Date = Date()) throws -> LocalAccount {
        guard let a = account(email: email.trimmingCharacters(in: .whitespaces), kind: .password), var v = verifier(for: a.id) else {
            // Same work for unknown emails, so timing doesn't reveal which profiles exist.
            _ = PasswordVerifier.derive(password, salt: Data(count: 16), iterations: PasswordVerifier.defaultIterations)
            throw AuthFailure.unknownEmail
        }
        if let until = v.lockedUntil, until > now { throw AuthFailure.locked(until: until) }
        guard v.matches(password) else {
            v.failures += 1
            let wait = Lockout.delay(afterFailures: v.failures)
            v.lockedUntil = wait > 0 ? now.addingTimeInterval(wait) : nil
            try saveVerifier(v, for: a.id)
            if let until = v.lockedUntil { throw AuthFailure.locked(until: until) }
            throw AuthFailure.wrongPassword(remaining: Lockout.freeAttempts - v.failures)
        }
        v.failures = 0; v.lockedUntil = nil
        try saveVerifier(v, for: a.id)
        var signed = a; signed.lastSignIn = Dates.now(); try save(signed)
        return signed
    }

    public func changePassword(_ id: String, to password: String) throws {
        if let p = PasswordStrength.problem(password) { throw AuthFailure.weakPassword(p) }
        try saveVerifier(PasswordVerifier.make(password), for: id)
    }

    func verifier(for id: String) -> PasswordVerifier? {
        keychain.get(account: "pw:\(id)").flatMap { try? JSONDecoder().decode(PasswordVerifier.self, from: Data($0.utf8)) }
    }
    func saveVerifier(_ v: PasswordVerifier, for id: String) throws {
        try keychain.set(String(decoding: try JSONEncoder().encode(v), as: UTF8.self), account: "pw:\(id)")
    }

    // MARK: Google accounts

    /// Finds or creates the profile for a verified Google identity.
    public func googleAccount(for identity: IDToken) throws -> LocalAccount {
        if var a = accounts.first(where: { $0.kind == .google && $0.googleSub == identity.sub }) {
            a.email = identity.email; if !identity.name.isEmpty { a.name = identity.name }
            a.lastSignIn = Dates.now(); try save(a); return a
        }
        let a = LocalAccount(id: Self.newID(), kind: .google, email: identity.email, name: identity.name, googleSub: identity.sub,
                             created: Dates.now(), lastSignIn: Dates.now())
        try save(a); return a
    }

    public func googleTokens(for id: String) -> GoogleTokens? {
        keychain.get(account: "google:\(id)").flatMap { try? JSONDecoder().decode(GoogleTokens.self, from: Data($0.utf8)) }
    }
    public func saveGoogleTokens(_ t: GoogleTokens, for id: String) throws {
        try keychain.set(String(decoding: try JSONEncoder().encode(t), as: UTF8.self), account: "google:\(id)")
    }
    public func deleteGoogleTokens(for id: String) { keychain.delete(account: "google:\(id)") }

    // MARK: session

    public var session: Session? {
        keychain.get(account: "session").flatMap { try? JSONDecoder().decode(Session.self, from: Data($0.utf8)) }
            .flatMap { s in account(s.accountID) == nil ? nil : s }
    }
    public func startSession(_ a: LocalAccount) throws {
        try keychain.set(String(decoding: try JSONEncoder().encode(Session(accountID: a.id, since: Dates.now(), touchID: a.touchID)), as: UTF8.self), account: "session")
    }

    /// Turns the Touch ID requirement on or off for the signed-in session (call only after the user is unlocked).
    public func setSessionTouchID(_ on: Bool) throws {
        guard var s = session else { return }
        s.touchID = on
        try keychain.set(String(decoding: try JSONEncoder().encode(s), as: UTF8.self), account: "session")
    }
    /// Sign out: forget the session and this account's tokens. The account's data stays on disk.
    public func signOut() {
        if let s = session { deleteGoogleTokens(for: s.accountID) }
        keychain.delete(account: "session")
    }

    /// "Forgot password": erase the local profile (folder, its Keychain items, its sign-in record). Data can't be recovered.
    public func erase(_ id: String) throws {
        if session?.accountID == id { keychain.delete(account: "session") }
        // The v0.1 backup holds this profile's old data too.
        if account(id)?.claimedLegacy == true { LegacyData.removeBackups(olderThanDays: 0, base: base) }
        keychain.delete(account: "pw:\(id)"); deleteGoogleTokens(for: id)
        Keychain(service: Paths.keychainService(for: id)).deleteAll()
        try? FileManager.default.removeItem(at: Paths.accountRoot(id, base: base))
        try lock.withLock { var f = read(); f.accounts.removeAll { $0.id == id }; try write(f) }
    }
}
