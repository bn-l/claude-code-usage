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

    @Test("UsageWindow decodes resets_at as nil when null")
    func resetsAtNull() throws {
        let json = Data("""
            {"utilization": 0.0, "resets_at": null}
            """.utf8)
        let window = try JSONDecoder().decode(UsageWindow.self, from: json)
        #expect(window.utilization == 0.0)
        #expect(window.resets_at == nil)
    }

    @Test("UsageLimits decodes real API response with null resets_at and unknown fields")
    func realAPIResponseWithNulls() throws {
        let json = Data("""
            {
                "five_hour": {"utilization": 0.0, "resets_at": null},
                "seven_day": {"utilization": 45.0, "resets_at": "2026-02-13T01:59:59.999835+00:00"},
                "seven_day_oauth_apps": null,
                "seven_day_opus": null,
                "seven_day_sonnet": {"utilization": 0.0, "resets_at": null},
                "seven_day_cowork": null,
                "iguana_necktie": null,
                "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null}
            }
            """.utf8)
        let limits = try JSONDecoder().decode(UsageLimits.self, from: json)
        #expect(limits.five_hour?.utilization == 0.0)
        #expect(limits.five_hour?.resets_at == nil)
        #expect(limits.seven_day?.utilization == 45.0)
        #expect(limits.seven_day?.resets_at == "2026-02-13T01:59:59.999835+00:00")
    }
}
