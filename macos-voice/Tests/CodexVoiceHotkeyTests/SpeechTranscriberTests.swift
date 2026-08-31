import XCTest
@testable import CodexVoiceHotkey

final class SpeechTranscriberTests: XCTestCase {
    func testStaleGenerationCannotReportOrFinishReplacementSession() {
        let gate = SpeechTranscriberSessionGate()
        let firstGeneration = gate.begin()
        let secondGeneration = gate.begin()

        XCTAssertFalse(gate.isCurrent(firstGeneration))
        XCTAssertFalse(gate.finish(firstGeneration))
        XCTAssertTrue(gate.isCurrent(secondGeneration))
        XCTAssertTrue(gate.finish(secondGeneration))
        XCTAssertFalse(gate.isCurrent(secondGeneration))
    }

    func testCurrentGenerationCanFinishExactlyOnce() {
        let gate = SpeechTranscriberSessionGate()
        let generation = gate.begin()

        XCTAssertTrue(gate.isCurrent(generation))
        XCTAssertTrue(gate.finish(generation))
        XCTAssertFalse(gate.finish(generation))
    }
}
