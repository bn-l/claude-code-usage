import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bml.claude-code-usage", category: "Optimiser")

private enum PacingZone {
    case ok, fast, slow
}

struct OptimiserResult: Sendable {
    let calibrator: Double
    let target: Double
    let optimalRate: Double
    let currentRate: Double?
    let weeklyDeviation: Double
    let exchangeRate: Double?
    let sessionBudget: Double?
    let isNewSession: Bool
    let sessionDeviation: Double
    let dailyDeviation: Double
}

@MainActor
final class UsageOptimiser {
    static let sessionMinutes: Double = 300
    static let weekMinutes: Double = 10080

    private static let maxDays = 90
    private static let emaAlpha = 0.3
    private static let gapThresholdMinutes: Double = 15
    private static let boundaryJumpMinutes: Double = 30
    private static let minActiveHoursForProjection: Double = 0.5
    private static let minExchangeRateSamples = 10
    private static let empiricalWeeksRequired: Double = 3
    private static let empiricalMinSamples = 5
    private static let windowDetectionMinPolls = 3
    private static let windowDetectionDaysRequired: Double = 7

    private static let dayResetHour = 5 // 5am local time

    private(set) var polls: [Poll]
    private(set) var sessionStarts: [SessionStart]
    private(set) var dailySnapshot: DailySnapshot?
    private var detectedWindows: [(start: Double, end: Double)]
    private let persistURL: URL?
    private var pacingZone: PacingZone = .ok
    private var prevCalOutput: Double = 0

    init(
        data: StoreData = StoreData(),
        activeHoursPerDay: [Double] = [10, 10, 10, 10, 10, 10, 10],
        persistURL: URL? = nil
    ) {
        self.polls = data.polls
        self.sessionStarts = data.sessions
        self.dailySnapshot = data.dailySnapshot
        self.persistURL = persistURL
        self.detectedWindows = activeHoursPerDay.map { hours in
            (start: 10.0, end: min(10.0 + hours, 24.0))
        }
        logger.info("Optimiser init: polls=\(data.polls.count, privacy: .public) sessions=\(data.sessions.count, privacy: .public) persist=\(persistURL != nil, privacy: .public)")
    }

    // MARK: - Public API

    func recordPoll(
        sessionUsage: Double,
        sessionRemaining: Double,
        weeklyUsage: Double,
        weeklyRemaining: Double,
        timestamp: Date = Date()
    ) -> OptimiserResult {
        let poll = Poll(
            timestamp: timestamp,
            sessionUsage: sessionUsage,
            sessionRemaining: sessionRemaining,
            weeklyUsage: weeklyUsage,
            weeklyRemaining: weeklyRemaining
        )

        let isNewSession = detectSessionBoundary(poll)
        if isNewSession {
            sessionStarts.append(SessionStart(
                timestamp: timestamp,
                weeklyUsage: weeklyUsage,
                weeklyRemaining: weeklyRemaining
            ))
            pacingZone = .ok
            prevCalOutput = 0
            logger.info("New session detected at \(timestamp, privacy: .public) weeklyUsage=\(weeklyUsage, privacy: .public)")
        }

        polls.append(poll)
        pruneOldRecords()
        maybeUpdateDetectedWindows()
        maybeUpdateDailySnapshot(poll)

        let deviation = weeklyDeviation(poll)
        let target = sessionTarget(deviation)
        let budget = sessionBudget(poll)
        let optimal = optimalRate(poll, target: target, budget: budget)
        let velocity = sessionVelocity()
        let sError = sessionError(poll, target: target)
        let cal = calibrator(sessionError: sError, deviation: deviation, poll: poll)
        let sDev = min(max(sError, -1), 1)
        let dDev = dailyDeviation(poll)

        persist()

        logger.info("Poll recorded: calibrator=\(cal, privacy: .public) target=\(target, privacy: .public) optimalRate=\(optimal, privacy: .public) weeklyDev=\(deviation, privacy: .public) sessionDev=\(sDev, privacy: .public) dailyDev=\(dDev, privacy: .public) newSession=\(isNewSession, privacy: .public)")

        return OptimiserResult(
            calibrator: cal,
            target: target,
            optimalRate: optimal,
            currentRate: velocity,
            weeklyDeviation: deviation,
            exchangeRate: exchangeRate(),
            sessionBudget: budget,
            isNewSession: isNewSession,
            sessionDeviation: sDev,
            dailyDeviation: dDev
        )
    }

