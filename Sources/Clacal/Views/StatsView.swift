import SwiftUI

struct StatsView: View {
    let stats: UsageStats
    let onDismiss: () -> Void

    private static let sessionColor = Color.blue
    private static let hoursColor = Color.indigo
    private static let weeklyColor = Color.teal

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Stats")
                    .font(.headline)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sessionUsageSection
                    hoursActiveSection
                    if !stats.weeklyHistory.isEmpty {
                        weeklyUtilSection
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    // MARK: - Avg Session Usage

    private var sessionUsageSection: some View {
        statsSection("Avg Session Usage", color: Self.sessionColor) {
            if let avg = stats.avgSessionUsage {
                HStack(spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Self.sessionColor.opacity(0.15))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Self.sessionColor.opacity(0.6))
                                .frame(width: geo.size.width * min(avg / 100, 1))
                        }
                    }
                    .frame(height: 8)
                    Text("\(Int(avg))%")
                        .font(.caption)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            } else {
                Text("Not enough data")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Hours Active

    private var hoursActiveSection: some View {
        statsSection("Hours Active", color: Self.hoursColor) {
            VStack(spacing: 4) {
                hoursRow("Today", value: stats.hoursToday, suffix: "h")
                if let avg = stats.hoursWeekAvg {
                    hoursRow("Week avg", value: avg, suffix: "h/day")
                }
                if let avg = stats.hoursAllTimeAvg {
                    hoursRow("All-time", value: avg, suffix: "h/day")
                }
            }
        }
    }

    // MARK: - Weekly Utilization

    private var weeklyUtilSection: some View {
        statsSection("Weekly Utilization", color: Self.weeklyColor) {
            VStack(spacing: 6) {
                ForEach(stats.weeklyHistory) { entry in
                    HStack(spacing: 8) {
                        Text(entry.weekStart, format: .dateTime.month(.abbreviated).day())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Self.weeklyColor.opacity(0.15))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Self.weeklyColor.opacity(0.6))
                                    .frame(width: geo.size.width * min(entry.utilization / 100, 1))
                            }
                        }
                        .frame(height: 8)
                        Text("\(Int(entry.utilization))%")
                            .font(.caption2)
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statsSection<Content: View>(
        _ title: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(color)
                .fontWeight(.medium)
            content()
        }
    }

    private func hoursRow(_ label: String, value: Double, suffix: String) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(String(format: "%.1f", value)) \(suffix)")
                .font(.caption)
                .fontWeight(.medium)
                .monospacedDigit()
        }
    }
}
