import SwiftUI

struct PopoverView: View {
    let monitor: UsageMonitor
    @State private var showingErrors = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showingErrors {
                errorListView
            } else {
                ZStack(alignment: .topTrailing) {
                    mainContent
                    if monitor.hasError {
                        errorButton
                    }
                }
            }

            Divider()

            HStack {
                if let lastUpdated = monitor.lastUpdated {
                    Text("Updated \(lastUpdated, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    Task { await monitor.manualPoll() }
                } label: {
                    if monitor.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .disabled(monitor.isLoading)
                Button {
                    monitor.toggleDisplayMode()
                } label: {
                    Image(systemName: monitor.displayMode == .calibrator
                        ? "chart.bar.fill"
                        : "gauge.with.needle")
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help(monitor.displayMode == .calibrator ? "Switch to dual bar" : "Switch to calibrator")
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onChange(of: monitor.hasError) { _, hasError in
            if !hasError { showingErrors = false }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if let metrics = monitor.metrics {
            MetricsView(metrics: metrics)
        } else if monitor.hasError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Unable to fetch usage data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            ProgressView("Loading...")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        }
    }

    private var errorButton: some View {
        Button {
            showingErrors = true
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
    }

    private var errorListView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Errors")
                    .font(.headline)
                Spacer()
                Button {
                    showingErrors = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(monitor.errors.reversed().enumerated()), id: \.element.id) { index, error in
                        if index > 0 { Divider() }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(error.timestamp, format: .dateTime.hour().minute().second())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(error.message)
                                .font(.caption)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }
}