    // MARK: - Session Boundary Detection

    private func detectSessionBoundary(_ poll: Poll) -> Bool {
        guard let previous = polls.last else {
            return true // Bootstrap: first poll ever
        }

        let timerJumped = poll.sessionRemaining - previous.sessionRemaining > Self.boundaryJumpMinutes
        let wallClockMinutes = poll.timestamp.timeIntervalSince(previous.timestamp) / 60
        let sessionExpired = wallClockMinutes > previous.sessionRemaining

        return timerJumped || sessionExpired
    }

    private var currentSessionStartTimestamp: Date? {
        sessionStarts.last?.timestamp
    }

    // MARK: - Stage 1: Weekly Deviation

    private func weeklyDeviation(_ poll: Poll) -> Double {
        guard poll.weeklyRemaining > 0 else { return 0 }

        let expected = weeklyExpected(poll)
        let positional = (expected - poll.weeklyUsage) / 100

        if let projected = weeklyProjected(poll) {
            let velocityDeviation = (100 - projected) / 100
            let raw = 0.5 * positional + 0.5 * velocityDeviation
            return tanh(2 * raw)
        }
        return tanh(2 * positional)
    }

    private func weeklyExpected(_ poll: Poll) -> Double {
        let elapsedMinutes = Self.weekMinutes - poll.weeklyRemaining
        if let empirical = weeklyExpectedEmpirical(poll, elapsedMinutes: elapsedMinutes) {
            return empirical
        }
        return weeklyExpectedFromSchedule(poll)
    }

    private func weeklyExpectedFromSchedule(_ poll: Poll) -> Double {
        let elapsedMinutes = Self.weekMinutes - poll.weeklyRemaining
        let weekStart = poll.timestamp.addingTimeInterval(-elapsedMinutes * 60)
        let weekEnd = poll.timestamp.addingTimeInterval(poll.weeklyRemaining * 60)

        let activeElapsed = activeHoursInRange(from: weekStart, to: poll.timestamp)
        let activeTotal = activeHoursInRange(from: weekStart, to: weekEnd)

        guard activeTotal > 0 else { return 0 }
        return min(100, (activeElapsed / activeTotal) * 100)
    }

    private func weeklyProjected(_ poll: Poll) -> Double? {
        let elapsedMinutes = Self.weekMinutes - poll.weeklyRemaining
        let weekStart = poll.timestamp.addingTimeInterval(-elapsedMinutes * 60)
        let weekEnd = poll.timestamp.addingTimeInterval(poll.weeklyRemaining * 60)

        let activeElapsed = activeHoursInRange(from: weekStart, to: poll.timestamp)
        guard activeElapsed >= Self.minActiveHoursForProjection else { return nil }

        let activeRemaining = activeHoursInRange(from: poll.timestamp, to: weekEnd)
        let averageRate = poll.weeklyUsage / activeElapsed
        return poll.weeklyUsage + averageRate * activeRemaining
    }

    private func weeklyExpectedEmpirical(_ poll: Poll, elapsedMinutes: Double) -> Double? {
        guard dataWeeks() >= Self.empiricalWeeksRequired else { return nil }

        let cutoff = poll.timestamp.addingTimeInterval(-7 * 86400)
        let values = polls
            .filter { $0.timestamp < cutoff }
            .filter { abs((Self.weekMinutes - $0.weeklyRemaining) - elapsedMinutes) < 15 }
            .map(\.weeklyUsage)
            .sorted()

        guard values.count >= Self.empiricalMinSamples else { return nil }
        return values[values.count / 2]
    }

