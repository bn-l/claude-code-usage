import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.bml.claude-code-usage", category: "Monitor")

struct AppError: Identifiable, Sendable {
    let id = UUID()
    let message: String
    let timestamp: Date

    init(message: String, timestamp: Date = Date()) {
        self.message = message
        self.timestamp = timestamp
    }
}

@Observable
@MainActor
final class UsageMonitor {
    var metrics: UsageMetrics? {
        didSet {
            logger.trace("metrics updated: calibrator=\(self.metrics?.calibrator ?? -99, privacy: .public)")
        }
    }
    var errors: [AppError] = []
    var hasError: Bool { !errors.isEmpty }
    var isLoading = false
    var lastUpdated: Date?
    var config = AppConfig.load()
    var displayMode: MenuBarDisplayMode {
        get { config.menuBarDisplayMode }
        set {
            config.menuBarDisplayMode = newValue
            config.save()
        }
    }
    private var napActivity: (any NSObjectProtocol)?

    // internal(set) for test injection
    var optimiser: UsageOptimiser?

    func toggleDisplayMode() {
        displayMode = displayMode == .calibrator ? .dualBar : .calibrator
    }

    func manualPoll() async {
        logger.info("Manual poll triggered")
        await poll()
    }

    func startPolling() async {
        logger.info("startPolling: pollInterval=\(self.config.pollIntervalSeconds, privacy: .public)s")
        napActivity = ProcessInfo.processInfo.beginActivity(options: .background, reason: "Periodic API polling")

        ensureOptimiser()

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

        ensureOptimiser()

        let result = optimiser!.recordPoll(
            sessionUsage: sessionUsagePct,
            sessionRemaining: sessionMinsLeft,
            weeklyUsage: weeklyUsagePct,
            weeklyRemaining: weeklyMinsLeft
        )

        metrics = UsageMetrics(
            sessionUsagePct: sessionUsagePct,
            weeklyUsagePct: weeklyUsagePct,
            sessionMinsLeft: sessionMinsLeft,
            weeklyMinsLeft: weeklyMinsLeft,
            calibrator: result.calibrator,
            sessionTarget: result.target,
            sessionUtilRatio: result.sessionUtilRatio,
            dailyAllotmentRatio: result.dailyAllotmentRatio,
            timestamp: Date()
        )
        errors.removeAll()
        lastUpdated = Date()

        logger.info("Poll complete: calibrator=\(result.calibrator, privacy: .public) target=\(result.target, privacy: .public) optimalRate=\(result.optimalRate, privacy: .public)")
    }

    private func ensureOptimiser() {
        guard optimiser == nil else { return }
        optimiser = UsageOptimiser(
            data: DataStore.load(),
            activeHoursPerDay: config.activeHoursPerDay,
            persistURL: DataStore.defaultURL
        )
    }

    private func appendError(_ message: String) {
        logger.debug("Error recorded: \(message, privacy: .public)")
        errors.append(AppError(message: message))
        if errors.count > 10 { errors.removeFirst(errors.count - 10) }
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
                appendError("No OAuth token in Keychain. Run: claude login")
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
            appendError(error.localizedDescription)
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

enum MenuBarDisplayMode: String, Codable, Sendable {
    case calibrator
    case dualBar
}

struct AppConfig: Codable, Sendable {
    var activeHoursPerDay: [Double] = [10, 10, 10, 10, 10, 10, 10]
    var pollIntervalSeconds: Int = 300
    var menuBarDisplayMode: MenuBarDisplayMode = .calibrator

    init(
        activeHoursPerDay: [Double] = [10, 10, 10, 10, 10, 10, 10],
        pollIntervalSeconds: Int = 300,
        menuBarDisplayMode: MenuBarDisplayMode = .calibrator
    ) {
        self.activeHoursPerDay = activeHoursPerDay
        self.pollIntervalSeconds = pollIntervalSeconds
        self.menuBarDisplayMode = menuBarDisplayMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeHoursPerDay = try container.decodeIfPresent([Double].self, forKey: .activeHoursPerDay) ?? [10, 10, 10, 10, 10, 10, 10]
        pollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 300
        menuBarDisplayMode = try container.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode) ?? .calibrator
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
        logger.info("Config loaded: path=\(path, privacy: .public) activeHoursPerDay=\(config.activeHoursPerDay, privacy: .public) pollIntervalSeconds=\(config.pollIntervalSeconds, privacy: .public) displayMode=\(config.menuBarDisplayMode.rawValue, privacy: .public)")
        return config
    }

    func save() {
        Self.save(self, to: Self.configURL)
    }

    static func save(_ config: AppConfig, to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(config) else {
            logger.error("Failed to encode config for save")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            logger.info("Config saved: displayMode=\(config.menuBarDisplayMode.rawValue, privacy: .public)")
        } catch {
            logger.error("Failed to write config: \(error.localizedDescription, privacy: .public)")
        }
    }
}
