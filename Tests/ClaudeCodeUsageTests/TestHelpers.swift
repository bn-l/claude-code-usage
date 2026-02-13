import Foundation
@testable import ClaudeCodeUsage

/// Create an in-memory UsageOptimiser with no disk persistence.
@MainActor
func makeTestOptimiser(
    data: StoreData = StoreData(),
    activeHoursPerDay: [Double] = [10, 10, 10, 10, 10, 10, 10]
) -> UsageOptimiser {
    UsageOptimiser(data: data, activeHoursPerDay: activeHoursPerDay, persistURL: nil)
}

/// Create a UsageMonitor with an in-memory optimiser (no disk I/O).
@MainActor
func makeTestMonitor(
    data: StoreData = StoreData(),
    activeHoursPerDay: [Double] = [10, 10, 10, 10, 10, 10, 10],
    config: AppConfig = AppConfig()
) -> UsageMonitor {
    let monitor = UsageMonitor()
    monitor.config = config
    let optimiser = UsageOptimiser(
        data: data,
        activeHoursPerDay: activeHoursPerDay,
        persistURL: nil
    )
    monitor.optimiser = optimiser
    return monitor
}

/// Build a StoreData from arrays of tuples for compact test setup.
func makeStoreData(
    polls: [(timestamp: Date, sessionUsage: Double, sessionRemaining: Double, weeklyUsage: Double, weeklyRemaining: Double)] = [],
    sessions: [(timestamp: Date, weeklyUsage: Double, weeklyRemaining: Double)] = []
) -> StoreData {
    StoreData(
        polls: polls.map { Poll(timestamp: $0.timestamp, sessionUsage: $0.sessionUsage, sessionRemaining: $0.sessionRemaining, weeklyUsage: $0.weeklyUsage, weeklyRemaining: $0.weeklyRemaining) },
        sessions: sessions.map { SessionStart(timestamp: $0.timestamp, weeklyUsage: $0.weeklyUsage, weeklyRemaining: $0.weeklyRemaining) }
    )
}