    // MARK: - Stage 2: Session Target & Budget

    private func sessionTarget(_ deviation: Double) -> Double {
        100 * max(0.1, min(1, 1 + deviation))
    }

    private func sessionBudget(_ poll: Poll) -> Double? {
        guard let rate = exchangeRate(), rate > 0 else { return nil }
        let remainingHours = remainingActiveHours(poll)
        let sessionsLeft = max(remainingHours / 5, 1)
        return max(100 - poll.weeklyUsage, 0) / sessionsLeft
    }

    private func remainingActiveHours(_ poll: Poll) -> Double {
        let weekEnd = poll.timestamp.addingTimeInterval(poll.weeklyRemaining * 60)
        return activeHoursInRange(from: poll.timestamp, to: weekEnd)
    }

    // MARK: - Stage 3: Optimal Rate

    private func optimalRate(_ poll: Poll, target: Double, budget: Double?) -> Double {
        guard poll.sessionRemaining > 0 else { return 0 }

        let tau = max(poll.sessionRemaining, 0.1)
        let targetRate = max((target - poll.sessionUsage) / tau, 0)
        let ceilingRate = max((100 - poll.sessionUsage) / tau, 0)

        var rate = min(targetRate, ceilingRate)

        if let xr = exchangeRate(), xr > 0, let budget {
            let budgetRate = max(budget / (xr * tau), 0)
            rate = min(rate, budgetRate)
        }

        return rate
    }

    // MARK: - Session Error (shared by calibrator + dual bar)

    private func sessionError(_ poll: Poll, target: Double) -> Double {
        let elapsed = Self.sessionMinutes - poll.sessionRemaining
        guard elapsed >= 5 else { return 0 }
        let expectedUsage = target * (elapsed / Self.sessionMinutes)
        return (poll.sessionUsage - expectedUsage) / max(target, 1)
    }

    // MARK: - Stage 4: Calibrator (PB+Pipe)

    private func calibrator(sessionError: Double, deviation: Double, poll: Poll) -> Double {
        guard poll.sessionRemaining > 0 else { return 0 }

        let elapsed = Self.sessionMinutes - poll.sessionRemaining
        guard elapsed >= 5 else { return 0 }

        // Blend: session error (weighted by time remaining) + weekly deviation
        let sFrac = poll.sessionRemaining / Self.sessionMinutes
        let raw = max(-1.0, min(1.0, sFrac * sessionError + (1 - sFrac) * (-deviation)))

        // Dead zone — suppress small signals
        let dz: Double
        if abs(raw) < 0.05 {
            dz = 0
        } else {
            let sign: Double = raw > 0 ? 1 : -1
            dz = sign * (abs(raw) - 0.05) / 0.95
        }

        // Hysteresis — prevent oscillation at zone boundaries
        let hz: Double
        switch pacingZone {
        case .ok:
            if dz > 0.12 {
                pacingZone = .fast
                hz = dz
            } else if dz < -0.12 {
                pacingZone = .slow
                hz = dz
            } else {
                hz = 0
            }
        case .fast:
            if dz < 0.05 {
                pacingZone = .ok
                hz = 0
            } else {
                hz = dz
            }
        case .slow:
            if dz > -0.05 {
                pacingZone = .ok
                hz = 0
            } else {
                hz = dz
            }
        }

        // Smoothing — slew-rate limit for stable display
        let output = 0.25 * hz + 0.75 * prevCalOutput
        prevCalOutput = output
        return max(-1, min(1, output))
    }

    // MARK: - Velocity Estimation

    private func sessionVelocity() -> Double? {
        guard let sessionStart = currentSessionStartTimestamp else { return nil }
        let sessionPolls = polls.filter { $0.timestamp >= sessionStart }
        return emaVelocity(sessionPolls) { $0.sessionUsage }
    }

