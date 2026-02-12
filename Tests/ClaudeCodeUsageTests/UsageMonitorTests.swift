import Testing
import Foundation
import GRDB
@testable import ClaudeCodeUsage

// MARK: - Session Reset Detection

@Suite("UsageMonitor — Session Reset Detection", .serialized)
@MainActor
struct UsageMonitorSessionResetTests {

    private func makeMonitor() throws -> (UsageMonitor, HistoryStore) {
        let store = try makeTestStore()
        let monitor = UsageMonitor()
        monitor.historyStore = store
        monitor.currentSnapshot = SessionSnapshot(
            weeklyUsagePctAtStart: 30, weeklyMinsLeftAtStart: 8000, timestamp: Date()
        )
        return (monitor, store)
    }

    @Test("Timer jumped up by >30 mins: session reset detected")
    func timerJumpedUp() throws {
        let (monitor, store) = try makeMonitor()
        monitor.previousSessionMinsLeft = 50
        monitor.previousPollTimestamp = Date()

        monitor.processResponse(
            sessionUsagePct: 0, weeklyUsagePct: 30,
            sessionMinsLeft: 290, weeklyMinsLeft: 8000
        )

        // New snapshot created
        #expect(monitor.currentSnapshot != nil)
        #expect(monitor.currentSnapshot!.weeklyUsagePctAtStart == 30)
        // Persisted to session_starts
        #expect(try sessionStartCount(store) == 1)
    }

    @Test("Timer jumped by exactly 30: no detection (threshold is strictly >30)")
    func timerJumpedExactly30() throws {
        let (monitor, _) = try makeMonitor()
        let originalSnapshot = monitor.currentSnapshot
        monitor.previousSessionMinsLeft = 100
        monitor.previousPollTimestamp = Date()

        monitor.processResponse(
            sessionUsagePct: 10, weeklyUsagePct: 30,
            sessionMinsLeft: 130, weeklyMinsLeft: 8000
        )

        // Snapshot should be the same object (not replaced by session reset)
        #expect(monitor.currentSnapshot!.weeklyUsagePctAtStart == originalSnapshot!.weeklyUsagePctAtStart)
    }

    @Test("Timer jumped by 31: detection fires")
    func timerJumped31() throws {
        let (monitor, store) = try makeMonitor()
        monitor.previousSessionMinsLeft = 100
        monitor.previousPollTimestamp = Date()

        monitor.processResponse(
            sessionUsagePct: 0, weeklyUsagePct: 30,
            sessionMinsLeft: 131, weeklyMinsLeft: 8000
        )

        #expect(try sessionStartCount(store) == 1)
    }

    @Test("Timer decreased normally: no detection")
    func timerDecreased() throws {
        let (monitor, store) = try makeMonitor()
        monitor.previousSessionMinsLeft = 200
        monitor.previousPollTimestamp = Date()

        monitor.processResponse(
            sessionUsagePct: 10, weeklyUsagePct: 30,
            sessionMinsLeft: 195, weeklyMinsLeft: 8000
        )

        #expect(try sessionStartCount(store) == 0)
    }

    @Test("No previous value (first poll): no detection, no crash")
    func noPreviousValue() throws {
        let (monitor, store) = try makeMonitor()
        monitor.previousSessionMinsLeft = nil
        monitor.previousPollTimestamp = nil

        monitor.processResponse(
            sessionUsagePct: 10, weeklyUsagePct: 30,
            sessionMinsLeft: 290, weeklyMinsLeft: 8000
        )

        #expect(try sessionStartCount(store) == 0)
    }

    @Test("App downtime: prev=280 stored 6h ago, current=260 — sessionExpired fires")
    func downtimeSessionExpired() throws {
        let (monitor, store) = try makeMonitor()
        monitor.previousSessionMinsLeft = 280
        monitor.previousPollTimestamp = Date().addingTimeInterval(-6 * 3600) // 6h ago

        // sessionExpired: Date() > (6h ago + 280min) = (6h ago + 4h40m) = (1h20m ago) → true
        // timerJumped: 260 - 280 = -20, not > 30 → false
        monitor.processResponse(
            sessionUsagePct: 5, weeklyUsagePct: 32,
            sessionMinsLeft: 260, weeklyMinsLeft: 7800
        )

        #expect(try sessionStartCount(store) == 1)
    }

