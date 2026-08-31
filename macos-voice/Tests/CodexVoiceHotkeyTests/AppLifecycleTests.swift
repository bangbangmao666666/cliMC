import XCTest
@testable import CodexVoiceHotkey

final class AppLifecycleTests: XCTestCase {
    private let webLauncherSourcePath = #filePath
        .replacingOccurrences(of: "/Tests/CodexVoiceHotkeyTests/AppLifecycleTests.swift", with: "/Sources/CodexVoiceHotkey/WebLauncher.swift")

    func testHandleReopenActivatesExistingInstance() {
        var activationCount = 0

        let handled = AppLifecycle.handleReopen {
            activationCount += 1
        }

        XCTAssertTrue(handled)
        XCTAssertEqual(activationCount, 1)
    }

    func testHandleOpenActivatesExistingInstance() {
        var activationCount = 0

        let handled = AppLifecycle.handleOpen {
            activationCount += 1
        }

        XCTAssertTrue(handled)
        XCTAssertEqual(activationCount, 1)
    }

    func testWebLauncherPassesVocabularyLearnerStatePath() throws {
        let source = try String(contentsOfFile: webLauncherSourcePath)
        let homeDirectory = try XCTUnwrap(source.range(of: "FileManager.default\n            .homeDirectoryForCurrentUser"))
        let statePathStart = try XCTUnwrap(source.range(of: "let vocabStateDataPath", range: homeDirectory.lowerBound..<source.endIndex))
        let statePathEnd = try XCTUnwrap(source.range(of: "var arguments = [", range: statePathStart.lowerBound..<source.endIndex))
        let statePathConstruction = source[statePathStart.lowerBound..<statePathEnd.lowerBound]
        let argumentsStart = try XCTUnwrap(source.range(of: "var arguments = ["))
        let argumentsEnd = try XCTUnwrap(
            source.range(
                of: "if FileManager.default.fileExists",
                range: argumentsStart.lowerBound..<source.endIndex
            )
        )
        let argumentsArray = source[argumentsStart.lowerBound..<argumentsEnd.lowerBound]

        XCTAssertTrue(statePathConstruction.contains("FileManager.default\n            .homeDirectoryForCurrentUser"))
        XCTAssertTrue(statePathConstruction.contains(".appendingPathComponent(\".config/codex-voice/vocab-learner-state.json\")"))
        XCTAssertTrue(statePathConstruction.contains(".path"))
        XCTAssertTrue(argumentsArray.contains("\"--vocab-state-data\", vocabStateDataPath"))
    }
}
