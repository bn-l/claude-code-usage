import Foundation
import GRDB
import OSLog

private let logger = Logger(subsystem: "com.bml.claude-code-usage", category: "History")

final class HistoryStore: Sendable {
    let dbPool: DatabasePool

    convenience init() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/claude-code-usage")
        logger.debug("Creating database directory: path=\(dir.path(), privacy: .public)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try self.init(path: dir.appending(path: "history.db").path())
    }

    init(path: String) throws {
        logger.debug("Opening database pool: path=\(path, privacy: .public)")
        dbPool = try DatabasePool(path: path)

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            logger.debug("Running migration v1: creating tables and indexes")
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

            try db.create(indexOn: "usage_snapshots", columns: ["timestamp"])
            try db.create(indexOn: "session_starts", columns: ["timestamp"])
            logger.info("Migration v1 complete: tables and indexes created")
        }
        migrator.registerMigration("v2") { db in
            logger.debug("Running migration v2: renaming session_budget_used_pct column")
            try db.alter(table: "usage_snapshots") { t in
                t.rename(column: "session_budget_used_pct", to: "weekly_budget_burn_pct")
            }
            logger.info("Migration v2 complete: column renamed")
        }
        try migrator.migrate(dbPool)
        logger.info("HistoryStore initialized: path=\(path, privacy: .public)")
    }

    // MARK: - Write

    func saveSnapshot(_ m: UsageMetrics) throws {
        logger.debug("Saving snapshot: combinedPct=\(m.combinedPct, privacy: .public) sessionUsagePct=\(m.sessionUsagePct, privacy: .public) weeklyUsagePct=\(m.weeklyUsagePct, privacy: .public) timestamp=\(m.timestamp, privacy: .public)")
        try dbPool.write { db in
            try SnapshotRecord(
                timestamp: m.timestamp,
                sessionUsagePct: m.sessionUsagePct,
                weeklyUsagePct: m.weeklyUsagePct,
                sessionMinsLeft: m.sessionMinsLeft,
                weeklyMinsLeft: m.weeklyMinsLeft,
                sessionForecastPct: m.sessionForecastPct,
                weeklyBudgetBurnPct: m.weeklyBudgetBurnPct,
                combinedPct: m.combinedPct
            ).insert(db)
        }
        logger.trace("Snapshot saved successfully")
    }

    func saveSessionStart(_ s: SessionSnapshot) throws {
        logger.info("Saving session start: weeklyUsagePctAtStart=\(s.weeklyUsagePctAtStart, privacy: .public) weeklyMinsLeftAtStart=\(s.weeklyMinsLeftAtStart, privacy: .public) timestamp=\(s.timestamp, privacy: .public)")
        try dbPool.write { db in
            try SessionStartRecord(
                timestamp: s.timestamp,
                weeklyUsagePctAtStart: s.weeklyUsagePctAtStart,
                weeklyMinsLeftAtStart: s.weeklyMinsLeftAtStart
            ).insert(db)
        }
        logger.info("Session start saved")
    }

    func updateLatestSessionStart(_ s: SessionSnapshot) throws {
        logger.info("Updating latest session start (weekly re-baseline): weeklyUsagePctAtStart=\(s.weeklyUsagePctAtStart, privacy: .public) weeklyMinsLeftAtStart=\(s.weeklyMinsLeftAtStart, privacy: .public)")
        try dbPool.write { db in
            try db.execute(sql: """
                UPDATE session_starts
                SET weekly_usage_pct_at_start = ?, weekly_mins_left_at_start = ?, timestamp = ?
                WHERE id = (SELECT id FROM session_starts ORDER BY timestamp DESC LIMIT 1)
                """, arguments: [s.weeklyUsagePctAtStart, s.weeklyMinsLeftAtStart, s.timestamp])
            if db.changesCount == 0 {
                logger.info("No existing session start to update, inserting new row")
                try SessionStartRecord(
                    timestamp: s.timestamp,
                    weeklyUsagePctAtStart: s.weeklyUsagePctAtStart,
                    weeklyMinsLeftAtStart: s.weeklyMinsLeftAtStart
                ).insert(db)
            } else {
                logger.info("Latest session start updated successfully")
            }
        }
    }

    func latestSessionStart() throws -> SessionSnapshot? {
        logger.debug("Querying latest session start")
        let result = try dbPool.read { db in
            guard let record = try SessionStartRecord
                .order(Column("timestamp").desc)
                .fetchOne(db) else { return nil as SessionSnapshot? }
            return SessionSnapshot(
                weeklyUsagePctAtStart: record.weeklyUsagePctAtStart,
                weeklyMinsLeftAtStart: record.weeklyMinsLeftAtStart,
                timestamp: record.timestamp
            )
        }
        if let r = result {
            logger.debug("Latest session start found: weeklyUsagePctAtStart=\(r.weeklyUsagePctAtStart, privacy: .public) weeklyMinsLeftAtStart=\(r.weeklyMinsLeftAtStart, privacy: .public) timestamp=\(r.timestamp, privacy: .public)")
        } else {
            logger.debug("No session start records found")
        }
        return result
    }

    func latestPollState() throws -> (sessionMinsLeft: Double, weeklyMinsLeft: Double, timestamp: Date)? {
        logger.debug("Querying latest poll state")
        let result: (sessionMinsLeft: Double, weeklyMinsLeft: Double, timestamp: Date)? = try dbPool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT session_mins_left, weekly_mins_left, timestamp
                FROM usage_snapshots ORDER BY timestamp DESC LIMIT 1
                """)
            guard let sMins: Double = row?["session_mins_left"],
                  let wMins: Double = row?["weekly_mins_left"],
                  let ts: Date = row?["timestamp"] else { return nil }
            return (sMins, wMins, ts)
        }
        if let r = result {
            logger.debug("Latest poll state found: sessionMinsLeft=\(r.sessionMinsLeft, privacy: .public) weeklyMinsLeft=\(r.weeklyMinsLeft, privacy: .public) timestamp=\(r.timestamp, privacy: .public)")
        } else {
            logger.debug("No poll state records found")
        }
        return result
    }

    func pruneOldRecords() throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        logger.debug("Pruning records older than: cutoff=\(cutoff, privacy: .public)")
        try dbPool.write { db in
            let snapshotCount = try SnapshotRecord
                .filter(Column("timestamp") < cutoff)
                .deleteAll(db)
            let sessionCount = try SessionStartRecord
                .filter(Column("timestamp") < cutoff)
                .deleteAll(db)
            if snapshotCount > 0 || sessionCount > 0 {
                logger.info("Pruned old records: snapshots=\(snapshotCount, privacy: .public) sessions=\(sessionCount, privacy: .public)")
            }
        }
    }

    // MARK: - History Queries

    struct TodayStats: Sendable {
        let sessionCount: Int
        let avgCombinedPct: Double
    }

    struct DailyStat: Sendable {
        let date: String
        let maxCombinedPct: Double
    }

    struct HourlyStat: Sendable {
        let hour: Int
        let avgCombinedPct: Double
    }

    func todayStats() throws -> TodayStats {
        logger.debug("Querying today's stats")
        let stats = try dbPool.read { db in
            let startOfDay = Calendar.current.startOfDay(for: Date())
            let sessionCount = try SessionStartRecord
                .filter(Column("timestamp") >= startOfDay)
                .fetchCount(db)
            let row = try Row.fetchOne(db, sql: """
                SELECT COALESCE(AVG(combined_pct), 0) AS avg_pct
                FROM usage_snapshots WHERE timestamp >= ?
                """, arguments: [startOfDay])
            return TodayStats(
                sessionCount: sessionCount,
                avgCombinedPct: row?["avg_pct"] ?? 0
            )
        }
        logger.debug("Today's stats: sessionCount=\(stats.sessionCount, privacy: .public) avgCombinedPct=\(stats.avgCombinedPct, privacy: .public)")
        return stats
    }

    func dailyMaxCombined(days: Int = 7) throws -> [DailyStat] {
        logger.debug("Querying daily max combined: days=\(days, privacy: .public)")
        let results = try dbPool.read { db in
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
            let rows = try Row.fetchAll(db, sql: """
                SELECT strftime('%Y-%m-%d', timestamp, 'localtime') AS day, MAX(combined_pct) AS max_pct
                FROM usage_snapshots WHERE timestamp >= ?
                GROUP BY day ORDER BY day
                """, arguments: [cutoff])
            return rows.map { DailyStat(date: $0["day"], maxCombinedPct: $0["max_pct"]) }
        }
        logger.debug("Daily max combined: count=\(results.count, privacy: .public)")
        return results
    }

    func budgetHitRate(days: Int = 7) throws -> Double {
        logger.debug("Querying budget hit rate: days=\(days, privacy: .public)")
        let rate = try dbPool.read { db in
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    COUNT(CASE WHEN weekly_budget_burn_pct >= 100 THEN 1 END) * 100.0
                    / MAX(COUNT(*), 1) AS hit_rate
                FROM usage_snapshots WHERE timestamp >= ?
                """, arguments: [cutoff])
            return (row?["hit_rate"] ?? 0) as Double
        }
        logger.debug("Budget hit rate: rate=\(rate, privacy: .public)%")
        return rate
    }

    func peakUsageHours(top: Int = 3) throws -> [HourlyStat] {
        logger.debug("Querying peak usage hours: top=\(top, privacy: .public)")
        let results = try dbPool.read { db in
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            let rows = try Row.fetchAll(db, sql: """
                SELECT CAST(strftime('%H', timestamp, 'localtime') AS INTEGER) AS hour,
                       AVG(combined_pct) AS avg_pct
                FROM usage_snapshots WHERE timestamp >= ?
                GROUP BY hour ORDER BY avg_pct DESC LIMIT ?
                """, arguments: [cutoff, top])
            return rows.map { HourlyStat(hour: $0["hour"], avgCombinedPct: $0["avg_pct"]) }
        }
        logger.debug("Peak usage hours: count=\(results.count, privacy: .public) hours=\(results.map(\.hour), privacy: .public)")
        return results
    }

    func weeklyResetTrend(weeks: Int = 4) throws -> [DailyStat] {
        logger.debug("Querying weekly reset trend: weeks=\(weeks, privacy: .public)")
        let results = try dbPool.read { db in
            let cutoff = Calendar.current.date(byAdding: .day, value: -weeks * 7, to: Date())!
            let rows = try Row.fetchAll(db, sql: """
                SELECT MAX(strftime('%Y-%m-%d', timestamp, 'localtime')) AS day,
                       MAX(weekly_usage_pct) AS max_pct
                FROM usage_snapshots WHERE timestamp >= ?
                GROUP BY strftime('%Y-%W', timestamp, 'localtime')
                ORDER BY day DESC LIMIT ?
                """, arguments: [cutoff, weeks])
            return rows.map { DailyStat(date: $0["day"], maxCombinedPct: $0["max_pct"]) }
        }
        logger.debug("Weekly reset trend: count=\(results.count, privacy: .public)")
        return results
    }

    func avgSessionsPerDay(days: Int = 7) throws -> Double {
        logger.debug("Querying avg sessions per day: days=\(days, privacy: .public)")
        let avg = try dbPool.read { db in
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
            let row = try Row.fetchOne(db, sql: """
                SELECT CAST(COUNT(*) AS REAL)
                    / MAX(COUNT(DISTINCT strftime('%Y-%m-%d', timestamp, 'localtime')), 1) AS avg_per_day
                FROM session_starts WHERE timestamp >= ?
                """, arguments: [cutoff])
            return (row?["avg_per_day"] ?? 0) as Double
        }
        logger.debug("Avg sessions per day: avg=\(avg, privacy: .public)")
        return avg
    }

    func expectedSessionsPerDay() throws -> Double? {
        logger.debug("Querying expected sessions per day")
        let result = try dbPool.read { db -> Double? in
            let weekday = Calendar.current.component(.weekday, from: Date()) - 1 // 0=Sun matches strftime('%w')

            // Try weekday-specific average (need >= 2 distinct days for this weekday)
            let wdRow = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS total,
                       COUNT(DISTINCT strftime('%Y-%m-%d', timestamp, 'localtime')) AS distinct_days
                FROM session_starts
                WHERE CAST(strftime('%w', timestamp, 'localtime') AS INTEGER) = ?
                """, arguments: [weekday])
            if let total: Int = wdRow?["total"],
               let distinctDays: Int = wdRow?["distinct_days"],
               distinctDays >= 2 {
                let avg = Double(total) / Double(distinctDays)
                logger.debug("Weekday-specific sessionsPerDay: weekday=\(weekday, privacy: .public) avg=\(avg, privacy: .public) distinctDays=\(distinctDays, privacy: .public)")
                return avg
            }

            // Fall back to overall lifetime average
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS total, MIN(timestamp) AS first_ts
                FROM session_starts
                """)
            guard let total: Int = row?["total"], total > 0,
                  let firstTs: Date = row?["first_ts"] else { return nil }
            let daysSinceFirst = max(Date().timeIntervalSince(firstTs) / 86400, 1)
            let avg = Double(total) / daysSinceFirst
            logger.debug("Lifetime fallback sessionsPerDay: avg=\(avg, privacy: .public) days=\(daysSinceFirst, privacy: .public)")
            return avg
        }
        if result == nil {
            logger.debug("No session data for sessionsPerDay calculation")
        }
        return result
    }
}