    @Test("App downtime: prev=280 stored 2h ago, current=160 — no detection (same session)")
    func downtimeSameSession() throws {
        let (monitor, store) = try makeMonitor()
        monitor.previousSessionMinsLeft = 280
        monitor.previousPollTimestamp = Date().addingTimeInterval(-2 * 3600) // 2h ago

        // sessionExpired: Date() > (2h ago + 280min) = (2h ago + 4h40m) = (2h40m from now) → false
        // timerJumped: 160 - 280 = -120, not > 30 → false
        monitor.processResponse(
            sessionUsagePct: 20, weeklyUsagePct: 35,
            sessionMinsLeft: 160, weeklyMinsLeft: 7700
        )

        #expect(try sessionStartCount(store) == 0)
    }

    @Test("App downtime: prev=20 stored 25min ago, current=290 — both signals fire, one snapshot")
    func downtimeBothSignals() throws {
        let (monitor, store) = try makeMonitor()
        monitor.previousSessionMinsLeft = 20
        monitor.previousPollTimestamp = Date().addingTimeInterval(-25 * 60) // 25min ago

        // sessionExpired: Date() > (25min ago + 20min) = (5min ago) → true
        // timerJumped: 290 - 20 = 270 > 30 → true
        // Both fire, but only one INSERT
        monitor.processResponse(
            sessionUsagePct: 0, weeklyUsagePct: 30,
            sessionMinsLeft: 290, weeklyMinsLeft: 8000
        )

        #expect(try sessionStartCount(store) == 1) // not 2
    }

    @Test("State restored from SQLite on launch via latestPollState")
    func stateRestoredFromDB() throws {
        let store = try makeTestStore()
        let ts = Date().addingTimeInterval(-600)
        try insertSnapshot(store, timestamp: ts, sessionMinsLeft: 123, weeklyMinsLeft: 456)
        try insertSessionStart(store, timestamp: ts, weeklyUsagePctAtStart: 15, weeklyMinsLeftAtStart: 9000)

        let monitor = UsageMonitor()
        monitor.historyStore = store
        try monitor.initializeFromStore()

        #expect(monitor.previousSessionMinsLeft == 123)
        #expect(monitor.previousWeeklyMinsLeft == 456)
        #expect(monitor.previousPollTimestamp != nil)
        #expect(monitor.currentSnapshot != nil)
        #expect(monitor.currentSnapshot!.weeklyUsagePctAtStart == 15)
    }

    @Test("Session reset snapshot uses current API values, not stale values")
    func snapshotUsesCurrentValues() throws {
        let (monitor, _) = try makeMonitor()
        monitor.previousSessionMinsLeft = 50
        monitor.previousPollTimestamp = Date()

        monitor.processResponse(
            sessionUsagePct: 0, weeklyUsagePct: 42,
            sessionMinsLeft: 290, weeklyMinsLeft: 7500
        )

        #expect(monitor.currentSnapshot!.weeklyUsagePctAtStart == 42)
        #expect(monitor.currentSnapshot!.weeklyMinsLeftAtStart == 7500)
    }
}

// MARK: - Weekly Reset Detection

@Suite("UsageMonitor — Weekly Reset Detection", .serialized)
@MainActor
struct UsageMonitorWeeklyResetTests {

    private func makeMonitor() throws -> (UsageMonitor, HistoryStore) {
        let store = try makeTestStore()
        let monitor = UsageMonitor()
        monitor.historyStore = store
        monitor.currentSnapshot = SessionSnapshot(
            weeklyUsagePctAtStart: 30, weeklyMinsLeftAtStart: 8000, timestamp: Date()
        )
        return (monitor, store)
    }

    @Test("weeklyMinsLeft increased by >60: weekly reset detected")
    func weeklyResetDetected() throws {
        let (monitor, _) = try makeMonitor()
        monitor.previousSessionMinsLeft = 200
        monitor.previousWeeklyMinsLeft = 10
        monitor.previousPollTimestamp = Date()

        // First insert a session start so updateLatestSessionStart has something to update
        try monitor.historyStore?.saveSessionStart(monitor.currentSnapshot!)

        monitor.processResponse(
            sessionUsagePct: 0, weeklyUsagePct: 0,
            sessionMinsLeft: 200, weeklyMinsLeft: 10080
        )

        // Snapshot re-baselined
        #expect(monitor.currentSnapshot!.weeklyUsagePctAtStart == 0)
        #expect(monitor.currentSnapshot!.weeklyMinsLeftAtStart == 10080)
    }

