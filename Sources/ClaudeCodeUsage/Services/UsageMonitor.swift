import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.bml.claude-code-usage", category: "Monitor")

@Observable
@MainActor
final class UsageMonitor {
    var metrics: UsageMetrics? {
        didSet {
            logger.trace("metrics updated: combinedPct=\(self.metrics?.combinedPct ?? -1, privacy: .public) sessionForecast=\(self.metrics?.sessionForecastPct ?? -1, privacy: .public) budgetUsed=\(self.metrics?.weeklyBudgetBurnPct ?? -1, privacy: .public)")
        }
    }
    var lastError: String? {
        didSet {
            if let error = lastError {
                logger.debug("lastError changed: \(error, privacy: .public)")
            } else {
                logger.trace("lastError cleared")
            }
        }
    }
    var isLoading = false
    var lastUpdated: Date?
    private(set) var historyStore: HistoryStore?

    private var currentSnapshot: SessionSnapshot?
    private var previousSessionMinsLeft: Double?
    private var config = AppConfig.load()

    func manualPoll() async {
        logger.info("Manual poll triggered")
        await poll()
    }

    func startPolling() async {
        logger.info("startPolling called: pollInterval=\(self.config.pollIntervalSeconds, privacy: .public)s maxLocalSessions=\(self.config.maxLocalSessions, privacy: .public)")

        do {
            historyStore = try HistoryStore()
            currentSnapshot = try historyStore?.latestSessionStart()
            logger.info("HistoryStore initialized: hasExistingSnapshot=\(self.currentSnapshot != nil, privacy: .public)")
            if let snap = currentSnapshot {
                logger.info("Restored snapshot: weeklyUsagePctAtStart=\(snap.weeklyUsagePctAtStart, privacy: .public) weeklyMinsLeftAtStart=\(snap.weeklyMinsLeftAtStart, privacy: .public) timestamp=\(snap.timestamp, privacy: .public)")
            }
        } catch {
            lastError = "Database init failed: \(error.localizedDescription)"
            logger.error("HistoryStore init failed: \(error.localizedDescription, privacy: .public)")
        }

        logger.info("Starting initial poll")
        await poll()

        logger.info("Entering polling loop: interval=\(self.config.pollIntervalSeconds, privacy: .public)s")
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(config.pollIntervalSeconds))
            logger.debug("Poll timer fired")
            await poll()
        }
        logger.info("Polling loop exited: cancelled=\(Task.isCancelled, privacy: .public)")
    }

    private func poll() async {
        logger.debug("poll() start")
        isLoading = true
        defer {
            isLoading = false
            logger.debug("poll() end")
        }

        do {
            guard let token = CredentialProvider.readToken() else {
                lastError = "No OAuth token in Keychain. Run: claude login"
                logger.warning("No credentials available, skipping poll")
                return
            }

            let response = try await UsageAPIClient.fetch(token: token)
            let sessionUsagePct = response.five_hour?.utilization ?? 0
            let weeklyUsagePct = response.seven_day?.utilization ?? 0
            let sessionMinsLeft = minutesUntil(response.five_hour?.resets_at)
            let weeklyMinsLeft = minutesUntil(response.seven_day?.resets_at)

            logger.debug("Raw values: sessionUsagePct=\(sessionUsagePct, privacy: .public) weeklyUsagePct=\(weeklyUsagePct, privacy: .public) sessionMinsLeft=\(sessionMinsLeft, privacy: .public) weeklyMinsLeft=\(weeklyMinsLeft, privacy: .public)")

            // Session-reset detection: timer jumped from low to high
            if let prev = previousSessionMinsLeft, prev < 30, sessionMinsLeft > 250 {
                logger.info("Session reset detected: previousMinsLeft=\(prev, privacy: .public) currentMinsLeft=\(sessionMinsLeft, privacy: .public)")
                let snap = SessionSnapshot(
                    weeklyUsagePctAtStart: weeklyUsagePct,
                    weeklyMinsLeftAtStart: weeklyMinsLeft,
                    timestamp: Date()
                )
                currentSnapshot = snap
                do {
                    try historyStore?.saveSessionStart(snap)
                    logger.info("New session snapshot saved: weeklyUsagePct=\(weeklyUsagePct, privacy: .public) weeklyMinsLeft=\(weeklyMinsLeft, privacy: .public)")
                } catch {
                    logger.error("Failed to save session start: \(error.localizedDescription, privacy: .public)")
                }
            }
            previousSessionMinsLeft = sessionMinsLeft

            // Bootstrap initial snapshot if none exists
            if currentSnapshot == nil {
                logger.info("No existing snapshot, creating initial: weeklyUsagePct=\(weeklyUsagePct, privacy: .public) weeklyMinsLeft=\(weeklyMinsLeft, privacy: .public)")
                let snap = SessionSnapshot(
                    weeklyUsagePctAtStart: weeklyUsagePct,
                    weeklyMinsLeftAtStart: weeklyMinsLeft,
                    timestamp: Date()
                )
                currentSnapshot = snap
                do {
                    try historyStore?.saveSessionStart(snap)
                    logger.info("Initial snapshot saved")
                } catch {
                    logger.error("Failed to save initial snapshot: \(error.localizedDescription, privacy: .public)")
                }
            }

            let sessionsPerDay: Double
            if let observed = try? historyStore?.expectedSessionsPerDay() {
                sessionsPerDay = observed
                logger.debug("Using observed sessionsPerDay=\(sessionsPerDay, privacy: .public)")
            } else {
                sessionsPerDay = Double(config.maxLocalSessions)
                logger.debug("Using config fallback sessionsPerDay=\(sessionsPerDay, privacy: .public)")
            }

            let computed = UsageCalculator.compute(
                sessionUsagePct: sessionUsagePct,
                weeklyUsagePct: weeklyUsagePct,
                sessionMinsLeft: sessionMinsLeft,
                weeklyMinsLeft: weeklyMinsLeft,
                snapshot: currentSnapshot!,
                sessionsPerDay: sessionsPerDay
            )

            metrics = computed
            lastError = nil
            lastUpdated = Date()

            do {
                try historyStore?.saveSnapshot(computed)
                logger.debug("Snapshot persisted to database")
            } catch {
                logger.error("Failed to persist snapshot: \(error.localizedDescription, privacy: .public)")
            }

            do {
                try historyStore?.pruneOldRecords()
            } catch {
                logger.warning("Failed to prune old records: \(error.localizedDescription, privacy: .public)")
            }

            logger.info("Poll complete: combinedPct=\(computed.combinedPct, privacy: .public) sessionForecast=\(computed.sessionForecastPct, privacy: .public) budgetUsed=\(computed.weeklyBudgetBurnPct, privacy: .public) tier=\(String(describing: computed.colorTier), privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            logger.error("Poll failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func minutesUntil(_ isoString: String?) -> Double {
        guard let str = isoString else {
            logger.trace("minutesUntil: nil input")
            return 0
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: str) {
            let mins = max(date.timeIntervalSinceNow / 60, 0)
            logger.trace("minutesUntil: input=\(str, privacy: .public) minutes=\(mins, privacy: .public)")
            return mins
        }
        // Retry without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: str) else {
            logger.warning("Failed to parse ISO8601 date: input=\(str, privacy: .public)")
            return 0
        }
        let mins = max(date.timeIntervalSinceNow / 60, 0)
        logger.trace("minutesUntil (no frac): input=\(str, privacy: .public) minutes=\(mins, privacy: .public)")
        return mins
    }
}

// MARK: - Config

struct AppConfig: Codable, Sendable {
    var maxLocalSessions: Int = 2
    var pollIntervalSeconds: Int = 300

    private static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/claude-code-usage/config.json")

    static func load() -> AppConfig {
        let path = configURL.path()
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            logger.info("No config file found at \(path, privacy: .public), using defaults: maxLocalSessions=2 pollIntervalSeconds=300")
            return AppConfig()
        }
        logger.info("Config loaded: path=\(path, privacy: .public) maxLocalSessions=\(config.maxLocalSessions, privacy: .public) pollIntervalSeconds=\(config.pollIntervalSeconds, privacy: .public)")
        return config
    }
}
