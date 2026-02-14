import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bml.claude-code-usage", category: "Credentials")

enum CredentialProvider {
    private static let serviceName = "Claude Code-credentials"

    static func readToken() -> String? {
        logger.debug("Reading credentials via security CLI: service=\(serviceName, privacy: .public)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", NSUserName(), "-w", "-s", serviceName]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            logger.warning("Failed to launch security CLI: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            logger.warning("security CLI exited: status=\(process.terminationStatus, privacy: .public)")
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            logger.error("security CLI returned empty or non-UTF8 output")
            return nil
        }

        guard let jsonData = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            logger.error("Credential data is not a JSON object")
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
        logger.info("Credentials loaded via security CLI: tokenPrefix=\(prefix, privacy: .public)...")
        return token
    }
}
