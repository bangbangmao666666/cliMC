import AVFoundation
import XCTest
@testable import CodexVoiceHotkey

final class AudioCaptureSessionTests: XCTestCase {
    func testFirstBufferPublishesSevenBandAudioSpectrum() throws {
        let engine = FakeAudioCaptureEngine()
        let session = AudioCaptureSession(
            engine: engine,
            notificationCenter: NotificationCenter(),
            retryDelay: 0
        )
        let published = expectation(description: "seven-band spectrum")
        var receivedLevels: [Double]?
        session.onSpectrum = { levels in
            receivedLevels = levels
            published.fulfill()
        }

        try session.start()
        engine.emit(try makePCMBuffer(samples: [3_276, -3_276]))

        wait(for: [published], timeout: 1)
        XCTAssertEqual(receivedLevels?.count, LevelBarGeometry.barCount)
        XCTAssertTrue(receivedLevels?.allSatisfy { (0...1).contains($0) } ?? false)
        session.stop()
    }

    func testSecondStartDoesNotRestartWarmEngine() throws {
        let engine = FakeAudioCaptureEngine()
        let session = AudioCaptureSession(
            engine: engine,
            notificationCenter: NotificationCenter(),
            retryDelay: 0
        )

        try session.start()
        try session.start()

        XCTAssertEqual(engine.installCount, 1)
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(engine.stopCount, 0)
        session.stop()
    }

