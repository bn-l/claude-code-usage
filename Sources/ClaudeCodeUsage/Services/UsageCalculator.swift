import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bml.claude-code-usage", category: "Calculator")

enum UsageCalculator {
    private static let sessionLenMins: Double = 300
    private static let eps: Double = 0.01

    static func compute(
        sessionUsagePct: Double,
        weeklyUsagePct: Double,
        sessionMinsLeft: Double,
        weeklyMinsLeft: Double,
        snapshot: SessionSnapshot,
        sessionsPerDay: Double
    ) -> UsageMetrics {
        logger.debug("Computing metrics: sessionUsagePct=\(sessionUsagePct, privacy: .public) weeklyUsagePct=\(weeklyUsagePct, privacy: .public) sessionMinsLeft=\(sessionMinsLeft, privacy: .public) weeklyMinsLeft=\(weeklyMinsLeft, privacy: .public) sessionsPerDay=\(sessionsPerDay, privacy: .public)")
        logger.debug("Snapshot: weeklyUsagePctAtStart=\(snapshot.weeklyUsagePctAtStart, privacy: .public) weeklyMinsLeftAtStart=\(snapshot.weeklyMinsLeftAtStart, privacy: .public) timestamp=\(snapshot.timestamp, privacy: .public)")

        let sessionElapsedFrac = clamp(
            (sessionLenMins - sessionMinsLeft) / sessionLenMins,
            lo: eps, hi: 1
        )

        let sessionForecastPct = clamp(
            sessionUsagePct / sessionElapsedFrac,
            lo: 0, hi: 100
        )

        let daysLeftAtStart = max(snapshot.weeklyMinsLeftAtStart / 1440, eps)
        let dailyBudgetPctAtStart = max(100 - snapshot.weeklyUsagePctAtStart, 0) / daysLeftAtStart
        let sessionBudgetPctAtStart = dailyBudgetPctAtStart / max(sessionsPerDay, 1)

        let weeklyUsageDeltaPct = max(weeklyUsagePct - snapshot.weeklyUsagePctAtStart, 0)
        let weeklyBudgetBurnPct = clamp(
            100 * weeklyUsageDeltaPct / max(sessionBudgetPctAtStart, eps),
            lo: 0, hi: 100
        )

        let combinedPct = max(sessionForecastPct, weeklyBudgetBurnPct)

        logger.debug("Intermediate: sessionElapsedFrac=\(sessionElapsedFrac, privacy: .public) daysLeftAtStart=\(daysLeftAtStart, privacy: .public) dailyBudgetPctAtStart=\(dailyBudgetPctAtStart, privacy: .public) sessionBudgetPctAtStart=\(sessionBudgetPctAtStart, privacy: .public) weeklyUsageDeltaPct=\(weeklyUsageDeltaPct, privacy: .public)")
        logger.info("Computed metrics: sessionForecastPct=\(sessionForecastPct, privacy: .public) weeklyBudgetBurnPct=\(weeklyBudgetBurnPct, privacy: .public) combinedPct=\(combinedPct, privacy: .public)")

        return UsageMetrics(
            sessionUsagePct: sessionUsagePct,
            weeklyUsagePct: weeklyUsagePct,
            sessionMinsLeft: sessionMinsLeft,
            weeklyMinsLeft: weeklyMinsLeft,
            sessionForecastPct: sessionForecastPct,
            weeklyBudgetBurnPct: weeklyBudgetBurnPct,
            combinedPct: combinedPct,
            timestamp: Date()
        )
    }

    private static func clamp(_ value: Double, lo: Double, hi: Double) -> Double {
        min(max(value, lo), hi)
    }
}
