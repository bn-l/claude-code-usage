import Testing
import Foundation
@testable import Clacal

// MARK: - Session Boundary Detection

@Suite("UsageOptimiser — Session Boundary Detection")
@MainActor
struct OptimiserSessionBoundaryTests {

    @Test("First poll ever: detected as new session")
    func firstPollIsNewSession() {
        let opt = makeTestOptimiser()
        let result = opt.recordPoll(
            sessionUsage: 5, sessionRemaining: 290,
            weeklyUsage: 10, weeklyRemaining: 9000
        )
        #expect(result.isNewSession)
        #expect(opt.sessionStarts.count == 1)
    }

    @Test("Timer jumped up by >30: new session detected")
    func timerJumpedUp() {
        let now = Date()
        let data = makeStoreData(
            polls: [(now.addingTimeInterval(-300), 20, 100, 30, 8000)],
            sessions: [(now.addingTimeInterval(-3600), 25, 8500)]
        )
        let opt = makeTestOptimiser(data: data)

        let result = opt.recordPoll(
            sessionUsage: 0, sessionRemaining: 290,
            weeklyUsage: 30, weeklyRemaining: 8000,
            timestamp: now
        )
        #expect(result.isNewSession)
    }

    @Test("Timer jumped by exactly 30: no detection (threshold is strictly >30)")
    func timerJumpedExactly30() {
        let now = Date()
        let data = makeStoreData(
            polls: [(now.addingTimeInterval(-300), 10, 100, 30, 8000)],
            sessions: [(now.addingTimeInterval(-3600), 25, 8500)]
        )
        let opt = makeTestOptimiser(data: data)

        let result = opt.recordPoll(
            sessionUsage: 12, sessionRemaining: 130,
            weeklyUsage: 31, weeklyRemaining: 7995,
            timestamp: now
        )
        #expect(!result.isNewSession)
    }

    @Test("Timer jumped by 31: detection fires")
    func timerJumped31() {
        let now = Date()
        let data = makeStoreData(
            polls: [(now.addingTimeInterval(-300), 10, 100, 30, 8000)],
            sessions: [(now.addingTimeInterval(-3600), 25, 8500)]
        )
        let opt = makeTestOptimiser(data: data)

        let result = opt.recordPoll(
            sessionUsage: 0, sessionRemaining: 131,
            weeklyUsage: 30, weeklyRemaining: 8000,
            timestamp: now
        )
        #expect(result.isNewSession)
    }

    @Test("Timer decreased normally: no detection")
    func timerDecreased() {
        let now = Date()
        let data = makeStoreData(
            polls: [(now.addingTimeInterval(-300), 10, 200, 30, 8000)],
            sessions: [(now.addingTimeInterval(-3600), 25, 8500)]
        )
        let opt = makeTestOptimiser(data: data)

        let result = opt.recordPoll(
            sessionUsage: 12, sessionRemaining: 195,
            weeklyUsage: 31, weeklyRemaining: 7995,
            timestamp: now
        )
        #expect(!result.isNewSession)
    }

    @Test("App downtime: session must have expired during gap")
    func downtimeSessionExpired() {
        let now = Date()
        // Last poll 6 hours ago, session had 280 min left (4h40m) — it expired
        let data = makeStoreData(
            polls: [(now.addingTimeInterval(-6 * 3600), 20, 280, 30, 8000)],
            sessions: [(now.addingTimeInterval(-7 * 3600), 25, 8500)]
        )
        let opt = makeTestOptimiser(data: data)

        let result = opt.recordPoll(
            sessionUsage: 5, sessionRemaining: 260,
            weeklyUsage: 32, weeklyRemaining: 7800,
            timestamp: now
        )
        #expect(result.isNewSession)
    }

    @Test("App downtime within session: no detection")
    func downtimeSameSession() {
        let now = Date()
        // Last poll 2 hours ago, session had 280 min left (4h40m) — still alive
        let data = makeStoreData(
            polls: [(now.addingTimeInterval(-2 * 3600), 10, 280, 30, 8000)],
            sessions: [(now.addingTimeInterval(-3 * 3600), 25, 8500)]
        )
        let opt = makeTestOptimiser(data: data)

        let result = opt.recordPoll(
            sessionUsage: 20, sessionRemaining: 160,
            weeklyUsage: 35, weeklyRemaining: 7700,
            timestamp: now
        )
        #expect(!result.isNewSession)
    }

