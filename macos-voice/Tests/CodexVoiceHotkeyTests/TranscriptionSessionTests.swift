import XCTest
@testable import CodexVoiceHotkey

final class TranscriptionSessionTests: XCTestCase {
    func testPartialResultWhileRecordingOnlyPreviewsText() {
        let session = TranscriptionSession()

        XCTAssertEqual(
            session.receive(text: "你好", isFinal: false, isRecording: true),
            .preview("你好")
        )
        XCTAssertEqual(session.latestText, "你好")
        XCTAssertNil(session.finishRecording())
    }

    func testFinalResultWhileRecordingIsCommittedImmediately() {
        let session = TranscriptionSession()

        XCTAssertEqual(
            session.receive(text: "你好世界", isFinal: true, isRecording: true),
            .commit("你好世界")
        )
        XCTAssertNil(session.finishRecording())
        XCTAssertTrue(session.hasCommitted)
    }

    func testFinalResultAfterRecordingStopsCommitsImmediately() {
        let session = TranscriptionSession()

        XCTAssertEqual(
            session.receive(text: "打开设置", isFinal: true, isRecording: false),
            .commit("打开设置")
        )
    }
}