    func testWarmCaptureDiscardsIdleBuffersUntilConsumerAttaches() throws {
        let engine = FakeAudioCaptureEngine()
        let session = AudioCaptureSession(
            engine: engine,
            notificationCenter: NotificationCenter(),
            retryDelay: 0
        )
        let delivered = expectation(description: "active packet delivered")
        var packets: [Data] = []

        try session.start()
        engine.emit(try makePCMBuffer(samples: [1, 2]))
        session.onPCM16 = {
            packets.append($0)
            delivered.fulfill()
        }
        engine.emit(try makePCMBuffer(samples: [3, 4]))

        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].count, 4)
        session.stop()
    }

    func testNoFramesRemainWaitingWithoutStoppingCapture() throws {
        let engine = FakeAudioCaptureEngine()
        let session = AudioCaptureSession(engine: engine, notificationCenter: NotificationCenter(), retryDelay: 0)
        var states: [AudioCaptureState] = []
        session.onStateChange = { state, _ in states.append(state) }

        try session.start()

        XCTAssertEqual(states, [.waitingForAudio])
        XCTAssertEqual(engine.stopCount, 0)
        session.stop()
    }

    func testFirstFrameTransitionsToCapturingAndPublishesPCM16LE() throws {
        let engine = FakeAudioCaptureEngine()
        let session = AudioCaptureSession(engine: engine, notificationCenter: NotificationCenter(), retryDelay: 0)
        let captured = expectation(description: "capturing state")
        let pcm16 = expectation(description: "PCM16 data")
        var states: [AudioCaptureState] = []

        session.onStateChange = { state, _ in
            states.append(state)
            if state == .capturing { captured.fulfill() }
        }
        session.onPCM16 = { data in
            XCTAssertEqual(data.prefix(2), Data([0xD2, 0x04]))
            pcm16.fulfill()
        }

        try session.start()
        engine.emit(try makePCMBuffer(samples: [1_234, -500]))

        wait(for: [captured, pcm16], timeout: 1)
        XCTAssertEqual(states, [.waitingForAudio, .capturing])
        session.stop()
    }

    func testConsecutiveTapBuffersEachPublishNonEmptyPCM16() throws {
        let engine = FakeAudioCaptureEngine()
        let session = AudioCaptureSession(engine: engine, notificationCenter: NotificationCenter(), retryDelay: 0)
        let published = expectation(description: "two non-empty PCM packets")
        published.expectedFulfillmentCount = 2
        var packetSizes: [Int] = []

        session.onPCM16 = { data in
            packetSizes.append(data.count)
            if !data.isEmpty { published.fulfill() }
        }

        try session.start()
        engine.emit(try makePCMBuffer(samples: [1_000, 2_000]))
        engine.emit(try makePCMBuffer(samples: [3_000, 4_000]))

        wait(for: [published], timeout: 1)
        XCTAssertEqual(packetSizes, [4, 4])
        session.stop()
    }

    func testRouteChangesRemoveOldTapBeforeOneRetryInstallsReplacement() throws {
        let engine = FakeAudioCaptureEngine()
        let notificationCenter = NotificationCenter()
        let session = AudioCaptureSession(engine: engine, notificationCenter: notificationCenter, retryDelay: 0)
        let reinstalled = expectation(description: "replacement tap installed")
        engine.onInstall = { count in
            if count == 2 { reinstalled.fulfill() }
        }

        try session.start()
        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)
        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)

        wait(for: [reinstalled], timeout: 1)
        XCTAssertEqual(engine.installCount, 2)
        XCTAssertEqual(engine.removeCount, 1)
        XCTAssertEqual(engine.maximumActiveTapCount, 1)
        session.stop()
    }

    func testTapCopiesBufferBeforeAsynchronousDelivery() throws {
        let engine = FakeAudioCaptureEngine()
        let queue = DispatchQueue(label: "AudioCaptureSessionTests.copy")
        let session = AudioCaptureSession(engine: engine, notificationCenter: NotificationCenter(), retryDelay: 0, queue: queue)
        let delivered = expectation(description: "owned buffer delivered")

        session.onBuffer = { buffer in
            XCTAssertEqual(buffer.int16ChannelData?.pointee[0], 1_234)
            delivered.fulfill()
        }
        try session.start()
        queue.suspend()
        let source = try makePCMBuffer(samples: [1_234])
        engine.emit(source)
        source.int16ChannelData?.pointee[0] = 0
        queue.resume()

        wait(for: [delivered], timeout: 1)
        session.stop()
    }

    func testTapUsesConverterSourceFormatSnapshot() throws {
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        let engine = FakeAudioCaptureEngine(inputFormat: sourceFormat)
        let session = AudioCaptureSession(engine: engine, notificationCenter: NotificationCenter(), retryDelay: 0)

        try session.start()

        XCTAssertEqual(engine.installedTapFormats.count, 1)
        XCTAssertTrue(engine.installedTapFormats[0] === sourceFormat)
        session.stop()
    }

    func testHealthTracksRawFrameAndDeliveredPCM() throws {
        var now: UInt64 = 1_000
        let engine = FakeAudioCaptureEngine()
        let session = AudioCaptureSession(
            engine: engine,
            notificationCenter: NotificationCenter(),
            inputMonitor: FakeDefaultAudioInputMonitor(),
            retryDelay: 0,
            nowNanoseconds: { now }
        )
        try session.start()

        engine.emit(try makePCMBuffer(samples: [1, 2]))
        waitUntil { session.health.lastFrameNanoseconds == 1_000 }
        XCTAssertEqual(session.health.pcmDeliveryCount, 0)
        XCTAssertEqual(session.health.consumerDeliveryCount, 0)

        session.onPCM16 = { _ in }
        now = 2_000
        engine.emit(try makePCMBuffer(samples: [3, 4]))
        waitUntil { session.health.pcmDeliveryCount == 1 }

        XCTAssertEqual(session.health.lastFrameNanoseconds, 2_000)
        XCTAssertEqual(session.health.pcmDeliveryCount, 1)
        XCTAssertEqual(session.health.consumerDeliveryCount, 1)
    }

    func testHealthTracksRawBufferConsumerDelivery() throws {
        let engine = FakeAudioCaptureEngine()
        let session = AudioCaptureSession(
            engine: engine,
            notificationCenter: NotificationCenter(),
            inputMonitor: FakeDefaultAudioInputMonitor(),
            retryDelay: 0
        )
        session.onBuffer = { _ in }
        try session.start()

        engine.emit(try makePCMBuffer(samples: [1, 2]))
        waitUntil { session.health.consumerDeliveryCount == 1 }

        XCTAssertEqual(session.health.pcmDeliveryCount, 0)
        XCTAssertEqual(session.health.consumerDeliveryCount, 1)
    }

    func testDefaultInputChangeRebuildsWithoutEngineConfigurationNotification() throws {
        let engine = FakeAudioCaptureEngine()
        let monitor = FakeDefaultAudioInputMonitor()
        let session = AudioCaptureSession(
            engine: engine,
            notificationCenter: NotificationCenter(),
            inputMonitor: monitor,
            retryDelay: 0
        )
        try session.start()

        monitor.emitChange()
        waitUntil { engine.installCount == 2 }

        XCTAssertEqual(engine.removeCount, 1)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(session.health.recoveryGeneration, 1)
    }

    func testConcurrentRecoverySignalsCoalesceIntoOneRestart() throws {
        let engine = FakeAudioCaptureEngine()
        let monitor = FakeDefaultAudioInputMonitor()
        let session = AudioCaptureSession(
            engine: engine,
            notificationCenter: NotificationCenter(),
            inputMonitor: monitor,
            retryDelay: 1
        )
        try session.start()

        monitor.emitChange()
        session.recover(reason: "watchdog")
        session.recover(reason: "release")

        XCTAssertEqual(engine.removeCount, 1)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(session.health.recoveryGeneration, 1)
    }

    func testBufferFromRemovedTapCannotMarkReplacementHealthy() throws {
        let engine = FakeAudioCaptureEngine()
        let session = AudioCaptureSession(
            engine: engine,
            notificationCenter: NotificationCenter(),
            inputMonitor: FakeDefaultAudioInputMonitor(),
            retryDelay: 0,
            nowNanoseconds: { 123 }
        )
        session.onPCM16 = { _ in }
        try session.start()
        session.recover(reason: "test")
        waitUntil { engine.installCount == 2 }

        engine.emitFromInstalledTap(at: 0, buffer: try makePCMBuffer(samples: [1, 2]))
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))

        XCTAssertNil(session.health.lastFrameNanoseconds)
        XCTAssertEqual(session.health.consumerDeliveryCount, 0)

        engine.emit(try makePCMBuffer(samples: [3, 4]))
        waitUntil { session.health.consumerDeliveryCount == 1 }
        XCTAssertEqual(session.health.lastFrameNanoseconds, 123)
    }

    func testBufferFromFailedStartTapCannotMarkRetryHealthy() throws {
        let engine = FakeAudioCaptureEngine()
        engine.startFailuresRemaining = 1
        let session = AudioCaptureSession(
            engine: engine,
            notificationCenter: NotificationCenter(),
            inputMonitor: FakeDefaultAudioInputMonitor(),
            retryDelay: 0,
            nowNanoseconds: { 456 }
        )
        session.onPCM16 = { _ in }
        try session.start()
        waitUntil { engine.installCount == 2 }

        engine.emitFromInstalledTap(at: 0, buffer: try makePCMBuffer(samples: [1, 2]))
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))

        XCTAssertNil(session.health.lastFrameNanoseconds)
        XCTAssertEqual(session.health.consumerDeliveryCount, 0)
    }
}

