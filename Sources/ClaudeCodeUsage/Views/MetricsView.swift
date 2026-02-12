import SwiftUI

struct MetricsView: View {
    let metrics: UsageMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GaugeRow(
                label: "Combined",
                value: metrics.combinedPct,
                color: metrics.colorTier.color
            )

            GaugeRow(
                label: "Session Forecast",
                value: metrics.sessionForecastPct,
                color: ColorTier(combinedPct: metrics.sessionForecastPct).color
            )

            GaugeRow(
                label: "Session",
                value: metrics.sessionUsagePct,
                color: ColorTier.blue.color,
                detail: formatMinutes(metrics.sessionMinsLeft) + " remaining"
            )

            GaugeRow(
                label: "Weekly",
                value: metrics.weeklyUsagePct,
                color: ColorTier.purple.color,
                detail: formatMinutesLong(metrics.weeklyMinsLeft) + " until reset"
            )
        }
    }

    private func formatMinutes(_ mins: Double) -> String {
        let h = Int(mins) / 60
        let m = Int(mins) % 60
        return "\(h)h \(m)m"
    }

    private func formatMinutesLong(_ mins: Double) -> String {
        let totalMins = Int(mins)
        let days = totalMins / 1440
        let hours = (totalMins % 1440) / 60
        let minutes = totalMins % 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        return "\(hours)h \(minutes)m"
    }
}

struct GaugeRow: View {
    let label: String
    let value: Double
    let color: Color
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value))%")
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * min(value / 100, 1))
                }
            }
            .frame(height: 6)

            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
