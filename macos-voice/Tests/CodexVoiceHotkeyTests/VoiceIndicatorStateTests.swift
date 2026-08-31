import AppKit
import XCTest
@testable import CodexVoiceHotkey

final class VoiceIndicatorStateTests: XCTestCase {
    func testWaitingAndListeningUseStaticRecordingBars() {
        XCTAssertEqual(
            VoiceIndicatorState.waitingForAudio.visualStyle,
            .levelBars(color: .recording, animated: false)
        )
        XCTAssertEqual(
            VoiceIndicatorState.listening.visualStyle,
            .levelBars(color: .recording, animated: false)
        )
    }

    func testTranscribingUsesAnimatedProcessingBars() {
        XCTAssertEqual(
            VoiceIndicatorState.transcribing.visualStyle,
            .levelBars(color: .transcribing, animated: true)
        )
    }

    func testCountdownAndSubmittedUseIndigoStatusText() {
        XCTAssertEqual(
            VoiceIndicatorState.countdown.visualStyle,
            .statusText(color: .transcribing)
        )
        XCTAssertEqual(
            VoiceIndicatorState.submitted.visualStyle,
            .statusText(color: .transcribing)
        )
    }

    func testErrorUsesTextAndHiddenUsesNoContent() {
        XCTAssertEqual(VoiceIndicatorState.error.visualStyle, .errorText)
        XCTAssertEqual(VoiceIndicatorState.hidden.visualStyle, .none)
    }

    func testSpectrumGeometryMapsSevenLevelsDirectlyToEightThroughThirtyPoints() {
        let levels = [0.0, 0.25, 0.5, 0.75, 1.0, 0.1, 0.9]
        let expected = levels.map { CGFloat(8 + 22 * $0) }

        XCTAssertEqual(LevelBarGeometry.minimumHeight, 8)
        XCTAssertEqual(LevelBarGeometry.maximumHeight, 30)
        for (actual, expectedHeight) in zip(LevelBarGeometry.heights(for: levels), expected) {
            XCTAssertEqual(actual, expectedHeight, accuracy: 0.001)
        }
    }

    func testSpectrumGeometrySanitizesLengthAndInvalidValues() {
        XCTAssertEqual(
            LevelBarGeometry.heights(for: [.nan, -.infinity, 2]),
            [8, 8, 30, 8, 8, 8, 8]
        )
        XCTAssertEqual(
            LevelBarGeometry.heights(for: [1, 1, 1, 1, 1, 1, 1, 0]),
            Array(repeating: 30, count: 7)
        )
    }

    func testSpectrumSmootherMovesOnlyChangedBand() {
        var smoother = VoiceSpectrumSmoother()

        let result = smoother.update(to: [0, 0, 1, 0, 0, 0, 0])

        XCTAssertEqual(result, [0, 0, 0.9, 0, 0, 0, 0])
    }

    func testSpectrumSmootherAppliesExpansionAndReleasePerBand() {
        var smoother = VoiceSpectrumSmoother(
            initialLevels: [1, 0.5, 0, 0, 0, 0, 0]
        )
        let result = smoother.update(to: [0, 0.25, 1, 0, 0, 0, 0])

        XCTAssertEqual(result[0], 0.75, accuracy: 0.0001)
        let expandedQuarter = pow(0.25, 0.65)
        XCTAssertEqual(result[1], 0.5 + (expandedQuarter - 0.5) * 0.25, accuracy: 0.0001)
        XCTAssertEqual(result[2], 0.9, accuracy: 0.0001)
    }

    func testSpectrumSmootherSanitizesLengthAndResetsEveryBand() {
        var smoother = VoiceSpectrumSmoother()
        _ = smoother.update(to: [1, .nan, 1])

        XCTAssertEqual(smoother.displayedLevels, [0.9, 0, 0.9, 0, 0, 0, 0])
        smoother.reset()
        XCTAssertEqual(smoother.displayedLevels, [Double](repeating: 0, count: 7))
    }

    func testLevelSmootherRisesToNinetyPercentInOneUpdate() {
        var smoother = VoiceLevelSmoother()

        XCTAssertEqual(smoother.update(to: 1), 0.90, accuracy: 0.0001)
    }

    func testLevelSmootherExpandsQuietAndNormalSpeech() {
        XCTAssertEqual(
            VoiceLevelSmoother.expandedLevel(for: 0.25),
            pow(0.25, 0.65),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            VoiceLevelSmoother.expandedLevel(for: 0.50),
            pow(0.50, 0.65),
            accuracy: 0.0001
        )
        XCTAssertEqual(VoiceLevelSmoother.expandedLevel(for: 1), 1)
    }

    func testLevelSmootherFallsSmoothlyAcrossTwoUpdates() {
        var smoother = VoiceLevelSmoother(initialLevel: 1)

        XCTAssertEqual(smoother.update(to: 0), 0.75, accuracy: 0.0001)
        XCTAssertEqual(smoother.update(to: 0), 0.5625, accuracy: 0.0001)
    }

    func testLevelSmootherUsesExpandedIntermediateTargets() {
        var smoother = VoiceLevelSmoother(initialLevel: 0.5)
        let highTarget = pow(0.75, 0.65)
        let highResult = 0.5 + (highTarget - 0.5) * 0.90

        XCTAssertEqual(smoother.update(to: 0.75), highResult, accuracy: 0.0001)

        let lowTarget = pow(0.25, 0.65)
        let lowResult = highResult + (lowTarget - highResult) * 0.25
        XCTAssertEqual(smoother.update(to: 0.25), lowResult, accuracy: 0.0001)
    }

    func testLevelSmootherIgnoresChangesInsideExpandedDeadband() {
        var smoother = VoiceLevelSmoother(initialLevel: 0.5)
        let rawTarget = pow(0.53, 1 / 0.65)

        XCTAssertEqual(smoother.update(to: rawTarget), 0.5, accuracy: 0.0001)
    }

    func testLevelSmootherUpdatesAtExpandedDeadbandBoundary() {
        var smoother = VoiceLevelSmoother(initialLevel: 0.5)
        let rawTarget = pow(0.535, 1 / 0.65)

        XCTAssertEqual(smoother.update(to: rawTarget), 0.5315, accuracy: 0.0001)
    }

    func testLevelSmootherClampsAndSanitizesTargets() {
        var rising = VoiceLevelSmoother()
        var falling = VoiceLevelSmoother(initialLevel: 1)

        XCTAssertEqual(rising.update(to: 2), 0.90, accuracy: 0.0001)
        XCTAssertEqual(falling.update(to: -1), 0.75, accuracy: 0.0001)
        XCTAssertEqual(rising.update(to: .nan), 0.675, accuracy: 0.0001)
        XCTAssertEqual(rising.update(to: .infinity), 0.50625, accuracy: 0.0001)
    }

    func testLevelSmootherResetReturnsToSilence() {
        var smoother = VoiceLevelSmoother(initialLevel: 1)

        smoother.reset()

        XCTAssertEqual(smoother.displayedLevel, 0)
    }
}