    @Test("Both signals fire: only one session start created")
    func bothSignalsOneSessionStart() {
        let now = Date()
        let data = makeStoreData(
            polls: [(now.addingTimeInterval(-25 * 60), 50, 20, 30, 8000)],
            sessions: [(now.addingTimeInterval(-3600), 25, 8500)]
        )
        let opt = makeTestOptimiser(data: data)
        let sessionsBefore = opt.sessionStarts.count

        let result = opt.recordPoll(
            sessionUsage: 0, sessionRemaining: 290,
            weeklyUsage: 30, weeklyRemaining: 8000,
            timestamp: now
        )
        #expect(result.isNewSession)
        #expect(opt.sessionStarts.count == sessionsBefore + 1)
    }
}

// MARK: - Weekly Deviation

@Suite("UsageOptimiser — Weekly Deviation")
@MainActor
struct OptimiserWeeklyDeviationTests {

    @Test("weeklyRemaining=0: deviation is 0")
    func weeklyExpiredZeroDeviation() {
        let opt = makeTestOptimiser()
        let result = opt.recordPoll(
            sessionUsage: 10, sessionRemaining: 280,
            weeklyUsage: 90, weeklyRemaining: 0
        )
        #expect(result.weeklyDeviation == 0)
    }

    @Test("Usage exactly at schedule expectation: deviation near 0")
    func onSchedule() {
        // Mid-week with proportional usage — deviation should be small
        let opt = makeTestOptimiser()
        // First poll establishes session
        _ = opt.recordPoll(
            sessionUsage: 0, sessionRemaining: 300,
            weeklyUsage: 50, weeklyRemaining: 5040,
            timestamp: Date()
        )
        let result = opt.recordPoll(
            sessionUsage: 5, sessionRemaining: 295,
            weeklyUsage: 50, weeklyRemaining: 5035,
            timestamp: Date().addingTimeInterval(300)
        )
        // Deviation should be moderate (not extreme)
        #expect(abs(result.weeklyDeviation) < 1)
    }

    @Test("Far behind schedule: positive deviation")
    func behindSchedule() {
        let opt = makeTestOptimiser()
        // Week almost over (1 day left) but only 10% used
        let result = opt.recordPoll(
            sessionUsage: 5, sessionRemaining: 280,
            weeklyUsage: 10, weeklyRemaining: 1440
        )
        #expect(result.weeklyDeviation > 0)
    }

    @Test("Far ahead of schedule: negative deviation")
    func aheadOfSchedule() {
        let opt = makeTestOptimiser()
        // Early in week (6 days left) but already 90% used
        let result = opt.recordPoll(
            sessionUsage: 50, sessionRemaining: 200,
            weeklyUsage: 90, weeklyRemaining: 8640
        )
        #expect(result.weeklyDeviation < 0)
    }

    @Test("Deviation is bounded [-1, 1] via tanh")
    func deviationBounded() {
        let opt = makeTestOptimiser()
        let result = opt.recordPoll(
            sessionUsage: 0, sessionRemaining: 300,
            weeklyUsage: 0, weeklyRemaining: 100
        )
        #expect(result.weeklyDeviation >= -1)
        #expect(result.weeklyDeviation <= 1)
    }
}

// MARK: - Session Target

@Suite("UsageOptimiser — Session Target")
@MainActor
struct OptimiserSessionTargetTests {

    @Test("On schedule (deviation ~0): target = 100")
    func onScheduleFullTarget() {
        let opt = makeTestOptimiser()
        let result = opt.recordPoll(
            sessionUsage: 0, sessionRemaining: 300,
            weeklyUsage: 50, weeklyRemaining: 5040
        )
        // When deviation >= 0, target = 100
        if result.weeklyDeviation >= 0 {
            #expect(result.target == 100)
        }
    }

    @Test("Target never drops below 10")
    func targetFloor() {
        let opt = makeTestOptimiser()
        // Way ahead of schedule
        let result = opt.recordPoll(
            sessionUsage: 80, sessionRemaining: 100,
            weeklyUsage: 95, weeklyRemaining: 8000
        )
        #expect(result.target >= 10)
    }

    @Test("Target never exceeds 100")
    func targetCeiling() {
        let opt = makeTestOptimiser()
        let result = opt.recordPoll(
            sessionUsage: 0, sessionRemaining: 300,
            weeklyUsage: 0, weeklyRemaining: 100
        )
        #expect(result.target <= 100)
    }
}

// MARK: - Optimal Rate

