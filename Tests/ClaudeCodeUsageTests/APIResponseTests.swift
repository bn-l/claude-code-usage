import Testing
import Foundation
@testable import ClaudeCodeUsage

@Suite("APIResponse Codable")
struct APIResponseTests {

    @Test("UsageWindow decodes utilization as Double (fractional)")
    func utilizationIsDouble() throws {
        let json = Data("""
            {"utilization": 37.5, "resets_at": "2026-01-15T12:00:00Z"}
            """.utf8)
        let window = try JSONDecoder().decode(UsageWindow.self, from: json)
        #expect(window.utilization == 37.5)
    }

    @Test("UsageWindow decodes resets_at as String")
    func resetsAtIsString() throws {
        let json = Data("""
            {"utilization": 50.0, "resets_at": "2026-01-15T12:00:00Z"}
            """.utf8)
        let window = try JSONDecoder().decode(UsageWindow.self, from: json)
        #expect(window.resets_at == "2026-01-15T12:00:00Z")
    }

    @Test("UsageLimits decodes rate_limit_tier as optional String")
    func rateLimitTierOptional() throws {
        let json = Data("""
            {"five_hour": null, "seven_day": null, "rate_limit_tier": "tier_4"}
            """.utf8)
        let limits = try JSONDecoder().decode(UsageLimits.self, from: json)
        #expect(limits.rate_limit_tier == "tier_4")
    }

    @Test("UsageLimits handles missing five_hour/seven_day")
    func missingWindows() throws {
        let json = Data("""
            {"five_hour": null, "seven_day": null}
            """.utf8)
        let limits = try JSONDecoder().decode(UsageLimits.self, from: json)
        #expect(limits.five_hour == nil)
        #expect(limits.seven_day == nil)
    }

    @Test("UsageLimits decodes full response")
    func fullResponse() throws {
        let json = Data("""
            {
                "five_hour": {"utilization": 25.0, "resets_at": "2026-01-15T17:00:00Z"},
                "seven_day": {"utilization": 40.0, "resets_at": "2026-01-20T00:00:00Z"},
                "rate_limit_tier": "tier_3"
            }
            """.utf8)
        let limits = try JSONDecoder().decode(UsageLimits.self, from: json)
        #expect(limits.five_hour?.utilization == 25.0)
        #expect(limits.seven_day?.utilization == 40.0)
        #expect(limits.rate_limit_tier == "tier_3")
    }

    @Test("Utilization is 0-100 percent scale, not 0-1 fractional")
    func percentScale() throws {
        let json = Data("""
            {"utilization": 50.0, "resets_at": "2026-01-15T12:00:00Z"}
            """.utf8)
        let window = try JSONDecoder().decode(UsageWindow.self, from: json)
        // 50.0 means 50%, verify it's used directly in UsageCalculator
        let m = UsageCalculator.compute(
            sessionUsagePct: window.utilization,
            weeklyUsagePct: 20,
            sessionMinsLeft: 150, weeklyMinsLeft: 7200,
            snapshot: SessionSnapshot(weeklyUsagePctAtStart: 20, weeklyMinsLeftAtStart: 7200, timestamp: Date()),
            sessionsPerDay: 2
        )
        // sessionElapsedFrac = 0.5, forecast = 50/0.5 = 100
        #expect(m.sessionForecastPct == 100)
    }
}
