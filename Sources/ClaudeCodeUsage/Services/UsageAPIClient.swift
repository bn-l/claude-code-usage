import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bml.claude-code-usage", category: "API")

enum UsageAPIClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch(token: String) async throws -> UsageLimits {
        logger.debug("Fetching usage data: endpoint=\(endpoint.absoluteString, privacy: .public)")

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let start = ContinuousClock.now
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsed = ContinuousClock.now - start

        guard let http = response as? HTTPURLResponse else {
            logger.error("Response is not HTTP: type=\(String(describing: type(of: response)), privacy: .public)")
            throw URLError(.badServerResponse)
        }

        logger.debug("API response: status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public) elapsed=\(String(describing: elapsed), privacy: .public)")

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("API error: status=\(http.statusCode, privacy: .public) body=\(body, privacy: .public)")
            throw URLError(.badServerResponse)
        }

        let result = try JSONDecoder().decode(UsageLimits.self, from: data)
        logger.info("API fetch success: fiveHourUtil=\(result.five_hour?.utilization ?? -1, privacy: .public) sevenDayUtil=\(result.seven_day?.utilization ?? -1, privacy: .public) fiveHourResetsAt=\(result.five_hour?.resets_at ?? "nil", privacy: .public) sevenDayResetsAt=\(result.seven_day?.resets_at ?? "nil", privacy: .public) tier=\(result.rate_limit_tier ?? "nil", privacy: .public)")
        return result
    }
}
