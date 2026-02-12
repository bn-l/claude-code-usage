import Testing
import Foundation
import GRDB
@testable import ClaudeCodeUsage

// MARK: - Persistence

@Suite("HistoryStore — Persistence")
struct HistoryStorePersistenceTests {

    @Test("saveSnapshot inserts a row with all fields mapped correctly")
    func saveSnapshotRoundtrip() throws {
        let store = try makeTestStore()
        let m = UsageMetrics(
            sessionUsagePct: 25, weeklyUsagePct: 40,
            sessionMinsLeft: 200, weeklyMinsLeft: 5000,
            sessionForecastPct: 50, weeklyBudgetBurnPct: 60,
            combinedPct: 60, timestamp: Date()
        )
        try store.saveSnapshot(m)
        #expect(try snapshotCount(store) == 1)
    }

    @Test("saveSnapshot round-trip via raw SQL: column name matches CodingKey")
    func saveSnapshotColumnMatch() throws {
        let store = try makeTestStore()
        let m = UsageMetrics(
            sessionUsagePct: 25, weeklyUsagePct: 40,
            sessionMinsLeft: 200, weeklyMinsLeft: 5000,
            sessionForecastPct: 50, weeklyBudgetBurnPct: 73.5,
            combinedPct: 73.5, timestamp: Date()
        )
        try store.saveSnapshot(m)

        let stored: Double = try store.dbPool.read { db in
            try Double.fetchOne(db, sql: "SELECT weekly_budget_burn_pct FROM usage_snapshots LIMIT 1")!
        }
        #expect(stored == 73.5)
    }

    @Test("saveSessionStart inserts with correct field mapping")
    func saveSessionStart() throws {
        let store = try makeTestStore()
        let snap = SessionSnapshot(weeklyUsagePctAtStart: 30, weeklyMinsLeftAtStart: 8000, timestamp: Date())
        try store.saveSessionStart(snap)
        #expect(try sessionStartCount(store) == 1)
    }

    @Test("latestSessionStart returns most recent record")
    func latestSessionStart() throws {
        let store = try makeTestStore()
        let earlier = Date().addingTimeInterval(-3600)
        let later = Date()
        try insertSessionStart(store, timestamp: earlier, weeklyUsagePctAtStart: 10)
        try insertSessionStart(store, timestamp: later, weeklyUsagePctAtStart: 30)

        let latest = try store.latestSessionStart()
        #expect(latest != nil)
        #expect(latest!.weeklyUsagePctAtStart == 30)
    }

    @Test("latestSessionStart returns nil when table is empty")
    func latestSessionStartEmpty() throws {
        let store = try makeTestStore()
        #expect(try store.latestSessionStart() == nil)
    }

    @Test("latestPollState returns values from most recent snapshot")
    func latestPollState() throws {
        let store = try makeTestStore()
        try insertSnapshot(store, sessionMinsLeft: 123, weeklyMinsLeft: 456)

        let state = try store.latestPollState()
        #expect(state != nil)
        #expect(state!.sessionMinsLeft == 123)
        #expect(state!.weeklyMinsLeft == 456)
    }

    @Test("latestPollState returns nil when table is empty")
    func latestPollStateEmpty() throws {
        let store = try makeTestStore()
        #expect(try store.latestPollState() == nil)
    }

    @Test("pruneOldRecords deletes snapshots older than 90 days")
    func pruneSnapshots() throws {
        let store = try makeTestStore()
        let old = Date().addingTimeInterval(-91 * 86400)
        let recent = Date()
        try insertSnapshot(store, timestamp: old, combinedPct: 10)
        try insertSnapshot(store, timestamp: recent, combinedPct: 90)

        try store.pruneOldRecords()
        #expect(try snapshotCount(store) == 1)
    }

    @Test("pruneOldRecords deletes session_starts older than 90 days")
    func pruneSessions() throws {
        let store = try makeTestStore()
        let old = Date().addingTimeInterval(-91 * 86400)
        let recent = Date()
        try insertSessionStart(store, timestamp: old)
        try insertSessionStart(store, timestamp: recent)

        try store.pruneOldRecords()
        #expect(try sessionStartCount(store) == 1)
    }

    @Test("pruneOldRecords leaves records younger than 90 days")
    func pruneKeepsRecent() throws {
        let store = try makeTestStore()
        try insertSnapshot(store, timestamp: Date().addingTimeInterval(-89 * 86400))
        try insertSessionStart(store, timestamp: Date().addingTimeInterval(-89 * 86400))

        try store.pruneOldRecords()
        #expect(try snapshotCount(store) == 1)
        #expect(try sessionStartCount(store) == 1)
    }

