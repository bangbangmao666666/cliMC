import XCTest
@testable import CodexVoiceHotkey

final class VoiceTranscriptionRouterTests: XCTestCase {
    func testPartialResultInjectsPreviewDuringRecording() {
        let injector = MockTextInjector()
        let indicator = MockIndicator()
        let router = VoiceTranscriptionRouter(
            aliases: ["目标": "/goal"],
            injector: injector,
            indicator: indicator
        )

        router.beginRecording()
        router.handleResult(text: "目标", isFinal: false, isRecording: true)

        // Live preview injects partial text into the input field
        XCTAssertEqual(injector.operations, ["insert:目标"])
        XCTAssertEqual(indicator.states, [.listening, .listening])
    }

    func testFinishRecordingResolvesPendingFinalText() {
        let injector = MockTextInjector()
        let router = VoiceTranscriptionRouter(
            aliases: ["新对话": "/new"],
            injector: injector,
            indicator: MockIndicator()
        )

        router.beginRecording()
        router.handleResult(text: "帮我新建一个对话。", isFinal: true, isRecording: true)
        router.finishRecording()

        // Final result during recording is committed immediately with
        // alias resolution; finishRecording does not re-commit.
        XCTAssertEqual(injector.operations, [
            "insert:/new",
        ])
    }

    func testFinalResultAfterReleaseResolvesNaturalExpression() {
        let injector = MockTextInjector()
        let router = VoiceTranscriptionRouter(
            aliases: ["压缩": "/compact"],
            injector: injector,
            indicator: MockIndicator()
        )

        router.beginRecording()
        router.handleResult(text: "压缩一下上下文。", isFinal: true, isRecording: false)

        XCTAssertEqual(injector.operations, ["insert:/compact"])
    }

    func testFinalResultPreservesUnmatchedText() {
        let injector = MockTextInjector()
        let router = VoiceTranscriptionRouter(
            aliases: AliasStore.defaults,
            injector: injector,
            indicator: MockIndicator()
        )

        router.beginRecording()
        router.handleResult(text: "解释一下新对话的逻辑", isFinal: true, isRecording: false)

        XCTAssertEqual(injector.operations, ["insert:解释一下新对话的逻辑"])
    }

    func testFinishRecordingCommitsFinalTextAndHidesIndicator() {
        let injector = MockTextInjector()
        let indicator = MockIndicator()
        let router = VoiceTranscriptionRouter(
            aliases: [:],
            injector: injector,
            indicator: indicator
        )

        router.beginRecording()
        router.handleResult(text: "你好世界", isFinal: true, isRecording: true)
        router.finishRecording()

        // Final result during recording is committed immediately;
        // finishRecording does not re-commit
        XCTAssertEqual(injector.operations, [
            "insert:你好世界",
        ])
        XCTAssertEqual(indicator.states, [.listening, .hidden])
    }

    func testRevisedPartialIsInjectedDuringRecording() {
        let injector = MockTextInjector()
        let router = VoiceTranscriptionRouter(
            aliases: [:],
            injector: injector,
            indicator: MockIndicator()
        )

        router.beginRecording()
        router.handleResult(text: "就是说你的情况看一下是", isFinal: false, isRecording: true)
        router.handleResult(text: "就是说你的情况，看一下手里的情况", isFinal: false, isRecording: true)

        // Live preview uses a minimal delta: the first partial is inserted
        // whole, and a later partial that shares a prefix only backspaces
        // the divergent trailing characters and pastes the new suffix.
        XCTAssertEqual(injector.replacements, [
            ReplacementOperation(backspaces: 0, textToInsert: "就是说你的情况看一下是"),
            ReplacementOperation(backspaces: 4, textToInsert: "，看一下手里的情况"),
        ])
    }

    func testAppendOnlyPartialSendsZeroBackspacesAndOnlySuffix() {
        let injector = MockTextInjector()
        let router = VoiceTranscriptionRouter(
            aliases: [:],
            injector: injector,
            indicator: MockIndicator()
        )

        router.beginRecording()
        router.handleResult(text: "重新启动", isFinal: false, isRecording: true)
        router.handleResult(text: "重新启动服务", isFinal: false, isRecording: true)
        router.handleResult(text: "重新启动服务我要", isFinal: false, isRecording: true)

        // Each append-only step sends zero backspaces and pastes only the
        // newly appended suffix, avoiding an O(n²) full re-paste.
        XCTAssertEqual(injector.replacements, [
            ReplacementOperation(backspaces: 0, textToInsert: "重新启动"),
            ReplacementOperation(backspaces: 0, textToInsert: "服务"),
            ReplacementOperation(backspaces: 0, textToInsert: "我要"),
        ])
    }

