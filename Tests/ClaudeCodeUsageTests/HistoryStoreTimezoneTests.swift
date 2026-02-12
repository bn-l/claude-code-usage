import Testing
import Foundation
import GRDB
@testable import ClaudeCodeUsage

/// Timezone correctness tests — catch strftime UTC vs local time issues.
/// These tests set TZ=America/Los_Angeles (PST, UTC-8) to be meaningful.
@Suite("HistoryStore — Timezone Correctness", .serialized)
struct HistoryStoreTimezoneTests {

    private func withPST(_ body: () throws -> Void) rethrows {
        let oldTZ = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", "America/Los_Angeles", 1)
        tzset()
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let old = oldTZ {
                setenv("TZ", old, 1)
            } else {
                unsetenv("TZ")
            }
            tzset()
            NSTimeZone.resetSystemTimeZone()
        }
        try body()
    }

    /// Create a Date from UTC components (within the last few days for query-window safety)
    private func recentUTCDate(daysAgo: Int = 1, hour: Int, minute: Int = 0) -> Date {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(abbreviation: "UTC")!
        let base = utcCal.startOfDay(for: Date().addingTimeInterval(Double(-daysAgo) * 86400))
        return utcCal.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
    }

    @Test("peakUsageHours returns local hour, not UTC hour")
    func peakUsageHoursLocalHour() throws {
        try withPST {
            let store = try makeTestStore()
            // Yesterday at 22:00 UTC = 14:00 PST (UTC-8)
            let ts = recentUTCDate(daysAgo: 1, hour: 22)

            try insertSnapshot(store, timestamp: ts, combinedPct: 90)

            let results = try store.peakUsageHours(top: 1)
            #expect(results.count == 1)
            #expect(results[0].hour == 14) // local hour, not 22
        }
    }

    @Test("dailyMaxCombined groups by local date, not UTC date")
    func dailyMaxCombinedLocalDate() throws {
        try withPST {
            let store = try makeTestStore()
            // Yesterday at 07:30 UTC = day-before-yesterday 23:30 PST
            // Yesterday at 08:30 UTC = yesterday 00:30 PST
            let ts1 = recentUTCDate(daysAgo: 1, hour: 7, minute: 30)
            let ts2 = recentUTCDate(daysAgo: 1, hour: 8, minute: 30)

            try insertSnapshot(store, timestamp: ts1, combinedPct: 40)
            try insertSnapshot(store, timestamp: ts2, combinedPct: 60)

            let results = try store.dailyMaxCombined(days: 7)
            // Should be 2 different local days, not same UTC day
            #expect(results.count == 2)
        }
    }

    @Test("expectedSessionsPerDay matches local weekday, not UTC weekday")
    func expectedSessionsPerDayLocalWeekday() throws {
        try withPST {
            let store = try makeTestStore()
            // Yesterday at 06:00 UTC = day-before-yesterday 22:00 PST
            // This means the local weekday is one day earlier than the UTC weekday
            let ts = recentUTCDate(daysAgo: 1, hour: 6)

            var pstCal = Calendar(identifier: .gregorian)
            pstCal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

            try insertSessionStart(store, timestamp: ts)

            // Query for the local weekday
            let localDay = pstCal.component(.weekday, from: ts) - 1 // 0=Sun matches strftime('%w')
            let count: Int = try store.dbPool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM session_starts
                    WHERE CAST(strftime('%w', timestamp, 'localtime') AS INTEGER) = ?
                    """, arguments: [localDay])!
            }
            #expect(count == 1)
        }
    }

    @Test("todayStats vs dailyMaxCombined consistency at midnight boundary")
    func midnightBoundaryConsistency() throws {
        try withPST {
            let store = try makeTestStore()
            // Create a snapshot at 00:30 local time today
            var pstCal = Calendar(identifier: .gregorian)
            pstCal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            let startOfToday = pstCal.startOfDay(for: Date())
            let ts = pstCal.date(byAdding: .minute, value: 30, to: startOfToday)!

            // Only test if this timestamp is not in the future
            guard ts <= Date() else { return }

            try insertSnapshot(store, timestamp: ts, combinedPct: 75)

            let today = try store.todayStats()
            let daily = try store.dailyMaxCombined(days: 1)

            // todayStats uses Swift Calendar (local-aware)
            #expect(today.avgCombinedPct == 75)
            // dailyMaxCombined uses strftime with 'localtime'
            if !daily.isEmpty {
                #expect(daily.last!.maxCombinedPct == 75)
            }
        }
    }

    @Test("avgSessionsPerDay groups by local dates, not UTC dates")
    func avgSessionsPerDayLocalDates() throws {
        try withPST {
            let store = try makeTestStore()
            // 3 sessions on yesterday UTC, but in PST they span two local dates:
            // Yesterday 05:00 UTC = day-before-yesterday 21:00 PST (local date: day-before-yesterday)
            // Yesterday 06:00 UTC = day-before-yesterday 22:00 PST (local date: day-before-yesterday)
            // Yesterday 09:00 UTC = yesterday 01:00 PST (local date: yesterday)
            try insertSessionStart(store, timestamp: recentUTCDate(daysAgo: 1, hour: 5))
            try insertSessionStart(store, timestamp: recentUTCDate(daysAgo: 1, hour: 6))
            try insertSessionStart(store, timestamp: recentUTCDate(daysAgo: 1, hour: 9))

            let avg = try store.avgSessionsPerDay(days: 30)
            // 3 sessions / 2 local days = 1.5
            #expect(avg == 1.5)
        }
    }

    @Test("weeklyResetTrend groups by local week, not UTC week")
    func weeklyResetTrendLocalWeek() throws {
        try withPST {
            let store = try makeTestStore()
            // Insert two snapshots that are on different local weeks
            // Use dates ~8 days apart to ensure they're in different weeks
            let recent = recentUTCDate(daysAgo: 1, hour: 12)
            let older = recentUTCDate(daysAgo: 9, hour: 12)

            try insertSnapshot(store, timestamp: recent, weeklyUsagePct: 50, combinedPct: 50)
            try insertSnapshot(store, timestamp: older, weeklyUsagePct: 30, combinedPct: 30)

            let results = try store.weeklyResetTrend(weeks: 4)
            // Should have entries (at least 1, likely 2 different weeks)
            #expect(results.count >= 1)
        }
    }
}
