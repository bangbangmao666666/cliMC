import XCTest
@testable import CodexVoiceHotkey

final class TerminalInjectorTests: XCTestCase {
    func testSubmitStaysBehindFinalReplacement() {
        var queue = TerminalInjectionQueue()
        queue.enqueueReplacement(
            ReplacementOperation(backspaces: 0, textToInsert: "解释代码")
        )
        queue.enqueueSubmit()

        XCTAssertEqual(
            queue.takeNext(),
            .replacement(ReplacementOperation(backspaces: 0, textToInsert: "解释代码"))
        )
        XCTAssertEqual(queue.takeNext(), .submit)
        XCTAssertNil(queue.takeNext())
    }

    func testRestoreClipboardDeferredUntilPasteSettles() {
        let injector = TerminalInjector()
        let board = NSPasteboard.general

        // Preserve whatever the test runner currently has on the clipboard.
        let saved = board.pasteboardItems?.first?.string(forType: .string)
        defer {
            board.clearContents()
            if let saved { board.setString(saved, forType: .string) }
        }

        // 1. Snapshot an "original" clipboard.
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)
        injector.saveClipboardIfNeeded()

        // 2. A paste just wrote the transcription onto the clipboard.
        board.clearContents()
        board.setString("VOICE_TEXT", forType: .string)
        injector.setLastPasteAtForTesting(Date())

        // 3. Restoring immediately must NOT clobber the pasteboard — the
        //    target app may not have consumed the Cmd+V yet.
        injector.restoreClipboard()
        XCTAssertEqual(board.string(forType: .string), "VOICE_TEXT")

        // 4. After the paste-settle window elapses, the deferred restore
        //    fires and the original clipboard is recovered.
        let restored = expectation(description: "clipboard restored after settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if board.string(forType: .string) == "ORIGINAL" {
                restored.fulfill()
            }
        }
        wait(for: [restored], timeout: 2.0)
        XCTAssertEqual(board.string(forType: .string), "ORIGINAL")
    }
}
