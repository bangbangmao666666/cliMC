import AppKit
import XCTest
@testable import CodexVoiceHotkey

/// 指示器协议只传递文字状态内容。
final class VoiceIndicatorPresentingTests: XCTestCase {

    private final class RecordingIndicator: VoiceIndicatorPresenting {
        private(set) var states: [VoiceIndicatorState] = []
        private(set) var texts: [String?] = []
        var onShow: (() -> Void)?

        func show(_ state: VoiceIndicatorState, text: String?) {
            states.append(state)
            texts.append(text)
            onShow?()
        }

        func updateSpectrum(_ levels: [Double]) {}
        func hide() {
            states.append(.hidden)
            texts.append(nil)
        }
    }

    func testShowRecordsText() {
        let indicator = RecordingIndicator()

        indicator.show(.submitted, text: "🥳\n🎉")

        XCTAssertEqual(indicator.states, [.submitted])
        XCTAssertEqual(indicator.texts, ["🥳\n🎉"])
    }

    func testSubmittedUsesCompactTwoEmojiPanelSize() {
        let indicator = VoiceIndicator()

        indicator.show(.submitted, text: "🥳\n🎉")

        XCTAssertEqual(indicator.panelFrameSizeForTesting, NSSize(width: 96, height: 56))
    }

    func testSubmittedContentDisplaysTwoExpressionsInOneRow() throws {
        let content = VoiceIndicatorContentView(
            frame: NSRect(x: 0, y: 0, width: 96, height: 56)
        )

        content.apply(.submitted, text: "🥳\n🎉")
        content.layoutSubtreeIfNeeded()

        XCTAssertEqual(content.displayedGridTexts, ["🥳", "🎉"])
        let grid = try XCTUnwrap(content.subviews.first { view in
            view.subviews.compactMap { $0 as? NSTextField }.count == 2
        })
        let cells = grid.subviews.compactMap { $0 as? NSTextField }
        XCTAssertEqual(cells[0].frame.minY, cells[1].frame.minY, accuracy: 0.001)
        XCTAssertEqual(cells[0].frame.width, cells[1].frame.width, accuracy: 0.001)
    }

    func testSubmittedContentFallsBackToTwoSparkles() {
        let content = VoiceIndicatorContentView(
            frame: NSRect(x: 0, y: 0, width: 96, height: 56)
        )

        content.apply(.submitted, text: nil)

        XCTAssertEqual(content.displayedGridTexts, ["✨", "✨"])
    }

    func testListeningRetainsRectangularPanelSize() {
        let indicator = VoiceIndicator()

        indicator.show(.listening)

        XCTAssertEqual(indicator.panelFrameSizeForTesting, NSSize(width: 72, height: 36))
    }
}
