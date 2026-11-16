import Foundation
import Security

/// A Google OpenID Connect ID token: RS256 signature checked against Google's published keys, then every claim checked.
public struct IDToken: Sendable, Equatable {
    public let sub: String
    public let email: String
    public let emailVerified: Bool
    public let name: String
    public let issuedAt: Date
    public let expires: Date

    public static let issuers: Set<String> = ["accounts.google.com", "https://accounts.google.com"]

    public enum Failure: Error, Equatable, LocalizedError {
        case malformed, unsupportedAlgorithm(String), unknownKey, badSignature
        case wrongIssuer, wrongAudience, expired, issuedInFuture, nonceMismatch, emailNotVerified
        public var errorDescription: String? {
            switch self {
            case .emailNotVerified: "Google says this email address isn't verified yet. Verify it with Google, then try again."
            case .expired, .issuedInFuture: "Google's sign-in answer had the wrong time. Check your Mac's date and time, then try again."
            default: "Google's sign-in answer couldn't be verified, so Offerlane didn't use it. Try again."
            }
        }
    }

    /// Verifies `jwt` and returns its identity. `keys` is Google's JWKS document (https://www.googleapis.com/oauth2/v3/certs).
    public static func verify(_ jwt: String, jwks: Data, clientID: String, nonce: String, now: Date = Date(), leeway: TimeInterval = 300) throws -> IDToken {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = Base64URL.decode(parts[0]), let payloadData = Base64URL.decode(parts[1]),
              let sig = Base64URL.decode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { throw Failure.malformed }
        let alg = header["alg"] as? String ?? ""
        guard alg == "RS256" else { throw Failure.unsupportedAlgorithm(alg) }
        guard let kid = header["kid"] as? String, let key = try publicKey(kid: kid, jwks: jwks) else { throw Failure.unknownKey }
        let signed = Data((parts[0] + "." + parts[1]).utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, sig as CFData, nil) else { throw Failure.badSignature }

        guard let iss = claims["iss"] as? String, issuers.contains(iss) else { throw Failure.wrongIssuer }
        let aud = (claims["aud"] as? String).map { [$0] } ?? (claims["aud"] as? [String]) ?? []
        guard aud.contains(clientID) else { throw Failure.wrongAudience }
        if aud.count > 1, (claims["azp"] as? String) != clientID { throw Failure.wrongAudience }
        guard let exp = (claims["exp"] as? NSNumber)?.doubleValue, let iat = (claims["iat"] as? NSNumber)?.doubleValue else { throw Failure.malformed }
        guard now.timeIntervalSince1970 < exp + leeway else { throw Failure.expired }
        guard iat <= now.timeIntervalSince1970 + leeway else { throw Failure.issuedInFuture }
        guard let n = claims["nonce"] as? String, constantTimeEquals(n, nonce) else { throw Failure.nonceMismatch }
        guard let sub = claims["sub"] as? String, !sub.isEmpty else { throw Failure.malformed }
        let verified = (claims["email_verified"] as? Bool) ?? ((claims["email_verified"] as? String) == "true")
        guard verified else { throw Failure.emailNotVerified }
        return IDToken(sub: sub, email: (claims["email"] as? String ?? "").lowercased(), emailVerified: verified,
                       name: claims["name"] as? String ?? "", issuedAt: Date(timeIntervalSince1970: iat), expires: Date(timeIntervalSince1970: exp))
    }

    /// The RSA key with `kid` from a JWKS document.
    static func publicKey(kid: String, jwks: Data) throws -> SecKey? {
        guard let doc = try? JSONSerialization.jsonObject(with: jwks) as? [String: Any], let keys = doc["keys"] as? [[String: Any]] else { throw Failure.malformed }
        guard let jwk = keys.first(where: { ($0["kid"] as? String) == kid && ($0["kty"] as? String) == "RSA" }),
              let n = (jwk["n"] as? String).flatMap(Base64URL.decode), let e = (jwk["e"] as? String).flatMap(Base64URL.decode) else { return nil }
        let der = rsaPublicKeyDER(modulus: n, exponent: e)
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil)
    }

    /// PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
    static func rsaPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        func integer(_ d: Data) -> Data {
            var bytes = [UInt8](d.drop(while: { $0 == 0 }))
            if bytes.first.map({ $0 & 0x80 != 0 }) ?? true { bytes.insert(0, at: 0) }
            return Data([0x02]) + length(bytes.count) + Data(bytes)
        }
        let body = integer(modulus) + integer(exponent)
        return Data([0x30]) + length(body.count) + body
    }
    static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var v = n, out: [UInt8] = []
        while v > 0 { out.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(out.count)] + out)
    }
}