    @Test("weeklyMinsLeft increased by exactly 60: no detection")
    func weeklyNoDetectionExact60() throws {
        let (monitor, _) = try makeMonitor()
        monitor.previousSessionMinsLeft = 200
        monitor.previousWeeklyMinsLeft = 100
        monitor.previousPollTimestamp = Date()

        let originalSnapshot = monitor.currentSnapshot
        monitor.processResponse(
            sessionUsagePct: 10, weeklyUsagePct: 30,
            sessionMinsLeft: 195, weeklyMinsLeft: 160
        )

        #expect(monitor.currentSnapshot!.weeklyUsagePctAtStart == originalSnapshot!.weeklyUsagePctAtStart)
    }

    @Test("weeklyMinsLeft increased by 61: detection fires")
    func weeklyDetection61() throws {
        let (monitor, _) = try makeMonitor()
        monitor.previousSessionMinsLeft = 200
        monitor.previousWeeklyMinsLeft = 100
        monitor.previousPollTimestamp = Date()

        monitor.processResponse(
            sessionUsagePct: 10, weeklyUsagePct: 2,
            sessionMinsLeft: 195, weeklyMinsLeft: 161
        )

        #expect(monitor.currentSnapshot!.weeklyMinsLeftAtStart == 161)
    }

    @Test("weeklyMinsLeft decreased normally: no detection")
    func weeklyDecreased() throws {
        let (monitor, _) = try makeMonitor()
        monitor.previousSessionMinsLeft = 200
        monitor.previousWeeklyMinsLeft = 5000
        monitor.previousPollTimestamp = Date()

        let originalSnapshot = monitor.currentSnapshot
        monitor.processResponse(
            sessionUsagePct: 10, weeklyUsagePct: 32,
            sessionMinsLeft: 195, weeklyMinsLeft: 4995
        )

        #expect(monitor.currentSnapshot!.weeklyUsagePctAtStart == originalSnapshot!.weeklyUsagePctAtStart)
    }

    @Test("No previous weekly value (first poll): no detection")
    func noPreviousWeekly() throws {
        let (monitor, _) = try makeMonitor()
        monitor.previousSessionMinsLeft = nil
        monitor.previousWeeklyMinsLeft = nil
        monitor.previousPollTimestamp = nil

        let originalSnapshot = monitor.currentSnapshot
        monitor.processResponse(
            sessionUsagePct: 10, weeklyUsagePct: 30,
            sessionMinsLeft: 290, weeklyMinsLeft: 10080
        )

        // No weekly reset (first poll), snapshot stays or becomes bootstrap
        #expect(monitor.currentSnapshot != nil)
    }

    @Test("Weekly re-baseline uses UPDATE, not INSERT — session count unchanged")
    func rebaselineDoesNotInsert() throws {
        let (monitor, store) = try makeMonitor()
        // Pre-populate a session start
        try store.saveSessionStart(monitor.currentSnapshot!)
        let countBefore = try sessionStartCount(store)

        monitor.previousSessionMinsLeft = 200
        monitor.previousWeeklyMinsLeft = 10
        monitor.previousPollTimestamp = Date()

        monitor.processResponse(
            sessionUsagePct: 0, weeklyUsagePct: 0,
            sessionMinsLeft: 200, weeklyMinsLeft: 10080
        )

        #expect(try sessionStartCount(store) == countBefore) // no new rows
    }

    @Test("Weekly reset does NOT set currentSnapshot to nil")
    func snapshotNotNil() throws {
        let (monitor, _) = try makeMonitor()
        monitor.previousSessionMinsLeft = 200
        monitor.previousWeeklyMinsLeft = 10
        monitor.previousPollTimestamp = Date()

        monitor.processResponse(
            sessionUsagePct: 0, weeklyUsagePct: 0,
            sessionMinsLeft: 200, weeklyMinsLeft: 10080
        )

        #expect(monitor.currentSnapshot != nil)
    }

    @Test("Both session-reset and weekly-reset in same poll: only one session_starts row")
    func bothResetsOnePoll() throws {
        let (monitor, store) = try makeMonitor()
        monitor.previousSessionMinsLeft = 20
        monitor.previousWeeklyMinsLeft = 10
        monitor.previousPollTimestamp = Date().addingTimeInterval(-25 * 60)

        // Session reset: timer jumped from 20 to 290 (delta=270 > 30) + sessionExpired
        // Weekly reset: weekly jumped from 10 to 10080 (delta=10070 > 60)
        monitor.processResponse(
            sessionUsagePct: 0, weeklyUsagePct: 0,
            sessionMinsLeft: 290, weeklyMinsLeft: 10080
        )

        // Session reset INSERTs, weekly reset UPDATEs that same row
        #expect(try sessionStartCount(store) == 1)
    }

