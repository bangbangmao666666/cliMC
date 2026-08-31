import XCTest
@testable import CodexVoiceHotkey

final class HotkeyStateTests: XCTestCase {
    func testOptionEPressRepeatAndReleaseProduceOneRecordingCycleWithoutLeakingRepeat() {
        var state = HotkeyState()

        XCTAssertEqual(
            state.transition(keyCode: 14, isKeyDown: true, modifierFlags: [.maskAlternate]),
            .press
        )
        let repeatedKeyDown = state.transition(
            keyCode: 14,
            isKeyDown: true,
            modifierFlags: [.maskAlternate]
        )
        XCTAssertNotEqual(repeatedKeyDown, .none)
        XCTAssertNotEqual(repeatedKeyDown, .press)
        XCTAssertEqual(state.transition(keyCode: 14, isKeyDown: false, modifierFlags: []), .release)
    }

    func testOtherKeysDoNotTriggerVoiceRecording() {
        var state = HotkeyState()

        XCTAssertEqual(state.transition(keyCode: 0, isKeyDown: true, modifierFlags: [.maskCommand]), .none)
    }

    func testReleasesWhenOptionModifierIsReleasedBeforeKeyUpArrives() {
        var state = HotkeyState()
        XCTAssertEqual(state.transition(keyCode: 14, isKeyDown: true, modifierFlags: [.maskAlternate]), .press)
        XCTAssertEqual(state.modifiersChanged([]), .release)
    }
}
