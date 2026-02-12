import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.bml.claude-code-usage", category: "HistoryView")

struct HistoryView: View {
    let monitor: UsageMonitor

    @State private var todayStats: HistoryStore.TodayStats?
    @State private var dailyTrend: [HistoryStore.DailyStat] = []
    @State private var budgetHitRate: Double = 0
    @State private var peakHours: [HistoryStore.HourlyStat] = []
    @State private var avgSessionsPerDay: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            if let today = todayStats {
                StatRow(label: "Today's sessions", value: "\(today.sessionCount)")
                StatRow(label: "Today's avg usage", value: "\(Int(today.avgCombinedPct))%")
            }

            if !dailyTrend.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("7-day trend (daily max)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 2) {
                        ForEach(dailyTrend, id: \.date) { stat in
                            VStack(spacing: 1) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(ColorTier(combinedPct: stat.maxCombinedPct).color)
                                    .frame(
                                        width: 28,
                                        height: CGFloat(stat.maxCombinedPct) / 100 * 30
                                    )
                                Text(String(stat.date.suffix(2)))
                                    .font(.system(size: 8))
                                    .foregroundStyle(.quaternary)
                            }
                        }
                    }
                    .frame(height: 42, alignment: .bottom)
                }
            }

            StatRow(
                label: "Budget hit rate (7d)",
                value: String(format: "%.0f%%", budgetHitRate)
            )
            StatRow(
                label: "Avg sessions/day (7d)",
                value: String(format: "%.1f", avgSessionsPerDay)
            )

            if !peakHours.isEmpty {
                StatRow(
                    label: "Peak hours",
                    value: peakHours.map { String(format: "%02d:00", $0.hour) }.joined(separator: ", ")
                )
            }
        }
        .task(id: monitor.lastUpdated) {
            loadHistory()
        }
    }

    private func loadHistory() {
        guard let store = monitor.historyStore else {
            logger.debug("loadHistory: no history store available")
            return
        }
        logger.debug("loadHistory: refreshing history data")

        todayStats = try? store.todayStats()
        dailyTrend = (try? store.dailyMaxCombined()) ?? []
        budgetHitRate = (try? store.budgetHitRate()) ?? 0
        peakHours = (try? store.peakUsageHours()) ?? []
        avgSessionsPerDay = (try? store.avgSessionsPerDay()) ?? 0

        logger.debug("loadHistory complete: todaySessions=\(todayStats?.sessionCount ?? 0, privacy: .public) dailyTrendDays=\(dailyTrend.count, privacy: .public) budgetHitRate=\(budgetHitRate, privacy: .public) peakHoursCount=\(peakHours.count, privacy: .public) avgSessionsPerDay=\(avgSessionsPerDay, privacy: .public)")
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Text(value)
                .font(.caption2)
                .fontWeight(.medium)
                .monospacedDigit()
        }
    }
}