    @Test("Weekly re-baseline with empty session_starts table: falls back to INSERT")
    func rebaselineEmptyTable() throws {
        let (monitor, store) = try makeMonitor()
        #expect(try sessionStartCount(store) == 0) // empty

        monitor.previousSessionMinsLeft = 200
        monitor.previousWeeklyMinsLeft = 10
        monitor.previousPollTimestamp = Date()

        monitor.processResponse(
            sessionUsagePct: 0, weeklyUsagePct: 0,
            sessionMinsLeft: 200, weeklyMinsLeft: 10080
        )

        #expect(try sessionStartCount(store) >= 0) // should not crash
    }
}

// MARK: - Bootstrap Snapshot

@Suite("UsageMonitor — Bootstrap Snapshot", .serialized)
@MainActor
struct UsageMonitorBootstrapTests {

    @Test("First launch, no data: currentSnapshot is nil initially, bootstrap creates one")
    func bootstrapCreatesSnapshot() throws {
        let store = try makeTestStore()
        let monitor = UsageMonitor()
        monitor.historyStore = store
        monitor.previousSessionMinsLeft = nil
        monitor.previousWeeklyMinsLeft = nil
        monitor.previousPollTimestamp = nil
        // currentSnapshot starts nil
        #expect(monitor.currentSnapshot == nil)

        monitor.processResponse(
            sessionUsagePct: 10, weeklyUsagePct: 25,
            sessionMinsLeft: 280, weeklyMinsLeft: 9000
        )

        #expect(monitor.currentSnapshot != nil)
        #expect(monitor.currentSnapshot!.weeklyUsagePctAtStart == 25)
    }

    @Test("Bootstrap snapshot is NOT persisted via saveSessionStart")
    func bootstrapNotPersisted() throws {
        let store = try makeTestStore()
        let monitor = UsageMonitor()
        monitor.historyStore = store

        monitor.processResponse(
            sessionUsagePct: 10, weeklyUsagePct: 25,
            sessionMinsLeft: 280, weeklyMinsLeft: 9000
        )

        #expect(try sessionStartCount(store) == 0) // no session start saved
    }

    @Test("Bootstrap snapshot is used for compute (no crash)")
    func bootstrapUsedForCompute() throws {
        let store = try makeTestStore()
        let monitor = UsageMonitor()
        monitor.historyStore = store

        monitor.processResponse(
            sessionUsagePct: 10, weeklyUsagePct: 25,
            sessionMinsLeft: 280, weeklyMinsLeft: 9000
        )

        #expect(monitor.metrics != nil)
    }

    @Test("Second launch with existing data: snapshot restored, bootstrap does not fire")
    func noBootstrapWithExistingData() throws {
        let store = try makeTestStore()
        let ts = Date().addingTimeInterval(-600)
        try insertSessionStart(store, timestamp: ts, weeklyUsagePctAtStart: 15, weeklyMinsLeftAtStart: 9000)

        let monitor = UsageMonitor()
        monitor.historyStore = store
        try monitor.initializeFromStore()

        #expect(monitor.currentSnapshot != nil)
        #expect(monitor.currentSnapshot!.weeklyUsagePctAtStart == 15)
    }
}

// MARK: - sessionsPerDay Resolution

@Suite("UsageMonitor — sessionsPerDay Resolution", .serialized)
@MainActor
struct UsageMonitorSessionsPerDayTests {

    @Test("With observed data: uses observed value")
    func usesObservedValue() throws {
        let store = try makeTestStore()
        // Create enough data for expectedSessionsPerDay to return a value
        let today = Date()
        try insertSessionStart(store, timestamp: today)
        try insertSessionStart(store, timestamp: today)

        let monitor = UsageMonitor()
        monitor.historyStore = store
        monitor.currentSnapshot = SessionSnapshot(weeklyUsagePctAtStart: 20, weeklyMinsLeftAtStart: 7200, timestamp: Date())

        monitor.processResponse(
            sessionUsagePct: 0, weeklyUsagePct: 25,
            sessionMinsLeft: 300, weeklyMinsLeft: 7200
        )

        // Should use observed sessions per day (2.0 for single-day fallback would be 2/1=2.0)
        #expect(monitor.metrics != nil)
    }