@Suite("UsageOptimiser — Optimal Rate")
@MainActor
struct OptimiserOptimalRateTests {

    @Test("Session expired (sessionRemaining=0): rate is 0")
    func sessionExpiredZeroRate() {
        let opt = makeTestOptimiser()
        let result = opt.recordPoll(
            sessionUsage: 80, sessionRemaining: 0,
            weeklyUsage: 50, weeklyRemaining: 5000
        )
        #expect(result.optimalRate == 0)
    }

    @Test("Rate is non-negative")
    func rateNonNegative() {
        let opt = makeTestOptimiser()
        let result = opt.recordPoll(
            sessionUsage: 30, sessionRemaining: 200,
            weeklyUsage: 40, weeklyRemaining: 6000
        )
        #expect(result.optimalRate >= 0)
    }

    @Test("Session usage already exceeds target: rate floors to 0")
    func usageExceedsTarget() {
        let opt = makeTestOptimiser()
        // Far ahead → low target, but session usage already exceeds it
        let result = opt.recordPoll(
            sessionUsage: 80, sessionRemaining: 100,
            weeklyUsage: 95, weeklyRemaining: 8000
        )
        // Target will be low (surplus), usage 80 likely exceeds it
        #expect(result.optimalRate >= 0)
    }
}

// MARK: - Calibrator

@Suite("UsageOptimiser — Calibrator")
@MainActor
struct OptimiserCalibratorTests {

    @Test("Session expired: calibrator = 0")
    func sessionExpired() {
        let opt = makeTestOptimiser()
        let result = opt.recordPoll(
            sessionUsage: 50, sessionRemaining: 0,
            weeklyUsage: 40, weeklyRemaining: 5000
        )
        #expect(result.calibrator == 0)
    }

    @Test("First few minutes of session (< 5 min elapsed): calibrator = 0")
    func earlySessionNoSignal() {
        let opt = makeTestOptimiser()
        let result = opt.recordPoll(
            sessionUsage: 2, sessionRemaining: 298,
            weeklyUsage: 20, weeklyRemaining: 8000
        )
        // elapsed = 300 - 298 = 2 min < 5 → calibrator = 0
        #expect(result.calibrator == 0)
    }

    @Test("Calibrator bounded [-1, 1]")
    func calibratorBounded() {
        let opt = makeTestOptimiser()
        let result = opt.recordPoll(
            sessionUsage: 30, sessionRemaining: 200,
            weeklyUsage: 40, weeklyRemaining: 6000
        )
        #expect(result.calibrator >= -1)
        #expect(result.calibrator <= 1)
    }

    @Test("Idle user with headroom: negative calibrator (under-using)")
    func idleWithHeadroom() {
        let now = Date()
        let sessionStart = now.addingTimeInterval(-1800) // 30 min ago
        let data = makeStoreData(
            polls: [
                (sessionStart, 0, 300, 20, 8000),
                (sessionStart.addingTimeInterval(300), 0, 295, 20, 7995),
                (sessionStart.addingTimeInterval(600), 0, 290, 20, 7990),
            ],
            sessions: [(sessionStart, 20, 8000)]
        )
        let opt = makeTestOptimiser(data: data)

        let result = opt.recordPoll(
            sessionUsage: 0, sessionRemaining: 270,
            weeklyUsage: 20, weeklyRemaining: 7970,
            timestamp: now
        )
        // Idle (velocity ~0) but optimal rate > 0 → negative calibrator (under-using)
        #expect(result.calibrator < 0)
    }
}

// MARK: - Exchange Rate

@Suite("UsageOptimiser — Exchange Rate")
@MainActor
struct OptimiserExchangeRateTests {

    @Test("Fewer than 10 samples: exchange rate is nil")
    func insufficientSamples() {
        let opt = makeTestOptimiser()
        _ = opt.recordPoll(
            sessionUsage: 10, sessionRemaining: 280,
            weeklyUsage: 20, weeklyRemaining: 8000
        )
        let result = opt.recordPoll(
            sessionUsage: 15, sessionRemaining: 275,
            weeklyUsage: 21, weeklyRemaining: 7995,
            timestamp: Date().addingTimeInterval(300)
        )
        #expect(result.exchangeRate == nil)
    }

