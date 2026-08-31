import XCTest
@testable import CodexVoiceHotkey

final class AudioCaptureLifecycleTests: XCTestCase {
    func testInitialLifecycleIsIdleWithoutAudioMetrics() {
        let lifecycle = AudioCaptureLifecycle()

        XCTAssertEqual(lifecycle.state, .idle)
        XCTAssertEqual(lifecycle.metrics, AudioCaptureMetrics())
    }

    func testStartWaitsUntilFirstFrame() {
        var lifecycle = AudioCaptureLifecycle()

        lifecycle.start()

        XCTAssertEqual(lifecycle.state, .waitingForAudio)

        lifecycle.receive(frameByteCount: 640)

        XCTAssertEqual(lifecycle.state, .capturing)
        XCTAssertEqual(lifecycle.metrics.frameCount, 1)
    }

    func testReceivingFramesAccumulatesMetricsAndMarksAudioReceived() {
        var lifecycle = AudioCaptureLifecycle()
        lifecycle.start()

        lifecycle.receive(frameByteCount: 640)
        lifecycle.receive(frameByteCount: 320)

        XCTAssertEqual(
            lifecycle.metrics,
            AudioCaptureMetrics(frameCount: 2, byteCount: 960, didReceiveAudio: true)
        )
    }

    func testStartResetsMetricsForANewCapture() {
        var lifecycle = AudioCaptureLifecycle()
        lifecycle.start()
        lifecycle.receive(frameByteCount: 640)

        lifecycle.start()

        XCTAssertEqual(lifecycle.state, .waitingForAudio)
        XCTAssertEqual(lifecycle.metrics, AudioCaptureMetrics())
    }

    func testStopTransitionsToStopping() {
        var lifecycle = AudioCaptureLifecycle()
        lifecycle.start()

        lifecycle.stop()

        XCTAssertEqual(lifecycle.state, .stopping)
    }
}