    private func emaVelocity(_ points: [Poll], value: (Poll) -> Double) -> Double? {
        guard points.count >= 2 else { return nil }
        var ema: Double?
        for index in 1..<points.count {
            let deltaMinutes = points[index].timestamp.timeIntervalSince(points[index - 1].timestamp) / 60
            guard deltaMinutes > 0, deltaMinutes <= Self.gapThresholdMinutes else { continue }
            let instantVelocity = (value(points[index]) - value(points[index - 1])) / deltaMinutes
            ema = ema.map { Self.emaAlpha * instantVelocity + (1 - Self.emaAlpha) * $0 } ?? instantVelocity
        }
        return ema
    }

    // MARK: - Exchange Rate

    func exchangeRate() -> Double? {
        var ratios: [Double] = []
        for index in 1..<polls.count {
            guard !spansSessionBoundary(from: polls[index - 1].timestamp, to: polls[index].timestamp) else {
                continue
            }
            let deltaMinutes = polls[index].timestamp.timeIntervalSince(polls[index - 1].timestamp) / 60
            guard deltaMinutes > 0, deltaMinutes <= Self.gapThresholdMinutes else { continue }
            let deltaSession = polls[index].sessionUsage - polls[index - 1].sessionUsage
            let deltaWeekly = polls[index].weeklyUsage - polls[index - 1].weeklyUsage
            if deltaSession > 0.5 {
                ratios.append(deltaWeekly / deltaSession)
            }
        }
        guard ratios.count >= Self.minExchangeRateSamples else { return nil }
        ratios.sort()
        return ratios[ratios.count / 2]
    }

    private func spansSessionBoundary(from start: Date, to end: Date) -> Bool {
        sessionStarts.contains { $0.timestamp > start && $0.timestamp <= end }
    }

    // MARK: - Active Hours Schedule