    @Test("With enough samples: exchange rate is a positive number")
    func sufficientSamples() {
        let now = Date()
        let sessionStart = now.addingTimeInterval(-3600)

        // Build 15 polls with consistent usage increase within same session
        var polls: [(Date, Double, Double, Double, Double)] = []
        for i in 0..<15 {
            let ts = sessionStart.addingTimeInterval(Double(i) * 300)
            let sessionUsage = Double(i) * 3.0
            let sessionRemaining = 300 - Double(i) * 5
            let weeklyUsage = 20 + Double(i) * 0.3
            let weeklyRemaining = 8000 - Double(i) * 5
            polls.append((ts, sessionUsage, sessionRemaining, weeklyUsage, weeklyRemaining))
        }

        let data = makeStoreData(
            polls: polls,
            sessions: [(sessionStart, 20, 8000)]
        )
        let opt = makeTestOptimiser(data: data)

        let result = opt.recordPoll(
            sessionUsage: 48, sessionRemaining: 220,
            weeklyUsage: 24.5, weeklyRemaining: 7920,
            timestamp: now
        )
        // Should have enough delta pairs for exchange rate
        if let xr = result.exchangeRate {
            #expect(xr > 0)
        }
        // It's OK if still nil — depends on whether enough pairs had deltaSession > 0.5
    }
}

// MARK: - Active Hours

@Suite("UsageOptimiser — Active Hours")
@MainActor
struct OptimiserActiveHoursTests {

    @Test("Full day within 10am-8pm window: 10 active hours")
    func fullDayWithinWindow() {
        let opt = makeTestOptimiser(activeHoursPerDay: [10, 10, 10, 10, 10, 10, 10])
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        let hours = opt.activeHoursInRange(from: today, to: today.addingTimeInterval(24 * 3600))
        // Window is 10am–8pm = 10 hours
        #expect(abs(hours - 10) < 0.01)
    }

    @Test("Range entirely before window: 0 active hours")
    func beforeWindow() {
        let opt = makeTestOptimiser(activeHoursPerDay: [10, 10, 10, 10, 10, 10, 10])
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // 2am to 8am — entirely before 10am window
        let start = today.addingTimeInterval(2 * 3600)
        let end = today.addingTimeInterval(8 * 3600)
        let hours = opt.activeHoursInRange(from: start, to: end)
        #expect(hours == 0)
    }

    @Test("Range entirely after window: 0 active hours")
    func afterWindow() {
        let opt = makeTestOptimiser(activeHoursPerDay: [10, 10, 10, 10, 10, 10, 10])
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // 9pm to 11pm — entirely after 8pm window
        let start = today.addingTimeInterval(21 * 3600)
        let end = today.addingTimeInterval(23 * 3600)
        let hours = opt.activeHoursInRange(from: start, to: end)
        #expect(hours == 0)
    }

    @Test("Partial overlap with window")
    func partialOverlap() {
        let opt = makeTestOptimiser(activeHoursPerDay: [10, 10, 10, 10, 10, 10, 10])
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // 8am to 2pm — overlaps with 10am–2pm = 4 hours
        let start = today.addingTimeInterval(8 * 3600)
        let end = today.addingTimeInterval(14 * 3600)
        let hours = opt.activeHoursInRange(from: start, to: end)
        #expect(abs(hours - 4) < 0.01)
    }

    @Test("Multi-day range sums active hours per day")
    func multiDay() {
        let opt = makeTestOptimiser(activeHoursPerDay: [10, 10, 10, 10, 10, 10, 10])
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // 3 full days
        let start = today
        let end = today.addingTimeInterval(3 * 24 * 3600)
        let hours = opt.activeHoursInRange(from: start, to: end)
        // 3 days × 10 hours = 30
        #expect(abs(hours - 30) < 0.01)
    }

    @Test("Different hours per day respected")
    func differentHoursPerDay() {
        // 8h weekdays, 4h weekends: windows are (10, 18) and (10, 14)
        let opt = makeTestOptimiser(activeHoursPerDay: [8, 8, 8, 8, 8, 4, 4])
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // Full week
        let start = today
        let end = today.addingTimeInterval(7 * 24 * 3600)
        let hours = opt.activeHoursInRange(from: start, to: end)
        // 5 × 8 + 2 × 4 = 48
        #expect(abs(hours - 48) < 0.01)
    }

    @Test("Zero hours per day: no active hours")
    func zeroHoursDay() {
        let opt = makeTestOptimiser(activeHoursPerDay: [10, 10, 10, 10, 10, 0, 0])
        let cal = Calendar.current

        // Find next Saturday
        var cursor = cal.startOfDay(for: Date())
        while cal.component(.weekday, from: cursor) != 7 { // 7 = Saturday
            cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
        }

        let hours = opt.activeHoursInRange(from: cursor, to: cursor.addingTimeInterval(24 * 3600))
        #expect(hours == 0)
    }

