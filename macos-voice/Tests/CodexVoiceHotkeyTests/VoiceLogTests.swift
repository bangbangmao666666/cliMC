import Foundation
import XCTest
@testable import CodexVoiceHotkey

final class VoiceLogTests: XCTestCase {
    func testLogLineContainsUTCMillisecondsAndMessage() {
        let date = Date(timeIntervalSince1970: 0)

        let line = VoiceLogFormatter.line(message: "开始录音", date: date)

        XCTAssertEqual(line, "[1970-01-01T00:00:00.000Z] [cliMC] 开始录音\n")
    }
}
