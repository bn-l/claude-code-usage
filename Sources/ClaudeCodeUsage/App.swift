import SwiftUI
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.bml.claude-code-usage", category: "App")

@main
struct ClaudeCodeUsageApp: App {
    @State private var monitor = UsageMonitor()

    init() {
        logger.info("ClaudeCodeUsageApp initializing")
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(monitor: monitor)
        } label: {
            PieChartIcon(combinedPct: monitor.metrics?.combinedPct ?? 0)
                .task {
                    logger.info("MenuBarExtra label task started, beginning polling")
                    await monitor.startPolling()
                }
        }
        .menuBarExtraStyle(.window)
    }
}
