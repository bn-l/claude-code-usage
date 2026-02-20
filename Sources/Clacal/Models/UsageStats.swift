import Foundation

struct UsageStats: Sendable {
    struct WeeklyEntry: Sendable, Identifiable {
        let id = UUID()
        let weekStart: Date
        let utilization: Double
    }

    let avgSessionUsage: Double?
    let hoursToday: Double
    let hoursWeekAvg: Double?
    let hoursAllTimeAvg: Double?
    let weeklyHistory: [WeeklyEntry]
}
