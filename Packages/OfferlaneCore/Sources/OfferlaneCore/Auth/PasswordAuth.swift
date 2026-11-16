import Foundation
import CommonCrypto

/// PBKDF2-HMAC-SHA256 password verifier with a per-user salt, plus failed-attempt lockout with exponential backoff.
public struct PasswordVerifier: Codable, Sendable, Equatable {
    public static let defaultIterations = 600_000
    public var salt: Data
    public var iterations: Int
    public var hash: Data
    public var failures = 0
    public var lockedUntil: Date?

    public static func make(_ password: String, iterations: Int = defaultIterations) -> PasswordVerifier {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return PasswordVerifier(salt: salt, iterations: iterations, hash: derive(password, salt: salt, iterations: iterations))
    }

    public func matches(_ password: String) -> Bool {
        constantTimeEquals(Self.derive(password, salt: salt, iterations: iterations), hash)
    }

    static func derive(_ password: String, salt: Data, iterations: Int) -> Data {
        let pw = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                 s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &out, out.count)
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return Data(out)
    }
}

/// Lockout policy: 5 free tries, then 30 s doubling per further failure, capped at 1 hour.
public enum Lockout {
    public static let freeAttempts = 5
    public static func delay(afterFailures n: Int) -> TimeInterval {
        guard n >= freeAttempts else { return 0 }
        return min(3600, 30 * pow(2, Double(n - freeAttempts)))
    }
}

/// A plain-English password strength estimate for the meter (0 weak … 4 strong).
public enum PasswordStrength {
    public static let minimumLength = 10
    static let common: Set<String> = ["password", "password1", "123456789", "1234567890", "qwertyuiop", "iloveyou", "letmein123",
                                      "welcome123", "admin12345", "offerlane", "passw0rd", "abc123456", "11111111", "football"]

    public static func score(_ p: String) -> Int {
        guard !p.isEmpty else { return 0 }
        let lower = p.lowercased()
        if common.contains(lower) || Set(p).count <= 2 { return 0 }
        var classes = 0
        if p.rangeOfCharacter(from: .lowercaseLetters) != nil { classes += 1 }
        if p.rangeOfCharacter(from: .uppercaseLetters) != nil { classes += 1 }
        if p.rangeOfCharacter(from: .decimalDigits) != nil { classes += 1 }
        if p.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil { classes += 1 }
        var s = 0
        if p.count >= minimumLength { s += 1 }
        if p.count >= 14 { s += 1 }
        if classes >= 3 { s += 1 }
        if p.count >= 18 || (p.count >= 12 && classes == 4) { s += 1 }
        if p.count < 8 { s = min(s, 1) }
        return min(4, s)
    }
    public static func label(_ score: Int) -> String { ["Too weak", "Weak", "Okay", "Good", "Strong"][max(0, min(4, score))] }
    /// Nil when acceptable; otherwise what to change.
    public static func problem(_ p: String) -> String? {
        if p.count < minimumLength { return "Use at least \(minimumLength) characters." }
        if score(p) < 2 { return "Add more words, or mix in capitals, numbers or symbols." }
        return nil
    }
}
