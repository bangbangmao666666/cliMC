import Foundation
import XCTest
@testable import CodexVoiceHotkey

final class UsageStatsTests: XCTestCase {
    func testStoreRecordsAndSummarizesUsageEventsInRange() throws {
        let fileURL = temporaryUsageFile()
        let store = UsageStatsStore(fileURL: fileURL)
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        try store.recordVoiceStarted(at: base)
        try store.recordTranscriptionCommitted(text: "你好 codex", at: base.addingTimeInterval(10))
        try store.recordAutoSubmitted(at: base.addingTimeInterval(20))
        try store.recordVoiceStarted(at: base.addingTimeInterval(90_000))

        let summary = try store.summary(
            from: base.addingTimeInterval(-1),
            to: base.addingTimeInterval(60)
        )

        XCTAssertEqual(summary.voiceInputCount, 1)
        XCTAssertEqual(summary.characterCount, 8)
        XCTAssertEqual(summary.autoSubmitCount, 1)
    }

    func testStoreSkipsMalformedLines() throws {
        let fileURL = temporaryUsageFile()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json\n".utf8).write(to: fileURL)
        let store = UsageStatsStore(fileURL: fileURL)
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        try store.recordVoiceStarted(at: date)

        let summary = try store.summary(from: date.addingTimeInterval(-1), to: date.addingTimeInterval(1))
        XCTAssertEqual(summary.voiceInputCount, 1)
    }

    private func temporaryUsageFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("usage-events.jsonl")
    }
}
