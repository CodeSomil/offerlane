import Foundation
import Security

/// Verifies a downloaded app or binary before Offerlane runs or installs it: it must carry a valid Apple-issued
/// Developer ID signature from the expected publisher (Team ID), with every nested file intact. This does the same
/// check as `codesign --verify --deep --strict -R '<requirement>'`, through the Security framework.
public enum CodeSignature {
    /// Publishers Offerlane installs software from. Read from their current signed releases on 2026-11-01.
    public enum Team {
        public static let anthropic = "Q6L2SF6YDW"   // Claude Code CLI ("Anthropic PBC")
        public static let ollama = "3MU9H2V9Y9"      // Ollama.app ("Infra Technologies, Inc")
    }

    public enum Failure: LocalizedError, Equatable {
        case unsigned
        case invalid(Int32)
        case wrongPublisher(found: String?)

        public var errorDescription: String? {
            switch self {
            case .unsigned: "The download isn't signed by its maker, so Offerlane didn't install it. Try again later."
            case .invalid: "The download's signature is broken (it may have been damaged or changed), so Offerlane didn't install it. Try again."
            case .wrongPublisher: "The download wasn't signed by the company that makes it, so Offerlane didn't install it. Try again later."
            }
        }
    }

    /// Throws unless `url` is validly signed with a Developer ID certificate belonging to `teamID`.
    public static func verify(_ url: URL, teamID: String) throws {
        let requirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(teamID)\""
        do { try verify(url, requirement: requirement) } catch Failure.invalid(let code) where code == Int32(errSecCSReqFailed) {
            throw Failure.wrongPublisher(found: self.teamID(of: url))
        }
    }

    /// Throws unless `url` is validly signed and satisfies a code-signing requirement string.
    public static func verify(_ url: URL, requirement: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { throw Failure.unsigned }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { throw Failure.invalid(-1) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode | (1 << 30) /* kSecCSEnforceRevocationChecks */)
        let status = SecStaticCodeCheckValidity(code, flags, req)
        switch status {
        case errSecSuccess: return
        case errSecCSUnsigned: throw Failure.unsigned
        case errSecCSReqFailed: throw Failure.invalid(status)
        default:
            // A revoked certificate is final. Other failures may just mean the revocation check needed the network
            // (offline): repeat the same check without it.
            if status == errSecCertificateRevoked || status == -2147409652 /* CSSMERR_TP_CERT_REVOKED */ { throw Failure.invalid(status) }
            let offline = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), req)
            if offline == errSecSuccess { Log.info("signature valid; revocation check unavailable (\(status))"); return }
            throw offline == errSecCSUnsigned ? Failure.unsigned : Failure.invalid(offline)
        }
    }

    /// The Team ID a file is signed with, if any.
    public static func teamID(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Lets installer tests swap in a stand-in for the real signature check.
public typealias SignatureCheck = @Sendable (URL, String) throws -> Void