// MARK: - GRDB Records

private struct SnapshotRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "usage_snapshots"

    var id: Int64?
    var timestamp: Date
    var sessionUsagePct: Double
    var weeklyUsagePct: Double
    var sessionMinsLeft: Double
    var weeklyMinsLeft: Double
    var sessionForecastPct: Double
    var weeklyBudgetBurnPct: Double
    var combinedPct: Double

    enum CodingKeys: String, CodingKey {
        case id, timestamp
        case sessionUsagePct = "session_usage_pct"
        case weeklyUsagePct = "weekly_usage_pct"
        case sessionMinsLeft = "session_mins_left"
        case weeklyMinsLeft = "weekly_mins_left"
        case sessionForecastPct = "session_forecast_pct"
        case weeklyBudgetBurnPct = "weekly_budget_burn_pct"
        case combinedPct = "combined_pct"
    }
}

private struct SessionStartRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "session_starts"

    var id: Int64?
    var timestamp: Date
    var weeklyUsagePctAtStart: Double
    var weeklyMinsLeftAtStart: Double

    enum CodingKeys: String, CodingKey {
        case id, timestamp
        case weeklyUsagePctAtStart = "weekly_usage_pct_at_start"
        case weeklyMinsLeftAtStart = "weekly_mins_left_at_start"
    }
}
