import Foundation
import Security
import OSLog

private let logger = Logger(subsystem: "com.bml.claude-code-usage", category: "Credentials")

enum CredentialProvider {
    private static let serviceName = "Claude Code-credentials"

    static func readToken() -> String? {
        logger.debug("Reading credentials from Keychain: service=\(serviceName, privacy: .public)")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            let desc = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            logger.warning("Keychain lookup failed: status=\(status, privacy: .public) error=\(desc, privacy: .public)")
            return nil
        }

        guard let data = result as? Data else {
            logger.error("Keychain returned non-data result")
            return nil
        }

        logger.debug("Keychain data read: bytes=\(data.count, privacy: .public)")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("Keychain data is not a JSON object")
            return nil
        }

        guard let oauth = json["claudeAiOauth"] as? [String: Any] else {
            let keys = Array(json.keys)
            logger.error("Missing claudeAiOauth key: availableKeys=\(keys, privacy: .public)")
            return nil
        }

        guard let token = oauth["accessToken"] as? String else {
            logger.error("Missing accessToken in claudeAiOauth")
            return nil
        }

        let prefix = String(token.prefix(8))
        logger.info("Credentials loaded from Keychain: tokenPrefix=\(prefix, privacy: .public)...")
        return token
    }
}
