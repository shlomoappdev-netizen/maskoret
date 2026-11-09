import Foundation
import CryptoKit
import Security

/// What makes a downloaded update trusted. latest.json alone is not enough: whoever could change the download site
/// could point it at any file with that file's own sha256. So:
///   1. every platform entry carries an Ed25519 signature of its platform, version, build and sha256, made with the
///      owner's release key (tools/manifest_sig.py); the public key is built in here;
///   2. the file comes only from this repository's GitHub releases;
///   3. the Mac app inside the DMG must be signed with the "Maskoret Signing" certificate itself (pinned by hash),
///      and is installed as is — never signed again on this Mac.
enum UpdateTrust {
    static let publicKey = "9W2HCLmnyplrC3gRqnhXipbtU5z5rJJmPLM4xCo96B0="

    /// The leaf certificate of "Maskoret Signing" (SHA-1, as codesign writes it in a designated requirement).
    static let codeRequirement =
        "identifier \"com.shlomodavid.maskoret\" and certificate leaf = H\"556a58571aefeab89e00634d67bce69e77f04297\""

    static func message(platform: String, version: String, build: Int, sha256: String) -> String {
        "maskoret-update-v1\n\(platform)\n\(version)\n\(build)\n\(sha256.lowercased())"
    }

    /// The entry was signed with the release key.
    static func isSigned(platform: String, version: String?, build: Int?, sha256: String, signature: String?,
                         publicKey: String = UpdateTrust.publicKey) -> Bool {
        guard let version, let build, let signature,
              let sig = Data(base64Encoded: signature), sig.count == 64,
              let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        let text = message(platform: platform, version: version, build: build, sha256: sha256)
        return key.isValidSignature(sig, for: Data(text.utf8))
    }

    /// Downloads come only from this repository's releases on GitHub.
    static func isAllowedDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com"
            && url.path.hasPrefix("/shlomoappdev-netizen/maskoret/releases/download/")
    }

    /// The app bundle is intact and signed with the pinned certificate.
    static func isTrustedApp(at url: URL, requirement: String = UpdateTrust.codeRequirement) -> Bool {
        var code: SecStaticCode?
        var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else {
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }
}