private final class FakeAudioCaptureEngine: AudioCaptureEngine {
    let inputFormat: AVAudioFormat
    var configurationChangeObject: AnyObject { self }
    private(set) var installCount = 0
    private(set) var installedTapFormats: [AVAudioFormat] = []
    private(set) var removeCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var maximumActiveTapCount = 0
    var startFailuresRemaining = 0
    var onInstall: ((Int) -> Void)?
    private var tap: ((AVAudioPCMBuffer) -> Void)?
    private var installedTaps: [(AVAudioPCMBuffer) -> Void] = []
    private var activeTapCount = 0

    init(
        inputFormat: AVAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    ) {
        self.inputFormat = inputFormat
    }

    func installTap(format: AVAudioFormat, _ tap: @escaping (AVAudioPCMBuffer) -> Void) {
        installCount += 1
        installedTapFormats.append(format)
        activeTapCount += 1
        self.tap = tap
        installedTaps.append(tap)
        maximumActiveTapCount = max(maximumActiveTapCount, activeTapCount)
        onInstall?(installCount)
    }

    func removeTap() {
        removeCount += 1
        tap = nil
        activeTapCount = 0
    }

    func prepare() {}
    func start() throws {
        startCount += 1
        if startFailuresRemaining > 0 {
            startFailuresRemaining -= 1
            throw NSError(domain: "FakeAudioCaptureEngine", code: 1)
        }
    }
    func stop() { stopCount += 1 }

    func emit(_ buffer: AVAudioPCMBuffer) {
        tap?(buffer)
    }

    func emitFromInstalledTap(at index: Int, buffer: AVAudioPCMBuffer) {
        installedTaps[index](buffer)
    }
}

private func makePCMBuffer(samples: [Int16]) throws -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    guard let channel = buffer.int16ChannelData?.pointee else {
        throw NSError(domain: "AudioCaptureSessionTests", code: 1)
    }
    for (index, sample) in samples.enumerated() {
        channel[index] = sample
    }
    return buffer
}

private final class FakeDefaultAudioInputMonitor: DefaultAudioInputMonitoring {
    var onChange: (() -> Void)?
    func start() {}
    func stop() {}
    func emitChange() { onChange?() }
}

private func waitUntil(
    timeout: TimeInterval = 1,
    condition: @escaping () -> Bool
) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    }
    XCTAssertTrue(condition())
}
