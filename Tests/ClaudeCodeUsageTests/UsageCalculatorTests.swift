import Testing
import Foundation
@testable import ClaudeCodeUsage

@Suite("UsageCalculator")
struct UsageCalculatorTests {

    private func snap(
        weeklyUsagePctAtStart: Double = 20,
        weeklyMinsLeftAtStart: Double = 7200
    ) -> SessionSnapshot {
        SessionSnapshot(
            weeklyUsagePctAtStart: weeklyUsagePctAtStart,
            weeklyMinsLeftAtStart: weeklyMinsLeftAtStart,
            timestamp: Date()
        )
    }

    // MARK: - Session Forecast

    @Test("Session at start: sessionElapsedFrac clamps to eps, forecast = 0")
    func sessionAtStart() {
        let m = UsageCalculator.compute(
            sessionUsagePct: 0, weeklyUsagePct: 20,
            sessionMinsLeft: 300, weeklyMinsLeft: 7200,
            snapshot: snap(), sessionsPerDay: 2
        )
        #expect(m.sessionForecastPct == 0)
        #expect(m.combinedPct == 0)
    }

    @Test("Session halfway: forecast = usagePct / 0.5")
    func sessionHalfway() {
        let m = UsageCalculator.compute(
            sessionUsagePct: 25, weeklyUsagePct: 20,
            sessionMinsLeft: 150, weeklyMinsLeft: 7200,
            snapshot: snap(), sessionsPerDay: 2
        )
        #expect(m.sessionForecastPct == 50)
    }

    @Test("Session nearly over: forecast ≈ usagePct")
    func sessionNearlyOver() {
        let m = UsageCalculator.compute(
            sessionUsagePct: 80, weeklyUsagePct: 20,
            sessionMinsLeft: 1, weeklyMinsLeft: 7200,
            snapshot: snap(), sessionsPerDay: 2
        )
        // sessionElapsedFrac ≈ 299/300 ≈ 0.997, forecast ≈ 80/0.997 ≈ 80.24, but clamped path doesn't apply
        #expect(abs(m.sessionForecastPct - 80) < 1)
    }

    @Test("sessionMinsLeft=0: no division by zero, elapsedFrac clamps to 1")
    func sessionMinsLeftZero() {
        let m = UsageCalculator.compute(
            sessionUsagePct: 80, weeklyUsagePct: 20,
            sessionMinsLeft: 0, weeklyMinsLeft: 7200,
            snapshot: snap(), sessionsPerDay: 2
        )
        #expect(m.sessionForecastPct == 80)
    }

    @Test("sessionUsagePct=100 halfway: forecast clamps to 100, not 200")
    func sessionForecastClamps() {
        let m = UsageCalculator.compute(
            sessionUsagePct: 100, weeklyUsagePct: 20,
            sessionMinsLeft: 150, weeklyMinsLeft: 7200,
            snapshot: snap(), sessionsPerDay: 2
        )
        #expect(m.sessionForecastPct == 100)
    }

    // MARK: - Weekly Budget Burn

    @Test("weeklyUsagePct == snapshot start: delta=0, burn=0")
    func weeklyNoDelta() {
        let m = UsageCalculator.compute(
            sessionUsagePct: 0, weeklyUsagePct: 20,
            sessionMinsLeft: 300, weeklyMinsLeft: 7200,
            snapshot: snap(weeklyUsagePctAtStart: 20), sessionsPerDay: 2
        )
        #expect(m.weeklyBudgetBurnPct == 0)
    }

    @Test("weeklyUsagePct below snapshot start: delta clamps to 0")
    func weeklyBelowStart() {
        let m = UsageCalculator.compute(
            sessionUsagePct: 0, weeklyUsagePct: 10,
            sessionMinsLeft: 300, weeklyMinsLeft: 7200,
            snapshot: snap(weeklyUsagePctAtStart: 20), sessionsPerDay: 2
        )
        #expect(m.weeklyBudgetBurnPct == 0)
    }