    func activeHoursInRange(from start: Date, to end: Date) -> Double {
        var total: Double = 0
        let calendar = Calendar.current
        var cursor = start

        while cursor < end {
            // Calendar weekday: 1=Sun, 2=Mon, ..., 7=Sat
            // We need: 0=Mon, 1=Tue, ..., 6=Sun
            let calendarWeekday = calendar.component(.weekday, from: cursor)
            let dayIndex = (calendarWeekday + 5) % 7

            let window = detectedWindows[dayIndex]
            let midnight = calendar.startOfDay(for: cursor)
            let windowOpen = midnight.addingTimeInterval(window.start * 3600)
            let windowClose = midnight.addingTimeInterval(window.end * 3600)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: midnight)!

            let segmentEnd = min(end, nextDay)
            let overlapStart = max(cursor, windowOpen)
            let overlapEnd = min(segmentEnd, windowClose)

            if overlapEnd > overlapStart {
                total += overlapEnd.timeIntervalSince(overlapStart) / 3600
            }

            cursor = nextDay
        }
        return total
    }

    // MARK: - Window Auto-Detection

    private func maybeUpdateDetectedWindows() {
        guard let firstPoll = polls.first else { return }
        let daysSinceFirst = Date().timeIntervalSince(firstPoll.timestamp) / 86400
        guard daysSinceFirst >= Self.windowDetectionDaysRequired else { return }

        let calendar = Calendar.current

        for dayIndex in 0..<7 {
            var activeHours: [Double] = []

            for index in 1..<polls.count {
                guard !spansSessionBoundary(from: polls[index - 1].timestamp, to: polls[index].timestamp) else {
                    continue
                }
                let deltaSession = polls[index].sessionUsage - polls[index - 1].sessionUsage
                guard deltaSession > 0.5 else { continue }

                let calendarWeekday = calendar.component(.weekday, from: polls[index].timestamp)
                let pollDayIndex = (calendarWeekday + 5) % 7
                guard pollDayIndex == dayIndex else { continue }

                let hour = Double(calendar.component(.hour, from: polls[index].timestamp))
                    + Double(calendar.component(.minute, from: polls[index].timestamp)) / 60
                activeHours.append(hour)
            }

            guard activeHours.count >= Self.windowDetectionMinPolls else { continue }

            let earliest = activeHours.min()!
            let latest = activeHours.max()!
            // Pad 1h on each side, clamped to 0–24
            let detectedStart = max(0, earliest - 1)
            let detectedEnd = min(24, latest + 1)

            if detectedEnd - detectedStart >= 2 {
                detectedWindows[dayIndex] = (start: detectedStart, end: detectedEnd)
            }
        }
    }

    // MARK: - Daily Snapshot & Ratios

    private func maybeUpdateDailySnapshot(_ poll: Poll) {
        let calendar = Calendar.current
        let boundary = dayBoundary(for: poll.timestamp, calendar: calendar)

        if let existing = dailySnapshot {
            let existingBoundary = dayBoundary(for: existing.date, calendar: calendar)
            let weeklyReset = !polls.isEmpty && poll.weeklyRemaining - (polls[polls.count - 2].weeklyRemaining) > 60
            guard boundary > existingBoundary || weeklyReset else { return }
        }

        dailySnapshot = DailySnapshot(
            date: poll.timestamp,
            weeklyUsagePct: poll.weeklyUsage,
            weeklyMinsLeft: poll.weeklyRemaining
        )
        logger.info("Daily snapshot captured: weeklyUsage=\(poll.weeklyUsage, privacy: .public) weeklyMinsLeft=\(poll.weeklyRemaining, privacy: .public)")
    }

    private func dayBoundary(for date: Date, calendar: Calendar) -> Date {
        let hour = calendar.component(.hour, from: date)
        let startOfDay = calendar.startOfDay(for: date)
        let boundary = startOfDay.addingTimeInterval(Double(Self.dayResetHour) * 3600)
        return hour < Self.dayResetHour
            ? boundary.addingTimeInterval(-86400)
            : boundary
    }

    private func dailyDeviation(_ poll: Poll) -> Double {
        guard let snapshot = dailySnapshot else { return 0 }
        let dailyDelta = max(poll.weeklyUsage - snapshot.weeklyUsagePct, 0)
        let daysRemaining = max(snapshot.weeklyMinsLeft / 1440.0, 0.01)
        let dailyAllotment = max(100 - snapshot.weeklyUsagePct, 0) / daysRemaining
        guard dailyAllotment > 0.01 else { return 0 }

        // Time-proportional: what fraction of today's active hours have elapsed?
        let calendar = Calendar.current
        let boundary = dayBoundary(for: poll.timestamp, calendar: calendar)
        let dayEnd = boundary.addingTimeInterval(86400)
        let activeTotal = activeHoursInRange(from: boundary, to: dayEnd)
        let activeElapsed = activeHoursInRange(from: boundary, to: poll.timestamp)
        let elapsedFrac = activeTotal > 0 ? activeElapsed / activeTotal : 0

        let expected = dailyAllotment * elapsedFrac
        let raw = (dailyDelta - expected) / dailyAllotment
        return min(max(raw, -1), 1)
    }

    // MARK: - Persistence & Housekeeping

    private func dataWeeks() -> Double {
        guard let first = polls.first, let last = polls.last else { return 0 }
        return last.timestamp.timeIntervalSince(first.timestamp) / 604800
    }

    private func pruneOldRecords() {
        guard let latest = polls.last else { return }
        let cutoff = latest.timestamp.addingTimeInterval(-Double(Self.maxDays) * 86400)
        polls.removeAll { $0.timestamp < cutoff }
        sessionStarts.removeAll { $0.timestamp < cutoff }
    }

    private func persist() {
        guard let url = persistURL else { return }
        DataStore.save(StoreData(polls: polls, sessions: sessionStarts, dailySnapshot: dailySnapshot), to: url)
    }
}
