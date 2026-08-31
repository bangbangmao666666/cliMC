import CoreGraphics
import XCTest
@testable import CodexVoiceHotkey

final class InputActivityTests: XCTestCase {
    func testPhysicalKeyAndMouseDownAreUserActivity() {
        XCTAssertTrue(InputActivityClassifier.shouldNotify(type: .keyDown, marker: 0))
        XCTAssertTrue(InputActivityClassifier.shouldNotify(type: .leftMouseDown, marker: 0))
        XCTAssertTrue(InputActivityClassifier.shouldNotify(type: .rightMouseDown, marker: 0))
        XCTAssertTrue(InputActivityClassifier.shouldNotify(type: .otherMouseDown, marker: 0))
    }

    func testReleaseMoveAndSyntheticEventsAreNotUserActivity() {
        XCTAssertFalse(InputActivityClassifier.shouldNotify(type: .keyUp, marker: 0))
        XCTAssertFalse(InputActivityClassifier.shouldNotify(type: .mouseMoved, marker: 0))
        XCTAssertFalse(
            InputActivityClassifier.shouldNotify(
                type: .keyDown,
                marker: VoiceSyntheticEvent.marker
            )
        )
    }
}
