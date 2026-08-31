import Foundation
import XCTest
@testable import CodexVoiceHotkey

final class UsageStatsStoreTests: XCTestCase {
    func testDailySummariesGroupsAcrossDays() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("usage-events.jsonl")
        let store = UsageStatsStore(fileURL: fileURL)
        let calendar = Calendar(identifier: .gregorian)

        // Day 1: 2 voice inputs
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 10))!
        try store.recordVoiceStarted(at: day1)
        try store.recordVoiceStarted(at: day1.addingTimeInterval(3600))

        // Day 2: 1 voice input + 1 transcription
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 21, hour: 14))!
        try store.recordVoiceStarted(at: day2)
        try store.recordTranscriptionCommitted(text: "你好世界", at: day2)

        // Day 3: auto submit
        let day3 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 9))!
        try store.recordAutoSubmitted(at: day3)

        let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 20))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 23, minute: 59, second: 59))!
        let summaries = try store.dailySummaries(from: start, to: end)

        XCTAssertEqual(summaries.count, 3)

        XCTAssertEqual(summaries[0].date, calendar.startOfDay(for: day1))
        XCTAssertEqual(summaries[0].voiceInputCount, 2)
        XCTAssertEqual(summaries[0].characterCount, 0)

        XCTAssertEqual(summaries[1].date, calendar.startOfDay(for: day2))
        XCTAssertEqual(summaries[1].voiceInputCount, 1)
        XCTAssertEqual(summaries[1].characterCount, 4)  // "你好世界" = 4 characters

        XCTAssertEqual(summaries[2].date, calendar.startOfDay(for: day3))
        XCTAssertEqual(summaries[2].autoSubmitCount, 1)
    }

    func testDailySummariesEmptyRange() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("usage-events.jsonl")
        let store = UsageStatsStore(fileURL: fileURL)
        let calendar = Calendar(identifier: .gregorian)

        let now = Date()
        try store.recordVoiceStarted(at: now)

        // Query a range that doesn't overlap
        let start = calendar.date(from: DateComponents(year: 2020, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2020, month: 1, day: 2))!
        let summaries = try store.dailySummaries(from: start, to: end)

        XCTAssertTrue(summaries.isEmpty)
    }

    func testDailySummariesNoEvents() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("usage-events.jsonl")
        let store = UsageStatsStore(fileURL: fileURL)
        let calendar = Calendar(identifier: .gregorian)

        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31))!
        let summaries = try store.dailySummaries(from: start, to: end)

        XCTAssertTrue(summaries.isEmpty)
    }

    func testDailySummariesSingleDayMultipleMetrics() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("usage-events.jsonl")
        let store = UsageStatsStore(fileURL: fileURL)
        let calendar = Calendar(identifier: .gregorian)

        let day = calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 8))!
        let later = day.addingTimeInterval(7200)

        try store.recordVoiceStarted(at: day)
        try store.recordTranscriptionCommitted(text: "测试", at: day)
        try store.recordAutoSubmitted(at: later)

        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let summaries = try store.dailySummaries(from: start, to: end)

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].voiceInputCount, 1)
        XCTAssertEqual(summaries[0].characterCount, 2)  // "测试" = 2 characters
        XCTAssertEqual(summaries[0].autoSubmitCount, 1)
    }
}
