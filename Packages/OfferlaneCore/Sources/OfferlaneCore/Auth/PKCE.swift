import Foundation
import CryptoKit
import Security

/// RFC 7636 Proof Key for Code Exchange, plus the random `state` and `nonce` values an OAuth request carries.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public var method: String { "S256" }

    public init() { self.init(verifier: Base64URL.random(bytes: 64)) }
    /// Deterministic form for tests (RFC 7636 appendix B vector).
    public init(verifier: String) {
        self.verifier = verifier
        challenge = Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

public enum Base64URL {
    public static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
    /// `bytes` from the system CSPRNG, base64url-encoded.
    public static func random(bytes: Int = 32) -> String {
        var d = Data(count: bytes)
        let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        precondition(ok == errSecSuccess, "the system random number generator failed")
        return encode(d)
    }
}

/// Constant-time comparison for secrets (state values, password hashes).
public func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[a.startIndex + i] ^ b[b.startIndex + i] }
    return diff == 0
}
public func constantTimeEquals(_ a: String, _ b: String) -> Bool { constantTimeEquals(Data(a.utf8), Data(b.utf8)) }
