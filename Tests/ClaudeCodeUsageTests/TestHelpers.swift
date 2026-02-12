import Foundation
import GRDB
@testable import ClaudeCodeUsage

func makeTestStore() throws -> HistoryStore {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    return try HistoryStore(path: tempDir.appendingPathComponent("test.db").path())
}

func insertSnapshot(
    _ store: HistoryStore,
    timestamp: Date = Date(),
    sessionUsagePct: Double = 50,
    weeklyUsagePct: Double = 30,
    sessionMinsLeft: Double = 150,
    weeklyMinsLeft: Double = 5000,
    sessionForecastPct: Double = 60,
    weeklyBudgetBurnPct: Double = 40,
    combinedPct: Double = 60
) throws {
    try store.dbPool.write { db in
        try db.execute(
            sql: """
                INSERT INTO usage_snapshots
                    (timestamp, session_usage_pct, weekly_usage_pct, session_mins_left,
                     weekly_mins_left, session_forecast_pct, weekly_budget_burn_pct, combined_pct)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [timestamp, sessionUsagePct, weeklyUsagePct, sessionMinsLeft,
                        weeklyMinsLeft, sessionForecastPct, weeklyBudgetBurnPct, combinedPct]
        )
    }
}

func insertSessionStart(
    _ store: HistoryStore,
    timestamp: Date = Date(),
    weeklyUsagePctAtStart: Double = 20,
    weeklyMinsLeftAtStart: Double = 8000
) throws {
    try store.dbPool.write { db in
        try db.execute(
            sql: """
                INSERT INTO session_starts (timestamp, weekly_usage_pct_at_start, weekly_mins_left_at_start)
                VALUES (?, ?, ?)
                """,
            arguments: [timestamp, weeklyUsagePctAtStart, weeklyMinsLeftAtStart]
        )
    }
}

func snapshotCount(_ store: HistoryStore) throws -> Int {
    try store.dbPool.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_snapshots")!
    }
}

func sessionStartCount(_ store: HistoryStore) throws -> Int {
    try store.dbPool.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_starts")!
    }
}
