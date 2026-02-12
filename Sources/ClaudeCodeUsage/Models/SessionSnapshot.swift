import Foundation

struct SessionSnapshot: Codable, Sendable {
    let weeklyUsagePctAtStart: Double
    let weeklyMinsLeftAtStart: Double
    let timestamp: Date
}