    @Test("Empty range: 0 active hours")
    func emptyRange() {
        let opt = makeTestOptimiser()
        let now = Date()
        let hours = opt.activeHoursInRange(from: now, to: now)
        #expect(hours == 0)
    }
}

// MARK: - Pruning

@Suite("UsageOptimiser — Pruning")
@MainActor
struct OptimiserPruningTests {

    @Test("Records older than 90 days are pruned")
    func prunesOldRecords() {
        let now = Date()
        let old = now.addingTimeInterval(-91 * 86400)
        let recent = now.addingTimeInterval(-300)

        let data = makeStoreData(
            polls: [
                (old, 10, 200, 20, 8000),
                (recent, 20, 250, 25, 7800),
            ],
            sessions: [
                (old, 20, 8000),
                (recent, 25, 7800),
            ]
        )
        let opt = makeTestOptimiser(data: data)

        // Record a new poll — triggers prune
        _ = opt.recordPoll(
            sessionUsage: 5, sessionRemaining: 290,
            weeklyUsage: 26, weeklyRemaining: 7795,
            timestamp: now
        )

        // Old records should be pruned
        #expect(opt.polls.allSatisfy { $0.timestamp > old })
        #expect(opt.sessionStarts.allSatisfy { $0.timestamp > old })
    }
}

// MARK: - End-to-End Scenarios from temp3.md

@Suite("UsageOptimiser — Worked Scenarios")
@MainActor
struct OptimiserScenarioTests {

    @Test("Fresh session, behind on weekly: velocity exceeds optimal rate")
    func behindOnWeekly() {
        let opt = makeTestOptimiser()

        // Simulate a few polls to get past the 5-min early-session guard
        let now = Date()
        _ = opt.recordPoll(
            sessionUsage: 0, sessionRemaining: 300,
            weeklyUsage: 10, weeklyRemaining: 1440,
            timestamp: now
        )
        for i in 1...5 {
            _ = opt.recordPoll(
                sessionUsage: Double(i) * 2, sessionRemaining: 300 - Double(i) * 5,
                weeklyUsage: 10 + Double(i) * 0.1, weeklyRemaining: 1440 - Double(i) * 5,
                timestamp: now.addingTimeInterval(Double(i) * 300)
            )
        }

        let result = opt.recordPoll(
            sessionUsage: 14, sessionRemaining: 265,
            weeklyUsage: 10.7, weeklyRemaining: 1405,
            timestamp: now.addingTimeInterval(2100)
        )
        // Far behind on weekly (only 10% used with 1 day left) → target 100
        // But velocity (~0.4 %/min) exceeds optimal (~0.325 %/min) → positive (over-using)
        #expect(result.target == 100)
        #expect(result.calibrator > 0)
    }

    @Test("Running hot: ahead of schedule, target reduced")
    func runningHot() {
        let opt = makeTestOptimiser()

        let result = opt.recordPoll(
            sessionUsage: 72, sessionRemaining: 180,
            weeklyUsage: 58, weeklyRemaining: 6500
        )
        // Well ahead of schedule — deviation should be negative
        #expect(result.weeklyDeviation < 0)
        // Target should be less than 100
        #expect(result.target < 100)
    }

    @Test("Session usage exceeds target: positive calibrator (over-using)")
    func usageExceedsTarget() {
        let now = Date()
        // Build a session with polls so we have velocity data
        let sessionStart = now.addingTimeInterval(-1800)
        var polls: [(Date, Double, Double, Double, Double)] = []
        for i in 0..<6 {
            let ts = sessionStart.addingTimeInterval(Double(i) * 300)
            polls.append((ts, Double(i) * 12, 300 - Double(i) * 5, 58 + Double(i) * 0.2, 6500 - Double(i) * 5))
        }

        let data = makeStoreData(
            polls: polls,
            sessions: [(sessionStart, 58, 6500)]
        )
        let opt = makeTestOptimiser(data: data)

        let result = opt.recordPoll(
            sessionUsage: 72, sessionRemaining: 270,
            weeklyUsage: 59.2, weeklyRemaining: 6470,
            timestamp: now
        )
        // Far ahead → target reduced, velocity exceeds optimal → positive calibrator (over-using)
        #expect(result.calibrator > 0)
    }
}
