import Testing
import Foundation
@testable import Clacal

@Suite("DataStore — JSON Persistence")
struct DataStoreTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("usage_data.json")
    }

    @Test("Load from nonexistent file returns empty StoreData")
    func loadNonexistent() {
        let data = DataStore.load(from: tempURL())
        #expect(data.polls.isEmpty)
        #expect(data.sessions.isEmpty)
    }

    @Test("Save then load round-trips polls and sessions")
    func roundTrip() {
        let url = tempURL()
        let now = Date()
        let original = StoreData(
            polls: [
                Poll(timestamp: now, sessionUsage: 25, sessionRemaining: 200, weeklyUsage: 40, weeklyRemaining: 6000),
                Poll(timestamp: now.addingTimeInterval(300), sessionUsage: 30, sessionRemaining: 195, weeklyUsage: 41, weeklyRemaining: 5995),
            ],
            sessions: [
                SessionStart(timestamp: now, weeklyUsage: 40, weeklyRemaining: 6000),
            ]
        )

        DataStore.save(original, to: url)
        let loaded = DataStore.load(from: url)

        #expect(loaded.polls.count == 2)
        #expect(loaded.sessions.count == 1)
        #expect(loaded.polls[0].sessionUsage == 25)
        #expect(loaded.polls[1].sessionUsage == 30)
        #expect(loaded.sessions[0].weeklyUsage == 40)
    }

    @Test("Timestamps round-trip through secondsSince1970 encoding")
    func timestampRoundTrip() {
        let url = tempURL()
        let now = Date()
        let original = StoreData(
            polls: [Poll(timestamp: now, sessionUsage: 10, sessionRemaining: 290, weeklyUsage: 20, weeklyRemaining: 9000)],
            sessions: []
        )

        DataStore.save(original, to: url)
        let loaded = DataStore.load(from: url)

        // Timestamps should be within 1 second (secondsSince1970 truncates sub-second)
        #expect(abs(loaded.polls[0].timestamp.timeIntervalSince(now)) < 1)
    }

    @Test("Corrupted file returns empty StoreData")
    func corruptedFile() throws {
        let url = tempURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json {{{".utf8).write(to: url)

        let data = DataStore.load(from: url)
        #expect(data.polls.isEmpty)
        #expect(data.sessions.isEmpty)
    }

    @Test("Save creates intermediate directories")
    func createsDirectories() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("deep")
            .appendingPathComponent("path")
            .appendingPathComponent("data.json")

        DataStore.save(StoreData(), to: url)
        let loaded = DataStore.load(from: url)
        #expect(loaded.polls.isEmpty)
    }

    @Test("Empty StoreData round-trips cleanly")
    func emptyRoundTrip() {
        let url = tempURL()
        DataStore.save(StoreData(), to: url)
        let loaded = DataStore.load(from: url)
        #expect(loaded.polls.isEmpty)
        #expect(loaded.sessions.isEmpty)
    }
}