    @Test("sessionsPerDay=0: protected by max(...,1)")
    func sessionsPerDayZero() {
        let m = UsageCalculator.compute(
            sessionUsagePct: 25, weeklyUsagePct: 25,
            sessionMinsLeft: 150, weeklyMinsLeft: 7200,
            snapshot: snap(weeklyUsagePctAtStart: 20), sessionsPerDay: 0
        )
        // Should not crash (no division by zero)
        #expect(m.weeklyBudgetBurnPct >= 0)
    }

    @Test("sessionsPerDay=0.5: budget = dailyBudget / 0.5 = 2x")
    func sessionsPerDayFractional() {
        let s = snap(weeklyUsagePctAtStart: 20, weeklyMinsLeftAtStart: 7200)
        let m = UsageCalculator.compute(
            sessionUsagePct: 0, weeklyUsagePct: 25,
            sessionMinsLeft: 300, weeklyMinsLeft: 7200,
            snapshot: s, sessionsPerDay: 0.5
        )
        // dailyBudget = 80 / 5 = 16, sessionBudget = 16 / 0.5 = 32
        // delta = 5, burn = 100 * 5 / 32 ≈ 15.6
        #expect(m.weeklyBudgetBurnPct > 0)
        #expect(m.weeklyBudgetBurnPct < 100)
    }

    @Test("Large sessionsPerDay: tiny per-session budget, burn hits 100 quickly")
    func largeSessPerDay() {
        let m = UsageCalculator.compute(
            sessionUsagePct: 0, weeklyUsagePct: 25,
            sessionMinsLeft: 300, weeklyMinsLeft: 7200,
            snapshot: snap(weeklyUsagePctAtStart: 20), sessionsPerDay: 10
        )
        // sessionBudget is very small, so 5% delta → burn clamped to 100
        #expect(m.weeklyBudgetBurnPct == 100)
    }

    @Test("weeklyBudgetBurnPct clamps to 100")
    func burnClamps() {
        let m = UsageCalculator.compute(
            sessionUsagePct: 0, weeklyUsagePct: 80,
            sessionMinsLeft: 300, weeklyMinsLeft: 7200,
            snapshot: snap(weeklyUsagePctAtStart: 20), sessionsPerDay: 10
        )
        #expect(m.weeklyBudgetBurnPct == 100)
    }

    @Test("combinedPct = max(sessionForecast, weeklyBurn)")
    func combinedIsMax() {
        let m = UsageCalculator.compute(
            sessionUsagePct: 25, weeklyUsagePct: 20,
            sessionMinsLeft: 150, weeklyMinsLeft: 7200,
            snapshot: snap(weeklyUsagePctAtStart: 20), sessionsPerDay: 2
        )
        // sessionForecast = 50, weeklyBurn = 0 (no delta)
        #expect(m.combinedPct == max(m.sessionForecastPct, m.weeklyBudgetBurnPct))
        #expect(m.combinedPct == 50)
    }

    @Test("weeklyMinsLeftAtStart=0: daysLeft clamps to eps, no crash")
    func weeklyMinsLeftAtStartZero() {
        let m = UsageCalculator.compute(
            sessionUsagePct: 0, weeklyUsagePct: 25,
            sessionMinsLeft: 300, weeklyMinsLeft: 100,
            snapshot: snap(weeklyUsagePctAtStart: 20, weeklyMinsLeftAtStart: 0),
            sessionsPerDay: 2
        )
        // Should not crash; large but finite budget math
        #expect(m.weeklyBudgetBurnPct >= 0)
    }

    @Test("weeklyUsagePctAtStart=100: dailyBudget=0, sessionBudget=0, burn=0/eps")
    func weeklyFullyUsed() {
        let m = UsageCalculator.compute(
            sessionUsagePct: 0, weeklyUsagePct: 100,
            sessionMinsLeft: 300, weeklyMinsLeft: 100,
            snapshot: snap(weeklyUsagePctAtStart: 100, weeklyMinsLeftAtStart: 100),
            sessionsPerDay: 2
        )
        // dailyBudget = max(0, 0) / ... = 0, sessionBudget = 0
        // burn = 100 * 0 / max(0, eps) = 0
        #expect(m.weeklyBudgetBurnPct == 0)
    }
}
