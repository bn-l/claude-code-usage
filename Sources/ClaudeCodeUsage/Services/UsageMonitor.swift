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
    var historyStore: HistoryStore?

    var currentSnapshot: SessionSnapshot?
    var previousSessionMinsLeft: Double?
    var previousWeeklyMinsLeft: Double?
    var previousPollTimestamp: Date?
    var config = AppConfig.load()

    func manualPoll() async {
        logger.info("Manual poll triggered")
        await poll()
    }

    func initializeFromStore() throws {
        if historyStore == nil {
            logger.debug("historyStore is nil, creating new instance")
            historyStore = try HistoryStore()
        }
        currentSnapshot = try historyStore?.latestSessionStart()
        if let state = try historyStore?.latestPollState() {
            previousSessionMinsLeft = state.sessionMinsLeft
            previousWeeklyMinsLeft = state.weeklyMinsLeft
            previousPollTimestamp = state.timestamp
        }
        logger.info("HistoryStore initialized: hasExistingSnapshot=\(self.currentSnapshot != nil, privacy: .public) previousSessionMinsLeft=\(self.previousSessionMinsLeft ?? -1, privacy: .public) previousPollTimestamp=\(self.previousPollTimestamp?.description ?? "nil", privacy: .public)")
        if let snap = currentSnapshot {
            logger.info("Restored snapshot: weeklyUsagePctAtStart=\(snap.weeklyUsagePctAtStart, privacy: .public) weeklyMinsLeftAtStart=\(snap.weeklyMinsLeftAtStart, privacy: .public) timestamp=\(snap.timestamp, privacy: .public)")
        }
    }

    func startPolling() async {
        logger.info("startPolling called: pollInterval=\(self.config.pollIntervalSeconds, privacy: .public)s defaultSessionsPerDay=\(self.config.defaultSessionsPerDay, privacy: .public)")

        do {
            try initializeFromStore()
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

    func processResponse(
        sessionUsagePct: Double,
        weeklyUsagePct: Double,
        sessionMinsLeft: Double,
        weeklyMinsLeft: Double
    ) {
        logger.debug("Raw values: sessionUsagePct=\(sessionUsagePct, privacy: .public) weeklyUsagePct=\(weeklyUsagePct, privacy: .public) sessionMinsLeft=\(sessionMinsLeft, privacy: .public) weeklyMinsLeft=\(weeklyMinsLeft, privacy: .public)")

        // Session-reset detection via two signals (both restored from SQLite on launch):
        // 1. Timer jumped up — session definitely reset
        // 2. Enough wall-clock time elapsed that the old session must have expired
        //    (handles app downtime where prev and current are both high)
        let sessionExpired = if let prev = previousSessionMinsLeft,
                                let prevTs = previousPollTimestamp {
            Date() > prevTs.addingTimeInterval(prev * 60)
        } else {
            false
        }
        let timerJumped = if let prev = previousSessionMinsLeft {
            sessionMinsLeft - prev > 30
        } else {
            false
        }
        if timerJumped || sessionExpired {
            logger.info("Session reset detected: timerJumped=\(timerJumped, privacy: .public) sessionExpired=\(sessionExpired, privacy: .public) prevMins=\(self.previousSessionMinsLeft ?? -1, privacy: .public) currentMins=\(sessionMinsLeft, privacy: .public)")
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

        // Weekly-reset detection: the weekly timer only counts down, so any
        // significant increase vs the previous poll means the week reset.
        // Compares with last poll (not snapshot) so it works even when the
        // snapshot was captured early in the week (near 10080).
        // Persisted via saveSessionStart so it survives app restarts.
        if let prevWeekly = previousWeeklyMinsLeft,
           weeklyMinsLeft - prevWeekly > 60 {
            logger.info("Weekly reset detected: weeklyMinsLeft=\(weeklyMinsLeft, privacy: .public) prevWeekly=\(prevWeekly, privacy: .public) — re-baselining")
            let snap = SessionSnapshot(
                weeklyUsagePctAtStart: weeklyUsagePct,
                weeklyMinsLeftAtStart: weeklyMinsLeft,
                timestamp: Date()
            )
            currentSnapshot = snap
            do {
                try historyStore?.updateLatestSessionStart(snap)
            } catch {
                logger.error("Failed to save weekly re-baseline: \(error.localizedDescription, privacy: .public)")
            }
        }

        previousSessionMinsLeft = sessionMinsLeft
        previousWeeklyMinsLeft = weeklyMinsLeft
        previousPollTimestamp = Date()

        // Bootstrap: need a snapshot to compute anything, but don't persist
        // as a session start — we may be launching mid-session which would
        // inflate expectedSessionsPerDay.
        if currentSnapshot == nil {
            logger.info("No existing snapshot, creating bootstrap: weeklyUsagePct=\(weeklyUsagePct, privacy: .public) weeklyMinsLeft=\(weeklyMinsLeft, privacy: .public)")
            currentSnapshot = SessionSnapshot(
                weeklyUsagePctAtStart: weeklyUsagePct,
                weeklyMinsLeftAtStart: weeklyMinsLeft,
                timestamp: Date()
            )
        }

        let sessionsPerDay: Double
        do {
            if let observed = try historyStore?.expectedSessionsPerDay() {
                sessionsPerDay = observed
                logger.debug("Using observed sessionsPerDay=\(sessionsPerDay, privacy: .public)")
            } else {
                sessionsPerDay = Double(config.defaultSessionsPerDay)
                logger.debug("Using config fallback sessionsPerDay=\(sessionsPerDay, privacy: .public) (no session data)")
            }
        } catch {
            sessionsPerDay = Double(config.defaultSessionsPerDay)
            logger.error("expectedSessionsPerDay query failed: \(error.localizedDescription, privacy: .public) — falling back to config default=\(sessionsPerDay, privacy: .public)")
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
            if response.five_hour == nil {
                logger.warning("API response missing five_hour window — defaulting to 0")
            }
            if response.seven_day == nil {
                logger.warning("API response missing seven_day window — defaulting to 0")
            }
            processResponse(
                sessionUsagePct: response.five_hour?.utilization ?? 0,
                weeklyUsagePct: response.seven_day?.utilization ?? 0,
                sessionMinsLeft: minutesUntil(response.five_hour?.resets_at),
                weeklyMinsLeft: minutesUntil(response.seven_day?.resets_at)
            )
        } catch {
            lastError = error.localizedDescription
            logger.error("Poll failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func minutesUntil(_ isoString: String?) -> Double {
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
    var defaultSessionsPerDay: Int = 2
    var pollIntervalSeconds: Int = 300

    init(defaultSessionsPerDay: Int = 2, pollIntervalSeconds: Int = 300) {
        self.defaultSessionsPerDay = defaultSessionsPerDay
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultSessionsPerDay = try container.decodeIfPresent(Int.self, forKey: .defaultSessionsPerDay) ?? 2
        pollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 300
    }

    private static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/claude-code-usage/config.json")

    static func load() -> AppConfig {
        load(from: configURL)
    }

    static func load(from url: URL) -> AppConfig {
        let path = url.path()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.info("Config file not readable at \(path, privacy: .public): \(error.localizedDescription, privacy: .public) — using defaults")
            return AppConfig()
        }
        guard let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            logger.error("Config file at \(path, privacy: .public) exists but failed to decode (\(data.count, privacy: .public) bytes) — using defaults")
            return AppConfig()
        }
        logger.info("Config loaded: path=\(path, privacy: .public) defaultSessionsPerDay=\(config.defaultSessionsPerDay, privacy: .public) pollIntervalSeconds=\(config.pollIntervalSeconds, privacy: .public)")
        return config
    }
}
