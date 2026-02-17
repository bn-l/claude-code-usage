import SwiftUI

struct MetricsView: View {
    let metrics: UsageMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeviationRow(
                label: "Pace",
                value: metrics.calibrator,
                positiveLabel: "Ease off",
                negativeLabel: "Use more"
            )

            DeviationRow(
                label: "Session Pace",
                value: metrics.sessionDeviation,
                positiveLabel: "Ahead",
                negativeLabel: "Behind"
            )

            DeviationRow(
                label: "Weekly Pace",
                value: metrics.weeklyDeviation,
                positiveLabel: "Ahead",
                negativeLabel: "Behind"
            )

            DeviationRow(
                label: "Daily Budget",
                value: metrics.dailyDeviation,
                positiveLabel: "Over",
                negativeLabel: "Under"
            )

            // Session
            GaugeRow(
                label: "Session",
                value: metrics.sessionUsagePct,
                elapsedPct: metrics.sessionElapsedPct,
                detail: "\(formatMinutes(metrics.sessionMinsLeft)) left \u{2022} target \(Int(metrics.sessionTarget))%"
            )

            // Weekly
            GaugeRow(
                label: "Weekly",
                value: metrics.weeklyUsagePct,
                elapsedPct: metrics.weeklyElapsedPct,
                detail: "\(formatMinutesLong(metrics.weeklyMinsLeft)) until reset"
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

struct DeviationRow: View {
    let label: String
    let value: Double
    var positiveLabel = "Over"
    var negativeLabel = "Under"
    var neutralLabel = "On pace"

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(statusLabel) \(signedPercent)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                let center = geo.size.width / 2
                let maxExtent = center - 4
                let clamped = min(max(value, -1), 1)
                let extent = CGFloat(abs(clamped)) * maxExtent

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))

                    if extent > 1 {
                        let barOffset = clamped >= 0 ? center : center - extent
                        RoundedRectangle(cornerRadius: 2)
                            .fill(UsageColor.fromCalibrator(clamped))
                            .frame(width: extent)
                            .offset(x: barOffset)
                    }

                    Rectangle()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 2)
                        .offset(x: center - 1)
                }
            }
            .frame(height: 8)
        }
    }

    private var statusLabel: String {
        if abs(value) < 0.1 { return neutralLabel }
        return value > 0 ? positiveLabel : negativeLabel
    }

    private var signedPercent: String {
        let pct = Int(round(value * 100))
        if pct == 0 { return "0%" }
        return pct > 0 ? "+\(pct)%" : "\(pct)%"
    }
}

struct GaugeRow: View {
    let label: String
    let value: Double
    var elapsedPct: Double? = nil
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

            if let elapsed = elapsedPct {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.primary.opacity(0.05))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: geo.size.width * min(elapsed / 100, 1))
                    }
                }
                .frame(height: 3)
            }

            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