    func testShrinkingPartialBackspacesDivergentTrailingCharacters() {
        let injector = MockTextInjector()
        let router = VoiceTranscriptionRouter(
            aliases: [:],
            injector: injector,
            indicator: MockIndicator()
        )

        router.beginRecording()
        router.handleResult(text: "重新启动服务我要", isFinal: false, isRecording: true)
        router.handleResult(text: "重新启动", isFinal: false, isRecording: true)

        // The second partial is a prefix of the first, so we backspace the
        // 4 trailing characters ("服务我要") and paste nothing.
        XCTAssertEqual(injector.replacements, [
            ReplacementOperation(backspaces: 0, textToInsert: "重新启动服务我要"),
            ReplacementOperation(backspaces: 4, textToInsert: ""),
        ])
    }

    func testFinalSnapshotCanRevisePunctuationAfterRelease() {
        let injector = MockTextInjector()
        let router = VoiceTranscriptionRouter(
            aliases: [:],
            injector: injector,
            indicator: MockIndicator()
        )

        router.beginRecording()
        router.handleResult(text: "飞书准确率怎么样", isFinal: false, isRecording: true)
        router.handleResult(text: "飞书准确率怎么样？", isFinal: true, isRecording: false)

        // The final snapshot only appends the punctuation that differs from
        // the live preview.
        XCTAssertEqual(
            injector.replacements.last,
            ReplacementOperation(backspaces: 0, textToInsert: "？")
        )
    }

    func testFinalCommitPublishesOnlyAfterTerminalReplacementCompletes() {
        let injector = DeferredTextInjector()
        let router = VoiceTranscriptionRouter(
            aliases: [:],
            injector: injector,
            indicator: MockIndicator()
        )
        var committed: [String] = []
        router.onFinalCommit = { committed.append($0) }

        router.beginRecording()
        router.handleResult(text: "解释代码", isFinal: true, isRecording: false)

        XCTAssertTrue(committed.isEmpty)
        injector.completeNext()
        XCTAssertEqual(committed, ["解释代码"])
    }

    func testFinalTextMatchingPreviewStillPublishesCommit() {
        let injector = MockTextInjector()
        let router = VoiceTranscriptionRouter(
            aliases: [:],
            injector: injector,
            indicator: MockIndicator()
        )
        var committed: [String] = []
        router.onFinalCommit = { committed.append($0) }
        router.beginRecording()
        router.handleResult(text: "完成", isFinal: false, isRecording: true)

        router.handleResult(text: "完成", isFinal: true, isRecording: false)

        XCTAssertEqual(committed, ["完成"])
        XCTAssertEqual(
            injector.replacements,
            [ReplacementOperation(backspaces: 0, textToInsert: "完成")]
        )
    }
}

private final class MockTextInjector: VoiceTextInjecting {
    var operations: [String] = []
    var replacements: [ReplacementOperation] = []

    func replaceVoiceSpan(backspaces: Int, text: String) {
        if backspaces > 0 {
            operations.append("delete:\(backspaces)")
        }
        operations.append("insert:\(text)")
        replacements.append(
            ReplacementOperation(backspaces: backspaces, textToInsert: text)
        )
    }
}

private final class MockIndicator: VoiceIndicatorPresenting {
    var states: [VoiceIndicatorState] = []

    func show(_ state: VoiceIndicatorState, text: String?) {
        states.append(state)
    }

    func hide() {
        states.append(.hidden)
    }
}

private final class DeferredTextInjector: VoiceTextInjecting {
    private var completions: [() -> Void] = []

    func replaceVoiceSpan(backspaces: Int, text: String) {}

    func replaceVoiceSpan(
        backspaces: Int,
        text: String,
        completion: @escaping () -> Void
    ) {
        completions.append(completion)
    }

    func completeNext() {
        completions.removeFirst()()
    }
}
