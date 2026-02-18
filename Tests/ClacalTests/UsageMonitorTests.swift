import Testing
import Foundation
@testable import Clacal

// MARK: - Session Reset Detection (via Optimiser)

@Suite("UsageMonitor — Session Reset Detection", .serialized)
@MainActor
struct UsageMonitorSessionResetTests {

    @Test("Timer jumped up by >30 mins: new session in optimiser")
    func timerJumpedUp() {
        let now = Date()
        let data = makeStoreData(
            polls: [(now.addingTimeInterval(-300), 20, 50, 30, 8000)],
            sessions: [(now.addingTimeInterval(-3600), 25, 8500)]
        )
        let monitor = makeTestMonitor(data: data)

        monitor.processResponse(
            sessionUsagePct: 0, weeklyUsagePct: 30,
            sessionMinsLeft: 290, weeklyMinsLeft: 8000
        )

        #expect(monitor.optimiser!.sessionStarts.count == 2) // original + new
    }

    @Test("Timer decreased normally: no new session")
    func timerDecreased() {
        let now = Date()
        let data = makeStoreData(
            polls: [(now.addingTimeInterval(-300), 10, 200, 30, 8000)],
            sessions: [(now.addingTimeInterval(-3600), 25, 8500)]
        )
        let monitor = makeTestMonitor(data: data)

        monitor.processResponse(
            sessionUsagePct: 12, weeklyUsagePct: 31,
            sessionMinsLeft: 195, weeklyMinsLeft: 7995
        )

        #expect(monitor.optimiser!.sessionStarts.count == 1) // only original
    }

    @Test("App downtime: session must have expired")
    func downtimeSessionExpired() {
        let now = Date()
        let data = makeStoreData(
            polls: [(now.addingTimeInterval(-6 * 3600), 20, 280, 30, 8000)],
            sessions: [(now.addingTimeInterval(-7 * 3600), 25, 8500)]
        )
        let monitor = makeTestMonitor(data: data)

        monitor.processResponse(
            sessionUsagePct: 5, weeklyUsagePct: 32,
            sessionMinsLeft: 260, weeklyMinsLeft: 7800
        )

        #expect(monitor.optimiser!.sessionStarts.count == 2)
    }

    @Test("First poll: bootstrap session detected")
    func firstPollBootstrap() {
        let monitor = makeTestMonitor()

        monitor.processResponse(
            sessionUsagePct: 10, weeklyUsagePct: 25,
            sessionMinsLeft: 280, weeklyMinsLeft: 9000
        )

        #expect(monitor.optimiser!.sessionStarts.count == 1)
        #expect(monitor.metrics != nil)
    }
}

// MARK: - minutesUntil

@Suite("UsageMonitor — minutesUntil")
@MainActor
struct UsageMonitorMinutesUntilTests {

    @Test("Valid ISO8601 with fractional seconds")
    func validWithFractional() {
        let monitor = UsageMonitor()
        let future = Date().addingTimeInterval(3600)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let str = fmt.string(from: future)

        let mins = monitor.minutesUntil(str)
        #expect(mins > 55 && mins < 65)
    }

    @Test("Valid ISO8601 without fractional seconds")
    func validWithoutFractional() {
        let monitor = UsageMonitor()
        let future = Date().addingTimeInterval(1800)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let str = fmt.string(from: future)

        let mins = monitor.minutesUntil(str)
        #expect(mins > 25 && mins < 35)
    }

    @Test("Date in the past: returns 0")
    func pastDate() {
        let monitor = UsageMonitor()
        let mins = monitor.minutesUntil("2020-01-01T00:00:00Z")
        #expect(mins == 0)
    }

    @Test("nil input: returns 0")
    func nilInput() {
        let monitor = UsageMonitor()
        let mins = monitor.minutesUntil(nil)
        #expect(mins == 0)
    }

    @Test("Malformed string: returns 0")
    func malformedString() {
        let monitor = UsageMonitor()
        let mins = monitor.minutesUntil("not-a-date")
        #expect(mins == 0)
    }
}

// MARK: - Polling behavior

@Suite("UsageMonitor — Polling", .serialized)
@MainActor
struct UsageMonitorPollingTests {

    @Test("processResponse sets metrics")
    func setsMetrics() {
        let monitor = makeTestMonitor()

        monitor.processResponse(
            sessionUsagePct: 25, weeklyUsagePct: 30,
            sessionMinsLeft: 200, weeklyMinsLeft: 6000
        )

        #expect(monitor.metrics != nil)
        #expect(monitor.metrics!.sessionUsagePct == 25)
        #expect(monitor.metrics!.weeklyUsagePct == 30)
        #expect(monitor.errors.isEmpty)
        #expect(monitor.lastUpdated != nil)
    }

    @Test("processResponse clears errors on success")
    func clearsError() {
        let monitor = makeTestMonitor()
        monitor.errors = [AppError(message: "previous error")]

        monitor.processResponse(
            sessionUsagePct: 25, weeklyUsagePct: 30,
            sessionMinsLeft: 200, weeklyMinsLeft: 6000
        )

        #expect(monitor.errors.isEmpty)
    }

    @Test("Metrics contain calibrator from optimiser")
    func metricsHaveCalibrator() {
        let monitor = makeTestMonitor()

        monitor.processResponse(
            sessionUsagePct: 25, weeklyUsagePct: 30,
            sessionMinsLeft: 200, weeklyMinsLeft: 6000
        )

        #expect(monitor.metrics!.calibrator >= -1)
        #expect(monitor.metrics!.calibrator <= 1)
    }

    @Test("Metrics contain sessionTarget from optimiser")
    func metricsHaveTarget() {
        let monitor = makeTestMonitor()

        monitor.processResponse(
            sessionUsagePct: 25, weeklyUsagePct: 30,
            sessionMinsLeft: 200, weeklyMinsLeft: 6000
        )

        #expect(monitor.metrics!.sessionTarget >= 10)
        #expect(monitor.metrics!.sessionTarget <= 100)
    }

    @Test("Multiple processResponse calls accumulate polls in optimiser")
    func accumulatesPolls() {
        let monitor = makeTestMonitor()

        monitor.processResponse(
            sessionUsagePct: 10, weeklyUsagePct: 20,
            sessionMinsLeft: 280, weeklyMinsLeft: 8000
        )
        monitor.processResponse(
            sessionUsagePct: 15, weeklyUsagePct: 21,
            sessionMinsLeft: 275, weeklyMinsLeft: 7995
        )

        #expect(monitor.optimiser!.polls.count == 2)
    }

    @Test("ensureOptimiser creates optimiser on first processResponse")
    func lazyInit() {
        let monitor = UsageMonitor()
        #expect(monitor.optimiser == nil)

        monitor.processResponse(
            sessionUsagePct: 10, weeklyUsagePct: 20,
            sessionMinsLeft: 280, weeklyMinsLeft: 8000
        )

        #expect(monitor.optimiser != nil)
    }
}