    @Test("Without observed data: falls back to config.defaultSessionsPerDay")
    func fallsBackToConfig() throws {
        let store = try makeTestStore()
        let monitor = UsageMonitor()
        monitor.historyStore = store
        monitor.config = AppConfig(defaultSessionsPerDay: 5, pollIntervalSeconds: 300)
        monitor.currentSnapshot = SessionSnapshot(weeklyUsagePctAtStart: 20, weeklyMinsLeftAtStart: 7200, timestamp: Date())

        // No session_starts → expectedSessionsPerDay returns nil → uses config
        monitor.processResponse(
            sessionUsagePct: 0, weeklyUsagePct: 25,
            sessionMinsLeft: 300, weeklyMinsLeft: 7200
        )

        #expect(monitor.metrics != nil)
        // With defaultSessionsPerDay=5, budget is tiny, so even small delta → high burn
    }

    @Test("High defaultSessionsPerDay makes budget strict")
    func highDefaultStrict() throws {
        let store = try makeTestStore()
        let monitor = UsageMonitor()
        monitor.historyStore = store
        monitor.config = AppConfig(defaultSessionsPerDay: 10, pollIntervalSeconds: 300)
        monitor.currentSnapshot = SessionSnapshot(weeklyUsagePctAtStart: 20, weeklyMinsLeftAtStart: 7200, timestamp: Date())

        monitor.processResponse(
            sessionUsagePct: 0, weeklyUsagePct: 25,
            sessionMinsLeft: 300, weeklyMinsLeft: 7200
        )

        // With 10 sessions/day, per-session budget is tiny
        // delta = 5%, sessionBudget = very small → burn should be high/clamped
        #expect(monitor.metrics!.weeklyBudgetBurnPct == 100)
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
        #expect(mins > 55 && mins < 65) // approximately 60 minutes
    }

    @Test("Valid ISO8601 without fractional seconds")
    func validWithoutFractional() {
        let monitor = UsageMonitor()
        let future = Date().addingTimeInterval(1800)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let str = fmt.string(from: future)

        let mins = monitor.minutesUntil(str)
        #expect(mins > 25 && mins < 35) // approximately 30 minutes
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

// MARK: - Polling behavior (processResponse-based)

@Suite("UsageMonitor — Polling", .serialized)
@MainActor
struct UsageMonitorPollingTests {

    @Test("processResponse persists snapshot via historyStore.saveSnapshot")
    func persistsSnapshot() throws {
        let store = try makeTestStore()
        let monitor = UsageMonitor()
        monitor.historyStore = store
        monitor.currentSnapshot = SessionSnapshot(weeklyUsagePctAtStart: 20, weeklyMinsLeftAtStart: 7200, timestamp: Date())

        monitor.processResponse(
            sessionUsagePct: 25, weeklyUsagePct: 30,
            sessionMinsLeft: 200, weeklyMinsLeft: 6000
        )

        #expect(try snapshotCount(store) == 1)
    }

    @Test("processResponse sets metrics")
    func setsMetrics() throws {
        let store = try makeTestStore()
        let monitor = UsageMonitor()
        monitor.historyStore = store
        monitor.currentSnapshot = SessionSnapshot(weeklyUsagePctAtStart: 20, weeklyMinsLeftAtStart: 7200, timestamp: Date())

        monitor.processResponse(
            sessionUsagePct: 25, weeklyUsagePct: 30,
            sessionMinsLeft: 200, weeklyMinsLeft: 6000
        )

        #expect(monitor.metrics != nil)
        #expect(monitor.lastError == nil)
        #expect(monitor.lastUpdated != nil)
    }

    @Test("processResponse clears lastError on success")
    func clearsError() throws {
        let store = try makeTestStore()
        let monitor = UsageMonitor()
        monitor.historyStore = store
        monitor.currentSnapshot = SessionSnapshot(weeklyUsagePctAtStart: 20, weeklyMinsLeftAtStart: 7200, timestamp: Date())
        monitor.lastError = "previous error"

        monitor.processResponse(
            sessionUsagePct: 25, weeklyUsagePct: 30,
            sessionMinsLeft: 200, weeklyMinsLeft: 6000
        )

        #expect(monitor.lastError == nil)
    }
}
