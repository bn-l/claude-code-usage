import Testing
import Foundation
@testable import ClaudeCodeUsage

@Suite("AppConfig")
struct AppConfigTests {

    @Test("Missing config file returns defaults")
    func missingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nonexistent.json")
        let config = AppConfig.load(from: url)
        #expect(config.activeHoursPerDay == [10, 10, 10, 10, 10, 10, 10])
        #expect(config.pollIntervalSeconds == 300)
    }

    @Test("Valid config with both fields")
    func validFullConfig() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        let json = Data("""
            {"activeHoursPerDay": [8, 8, 8, 8, 8, 4, 4], "pollIntervalSeconds": 120}
            """.utf8)
        try json.write(to: url)

        let config = AppConfig.load(from: url)
        #expect(config.activeHoursPerDay == [8, 8, 8, 8, 8, 4, 4])
        #expect(config.pollIntervalSeconds == 120)
    }

    @Test("Partial config: missing fields get Codable defaults")
    func partialConfig() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        let json = Data("""
            {"pollIntervalSeconds": 60}
            """.utf8)
        try json.write(to: url)

        let config = AppConfig.load(from: url)
        #expect(config.activeHoursPerDay == [10, 10, 10, 10, 10, 10, 10])
        #expect(config.pollIntervalSeconds == 60)
    }

    @Test("Malformed JSON returns defaults, no crash")
    func malformedJson() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try Data("not valid json {{{{".utf8).write(to: url)

        let config = AppConfig.load(from: url)
        #expect(config.activeHoursPerDay == [10, 10, 10, 10, 10, 10, 10])
        #expect(config.pollIntervalSeconds == 300)
    }

    @Test("Old config format with defaultSessionsPerDay is ignored gracefully")
    func oldFormatIgnored() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        let json = Data("""
            {"defaultSessionsPerDay": 5, "pollIntervalSeconds": 180}
            """.utf8)
        try json.write(to: url)

        let config = AppConfig.load(from: url)
        // defaultSessionsPerDay is an unknown key — ignored
        #expect(config.activeHoursPerDay == [10, 10, 10, 10, 10, 10, 10])
        #expect(config.pollIntervalSeconds == 180)
    }
}
