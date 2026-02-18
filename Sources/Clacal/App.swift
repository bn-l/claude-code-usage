import SwiftUI
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.bml.clacal", category: "App")

@main
struct ClacalApp: App {
    @State private var monitor = UsageMonitor()

    init() {
        logger.info("ClacalApp initializing")
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(monitor: monitor)
        } label: {
            CalibratorIcon(
                calibrator: monitor.metrics?.calibrator ?? 0,
                sessionDeviation: monitor.metrics?.sessionDeviation ?? 0,
                dailyDeviation: monitor.metrics?.dailyDeviation ?? 0,
                displayMode: monitor.displayMode,
                hasError: monitor.hasError
            )
                .task {
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
                        logger.info("Running under test host — skipping polling")
                        return
                    }
                    logger.info("MenuBarExtra label task started, beginning polling")
                    await monitor.startPolling()
                }
        }
        .menuBarExtraStyle(.window)
    }
}
