import SwiftUI

struct MetricsView: View {
    let metrics: UsageMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Calibrator — zero-centered bar
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Pace")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(calibratorLabel)
                        .font(.caption)
                        .fontWeight(.medium)
                }

                GeometryReader { geo in
                    let center = geo.size.width / 2
                    let maxExtent = center - 4
                    let magnitude = CGFloat(abs(metrics.calibrator))
                    let extent = magnitude * maxExtent

                    ZStack(alignment: .leading) {
                        // Track
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.08))

                        // Bar extending from center
                        if extent > 1 {
                            let barOffset = metrics.calibrator >= 0 ? center : center - extent
                            RoundedRectangle(cornerRadius: 2)
                                .fill(metrics.color)
                                .frame(width: extent)
                                .offset(x: barOffset)
                        }

                        // Center tick
                        Rectangle()
                            .fill(Color.primary.opacity(0.25))
                            .frame(width: 1)
                            .offset(x: center - 0.5)
                    }
                }
                .frame(height: 8)
            }

            // Session
            GaugeRow(
                label: "Session",
                value: metrics.sessionUsagePct,
                detail: "\(formatMinutes(metrics.sessionMinsLeft)) left \u{2022} target \(Int(metrics.sessionTarget))%"
            )

            // Weekly
            GaugeRow(
                label: "Weekly",
                value: metrics.weeklyUsagePct,
                detail: "\(formatMinutesLong(metrics.weeklyMinsLeft)) until reset"
            )
        }
    }

    private var calibratorLabel: String {
        let cal = metrics.calibrator
        if abs(cal) < 0.1 { return "On pace" }
        if cal > 0 { return "Ease off" }
        return "Use more"
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
                        .fill(value >= 100 ? Color.primary : Color.secondary.opacity(0.4))
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
