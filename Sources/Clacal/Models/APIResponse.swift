import Foundation

struct UsageWindow: Codable, Sendable {
    let utilization: Double
    let resets_at: String?
}

struct UsageLimits: Codable, Sendable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let rate_limit_tier: String?
}