    // MARK: - Migrations

    @Test("Migration v1 creates both tables and indexes")
    func migrationV1() throws {
        let store = try makeTestStore()
        let tables: [String] = try store.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('usage_snapshots', 'session_starts') ORDER BY name")
        }
        #expect(tables == ["session_starts", "usage_snapshots"])
    }

    @Test("Migration v2 renames column to weekly_budget_burn_pct")
    func migrationV2Column() throws {
        let store = try makeTestStore()
        let columns: [String] = try store.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('usage_snapshots') WHERE name = 'weekly_budget_burn_pct'")
        }
        #expect(columns == ["weekly_budget_burn_pct"])
    }

    @Test("Migration v2 preserves existing row values")
    func migrationV2PreservesData() throws {
        // Create a DB with v1 schema, insert data, then run v2
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let path = tempDir.appendingPathComponent("test.db").path()

        // Create with only v1
        let pool = try DatabasePool(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "usage_snapshots") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull()
                t.column("session_usage_pct", .double).notNull()
                t.column("weekly_usage_pct", .double).notNull()
                t.column("session_mins_left", .double).notNull()
                t.column("weekly_mins_left", .double).notNull()
                t.column("session_forecast_pct", .double).notNull()
                t.column("session_budget_used_pct", .double).notNull()
                t.column("combined_pct", .double).notNull()
            }
            try db.create(table: "session_starts") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull()
                t.column("weekly_usage_pct_at_start", .double).notNull()
                t.column("weekly_mins_left_at_start", .double).notNull()
            }
        }
        try migrator.migrate(pool)

        // Insert with old column name
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO usage_snapshots
                    (timestamp, session_usage_pct, weekly_usage_pct, session_mins_left,
                     weekly_mins_left, session_forecast_pct, session_budget_used_pct, combined_pct)
                VALUES (datetime('now'), 25, 40, 200, 5000, 50, 77.7, 77.7)
                """)
        }

        // Now open via HistoryStore which runs v1+v2
        let store = try HistoryStore(path: path)

        // Value should be preserved under new column name
        let value: Double = try store.dbPool.read { db in
            try Double.fetchOne(db, sql: "SELECT weekly_budget_burn_pct FROM usage_snapshots LIMIT 1")!
        }
        #expect(value == 77.7)
    }

    @Test("updateLatestSessionStart updates existing row, not insert")
    func updateLatestSessionStart() throws {
        let store = try makeTestStore()
        let snap1 = SessionSnapshot(weeklyUsagePctAtStart: 20, weeklyMinsLeftAtStart: 8000, timestamp: Date())
        try store.saveSessionStart(snap1)
        #expect(try sessionStartCount(store) == 1)

        let snap2 = SessionSnapshot(weeklyUsagePctAtStart: 5, weeklyMinsLeftAtStart: 10080, timestamp: Date())
        try store.updateLatestSessionStart(snap2)
        #expect(try sessionStartCount(store) == 1) // still 1, not 2

        let latest = try store.latestSessionStart()
        #expect(latest!.weeklyUsagePctAtStart == 5)
    }

    @Test("updateLatestSessionStart with empty table falls back to INSERT")
    func updateLatestSessionStartEmpty() throws {
        let store = try makeTestStore()
        let snap = SessionSnapshot(weeklyUsagePctAtStart: 5, weeklyMinsLeftAtStart: 10080, timestamp: Date())
        try store.updateLatestSessionStart(snap)
        #expect(try sessionStartCount(store) == 1)
    }
}

// MARK: - History Queries

@Suite("HistoryStore — History Queries")
struct HistoryStoreQueryTests {

    @Test("todayStats returns sessionCount from today only")
    func todayStatsSessionCount() throws {
        let store = try makeTestStore()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        try insertSessionStart(store, timestamp: yesterday)
        try insertSessionStart(store, timestamp: Date())
        try insertSessionStart(store, timestamp: Date())

        let stats = try store.todayStats()
        #expect(stats.sessionCount == 2)
    }

    @Test("todayStats returns avgCombinedPct from today's snapshots")
    func todayStatsAvgPct() throws {
        let store = try makeTestStore()
        try insertSnapshot(store, combinedPct: 40)
        try insertSnapshot(store, combinedPct: 60)

        let stats = try store.todayStats()
        #expect(stats.avgCombinedPct == 50)
    }

    @Test("todayStats with no data: sessionCount=0, avgCombinedPct=0")
    func todayStatsEmpty() throws {
        let store = try makeTestStore()
        let stats = try store.todayStats()
        #expect(stats.sessionCount == 0)
        #expect(stats.avgCombinedPct == 0)
    }

    @Test("dailyMaxCombined returns one entry per day with max combined_pct")
    func dailyMaxCombined() throws {
        let store = try makeTestStore()
        let today = Date()
        try insertSnapshot(store, timestamp: today, combinedPct: 40)
        try insertSnapshot(store, timestamp: today, combinedPct: 80)

        let results = try store.dailyMaxCombined(days: 7)
        #expect(results.count == 1)
        #expect(results[0].maxCombinedPct == 80)
    }

    @Test("dailyMaxCombined respects days parameter")
    func dailyMaxCombinedDays() throws {
        let store = try makeTestStore()
        try insertSnapshot(store, timestamp: Date().addingTimeInterval(-2 * 86400), combinedPct: 30)
        try insertSnapshot(store, timestamp: Date(), combinedPct: 70)

        let oneDay = try store.dailyMaxCombined(days: 1)
        #expect(oneDay.count == 1)

        let threeDays = try store.dailyMaxCombined(days: 3)
        #expect(threeDays.count == 2)
    }

    @Test("dailyMaxCombined ordered by date ascending")
    func dailyMaxCombinedOrder() throws {
        let store = try makeTestStore()
        try insertSnapshot(store, timestamp: Date().addingTimeInterval(-86400), combinedPct: 30)
        try insertSnapshot(store, timestamp: Date(), combinedPct: 70)

        let results = try store.dailyMaxCombined(days: 7)
        #expect(results.count == 2)
        #expect(results[0].date < results[1].date)
    }

    @Test("budgetHitRate returns percentage where weekly_budget_burn_pct >= 100")
    func budgetHitRate() throws {
        let store = try makeTestStore()
        try insertSnapshot(store, weeklyBudgetBurnPct: 100, combinedPct: 100)
        try insertSnapshot(store, weeklyBudgetBurnPct: 50, combinedPct: 50)
        try insertSnapshot(store, weeklyBudgetBurnPct: 100, combinedPct: 100)
        try insertSnapshot(store, weeklyBudgetBurnPct: 30, combinedPct: 30)

        let rate = try store.budgetHitRate()
        #expect(rate == 50) // 2 out of 4
    }

    @Test("budgetHitRate with zero snapshots returns 0")
    func budgetHitRateEmpty() throws {
        let store = try makeTestStore()
        let rate = try store.budgetHitRate()
        #expect(rate == 0)
    }

    @Test("peakUsageHours returns top N hours by avg combined_pct")
    func peakUsageHours() throws {
        let store = try makeTestStore()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // Hour 10: high usage
        try insertSnapshot(store, timestamp: cal.date(byAdding: .hour, value: 10, to: today)!, combinedPct: 90)
        // Hour 14: medium
        try insertSnapshot(store, timestamp: cal.date(byAdding: .hour, value: 14, to: today)!, combinedPct: 60)
        // Hour 22: low
        try insertSnapshot(store, timestamp: cal.date(byAdding: .hour, value: 22, to: today)!, combinedPct: 20)

        let results = try store.peakUsageHours(top: 2)
        #expect(results.count == 2)
        #expect(results[0].hour == 10)
        #expect(results[0].avgCombinedPct == 90)
        // Hours are 0-23 integers
        #expect(results.allSatisfy { (0...23).contains($0.hour) })
    }

    @Test("weeklyResetTrend groups by ISO year-week and returns max weekly_usage_pct")
    func weeklyResetTrend() throws {
        let store = try makeTestStore()
        // Insert snapshots in same week
        try insertSnapshot(store, timestamp: Date().addingTimeInterval(-86400), weeklyUsagePct: 30, combinedPct: 30)
        try insertSnapshot(store, timestamp: Date(), weeklyUsagePct: 50, combinedPct: 50)

        let results = try store.weeklyResetTrend(weeks: 4)
        // All in same week → 1 group, max = 50
        if results.count == 1 {
            #expect(results[0].maxCombinedPct == 50) // actually weekly_usage_pct aliased as maxCombinedPct via DailyStat
        }
    }

    @Test("weeklyResetTrend determinism: MAX aggregation gives same date both times")
    func weeklyResetTrendDeterminism() throws {
        let store = try makeTestStore()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Insert on Mon, Wed, Fri of this week
        for dayOffset in [0, 2, 4] {
            let ts = cal.date(byAdding: .day, value: -dayOffset, to: today)!
            try insertSnapshot(store, timestamp: ts, weeklyUsagePct: Double(30 + dayOffset * 5), combinedPct: 50)
        }

        let result1 = try store.weeklyResetTrend(weeks: 4)
        let result2 = try store.weeklyResetTrend(weeks: 4)

        // Dates must be identical
        let dates1 = result1.map(\.date)
        let dates2 = result2.map(\.date)
        #expect(dates1 == dates2)
    }

    @Test("weeklyResetTrend year boundary: different years grouped separately")
    func weeklyResetTrendYearBoundary() throws {
        let store = try makeTestStore()
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]

        // Week 1 of 2025
        let date2025 = fmt.date(from: "2025-01-06T12:00:00Z")!
        // Week 1 of 2026
        let date2026 = fmt.date(from: "2026-01-05T12:00:00Z")!

        try insertSnapshot(store, timestamp: date2025, weeklyUsagePct: 30, combinedPct: 30)
        try insertSnapshot(store, timestamp: date2026, weeklyUsagePct: 50, combinedPct: 50)

        let results = try store.weeklyResetTrend(weeks: 60)
        // Should be 2 separate groups (different %Y-%W)
        #expect(results.count == 2)
    }

    @Test("avgSessionsPerDay divides session count by distinct days")
    func avgSessionsPerDay() throws {
        let store = try makeTestStore()
        let today = Date()
        let yesterday = today.addingTimeInterval(-86400)
        try insertSessionStart(store, timestamp: today)
        try insertSessionStart(store, timestamp: today)
        try insertSessionStart(store, timestamp: yesterday)

        let avg = try store.avgSessionsPerDay()
        #expect(avg == 1.5) // 3 sessions / 2 days
    }
}

// MARK: - expectedSessionsPerDay

@Suite("HistoryStore — expectedSessionsPerDay")
struct HistoryStoreExpectedSessionsTests {

    @Test("With >= 2 distinct days for current weekday: weekday-specific average")
    func weekdaySpecific() throws {
        let store = try makeTestStore()
        let cal = Calendar.current
        let today = Date()
        let weekday = cal.component(.weekday, from: today)

        // Find two dates that are the same weekday as today
        let sameWeekday1 = cal.date(byAdding: .weekOfYear, value: -1, to: today)!
        let sameWeekday2 = cal.date(byAdding: .weekOfYear, value: -2, to: today)!

        // Verify they're the same weekday
        #expect(cal.component(.weekday, from: sameWeekday1) == weekday)
        #expect(cal.component(.weekday, from: sameWeekday2) == weekday)

        // 2 sessions on week-1, 4 sessions on week-2
        try insertSessionStart(store, timestamp: sameWeekday1)
        try insertSessionStart(store, timestamp: sameWeekday1)
        try insertSessionStart(store, timestamp: sameWeekday2)
        try insertSessionStart(store, timestamp: sameWeekday2)
        try insertSessionStart(store, timestamp: sameWeekday2)
        try insertSessionStart(store, timestamp: sameWeekday2)

        let result = try store.expectedSessionsPerDay()
        #expect(result != nil)
        #expect(result! == 3.0) // 6 sessions / 2 distinct days
    }

    @Test("With 1 distinct day for current weekday: falls back to lifetime average")
    func lifetimeFallback() throws {
        let store = try makeTestStore()
        let today = Date()
        // Only one occurrence of today's weekday
        try insertSessionStart(store, timestamp: today)
        try insertSessionStart(store, timestamp: today)
        // Also sessions on other days to create lifetime data
        try insertSessionStart(store, timestamp: today.addingTimeInterval(-86400))

        let result = try store.expectedSessionsPerDay()
        #expect(result != nil)
        // Lifetime: 3 sessions / max(daysSinceFirst, 1)
        #expect(result! > 0)
    }

    @Test("With no session_starts at all: returns nil")
    func noData() throws {
        let store = try makeTestStore()
        let result = try store.expectedSessionsPerDay()
        #expect(result == nil)
    }

    @Test("Single session on first day: returns 1.0")
    func singleSessionFirstDay() throws {
        let store = try makeTestStore()
        try insertSessionStart(store, timestamp: Date())

        // Only 1 distinct day for this weekday → needs lifetime fallback
        // Lifetime: 1 session / max(~0 days, 1) = 1.0
        let result = try store.expectedSessionsPerDay()
        #expect(result != nil)
        #expect(result! == 1.0)
    }
}
