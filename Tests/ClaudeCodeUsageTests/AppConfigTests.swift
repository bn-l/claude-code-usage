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
        #expect(config.defaultSessionsPerDay == 2)
        #expect(config.pollIntervalSeconds == 300)
    }

    @Test("Valid config with both fields")
    func validFullConfig() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        let json = Data("""
            {"defaultSessionsPerDay": 5, "pollIntervalSeconds": 120}
            """.utf8)
        try json.write(to: url)

        let config = AppConfig.load(from: url)
        #expect(config.defaultSessionsPerDay == 5)
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
        #expect(config.defaultSessionsPerDay == 2)   // default
        #expect(config.pollIntervalSeconds == 60)     // parsed
    }

    @Test("Malformed JSON returns defaults, no crash")
    func malformedJson() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try Data("not valid json {{{{".utf8).write(to: url)

        let config = AppConfig.load(from: url)
        #expect(config.defaultSessionsPerDay == 2)
        #expect(config.pollIntervalSeconds == 300)
    }
}
