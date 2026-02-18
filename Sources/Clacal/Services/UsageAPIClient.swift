import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bml.clacal", category: "API")

enum APIError: LocalizedError {
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .server(let status, let message):
            return "API \(status): \(message)"
        }
    }
}

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
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorObj = json["error"] as? [String: Any],
               let message = errorObj["message"] as? String {
                throw APIError.server(status: http.statusCode, message: message)
            }
            throw URLError(.badServerResponse)
        }

        let result: UsageLimits
        do {
            result = try JSONDecoder().decode(UsageLimits.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8, \(data.count) bytes>"
            logger.error("JSON decode failed: \(error.localizedDescription, privacy: .public) body=\(body, privacy: .public)")
            throw error
        }
        logger.info("API fetch success: fiveHourUtil=\(result.five_hour?.utilization ?? -1, privacy: .public) sevenDayUtil=\(result.seven_day?.utilization ?? -1, privacy: .public) fiveHourResetsAt=\(result.five_hour?.resets_at ?? "nil", privacy: .public) sevenDayResetsAt=\(result.seven_day?.resets_at ?? "nil", privacy: .public) tier=\(result.rate_limit_tier ?? "nil", privacy: .public)")
        return result
    }
}
