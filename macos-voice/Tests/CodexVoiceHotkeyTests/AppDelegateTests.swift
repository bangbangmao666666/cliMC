import AVFoundation
import XCTest
@testable import CodexVoiceHotkey

final class AppDelegateTests: XCTestCase {
    func testVoiceControllerForwardsAudioSpectrumOnMainThreadWhileRecording() {
        let events = CallLog()
        let capture = SpyAudioCapture(events: events)
        let indicator = SpyIndicator()
        let controller = VoiceController(
            preferences: .default,
            transcriber: SpyTranscriber(events: events),
            captureFactory: { capture },
            injector: SpyTextInjector(),
            indicator: indicator
        )
        controller.beginRecording()
        let forwarded = expectation(description: "spectrum reaches indicator on main thread")
        indicator.onSpectrum = { levels in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(levels, [0.6, 0.3])
            forwarded.fulfill()
        }

        DispatchQueue.global().async {
            capture.emit(spectrum: [0.6, 0.3])
        }

        wait(for: [forwarded], timeout: 1)
    }

    func testVoiceControllerIgnoresAudioLevelAfterRecordingFinishes() {
        let events = CallLog()
        let capture = SpyAudioCapture(events: events)
        let indicator = SpyIndicator()
        var preferences = VoicePreferences.default
        preferences.releaseHoldSeconds = 0
        let controller = VoiceController(
            preferences: preferences,
            transcriber: SpyTranscriber(events: events),
            captureFactory: { capture },
            injector: SpyTextInjector(),
            indicator: indicator
        )
        controller.beginRecording()
        capture.deliverPCM()
        controller.finishRecording()

        capture.emit(spectrum: [0.8, 0.4])

        XCTAssertTrue(indicator.levels.isEmpty)
    }

    func testVoiceControllerWarmsCaptureBeforeRecordingAndTracksCaptureState() throws {
        let events = CallLog()
        let transcriber = SpyTranscriber(events: events)
        let capture = SpyAudioCapture(events: events)
        let indicator = SpyIndicator()
        let controller = VoiceController(
            preferences: .default,
            transcriber: transcriber,
            captureFactory: { capture },
            injector: SpyTextInjector(),
            indicator: indicator
        )

        controller.startCaptureIfNeeded()

        XCTAssertEqual(events.values, ["capture.start"])
        events.values = []
        controller.beginRecording()

        XCTAssertEqual(events.values, ["transcriber.start"])
        XCTAssertTrue(transcriber.capture === capture)
        XCTAssertEqual(indicator.states.last, .waitingForAudio)

        capture.emit(state: .capturing, metrics: AudioCaptureMetrics(frameCount: 1, byteCount: 640, didReceiveAudio: true))

        XCTAssertEqual(indicator.states.last, .listening)
    }

    func testVoiceControllerPublishesCaptureStateToIndicatorOnMainThread() {
        let events = CallLog()
        let capture = SpyAudioCapture(events: events)
        let indicator = SpyIndicator()
        let controller = VoiceController(
            preferences: .default,
            transcriber: SpyTranscriber(events: events),
            captureFactory: { capture },
            injector: SpyTextInjector(),
            indicator: indicator
        )
        controller.beginRecording()
        let updated = expectation(description: "capture state reaches indicator on main thread")
        indicator.onState = { state in
            guard state == .listening else { return }
            XCTAssertTrue(Thread.isMainThread)
            updated.fulfill()
        }

        DispatchQueue.global().async {
            capture.emit(
                state: .capturing,
                metrics: AudioCaptureMetrics(frameCount: 1, byteCount: 640, didReceiveAudio: true)
            )
        }

        waitForExpectations(timeout: 1)
    }

    func testVoiceControllerStopsCaptureBeforeInputAndKeepsTranscribingUntilFinalResult() {
        let events = CallLog()
        let transcriber = SpyTranscriber(events: events)
        let capture = SpyAudioCapture(events: events)
        let indicator = SpyIndicator()
        var preferences = VoicePreferences.default
        preferences.releaseHoldSeconds = 0
        let controller = VoiceController(
            preferences: preferences,
            transcriber: transcriber,
            captureFactory: { capture },
            injector: SpyTextInjector(),
            indicator: indicator
        )
        controller.beginRecording()
        XCTAssertFalse(indicator.states.contains(.error))
        capture.deliverPCM()
        events.values = []

        controller.finishRecording()

        XCTAssertEqual(events.values, ["transcriber.stopInput"])
        XCTAssertEqual(indicator.states.last, .transcribing)

        let finalHidden = expectation(description: "final result hides transcribing indicator")
        indicator.onState = { state in
            if state == .hidden { finalHidden.fulfill() }
        }
        transcriber.onResult?("完成", true)

        waitForExpectations(timeout: 1)
        XCTAssertEqual(indicator.states.last, .hidden)
    }

    func testVoiceControllerFinalizesSynchronouslyWhenReleaseHoldIsDisabled() {
        let events = CallLog()
        let transcriber = SpyTranscriber(events: events)
        let capture = SpyAudioCapture(events: events)
        let indicator = SpyIndicator()
        var preferences = VoicePreferences.default
        preferences.releaseHoldSeconds = 0
        let controller = VoiceController(
            preferences: preferences,
            transcriber: transcriber,
            captureFactory: { capture },
            injector: SpyTextInjector(),
            indicator: indicator
        )
        controller.beginRecording()
        capture.deliverPCM()
        let statesAfterBegin = indicator.states.count
        events.values = []

        controller.finishRecording()

        // With release-hold disabled, stopInput runs synchronously and
        // finishRecording does not show the buffering indicator.
        XCTAssertEqual(events.values, ["transcriber.stopInput"])
        XCTAssertFalse(indicator.states[statesAfterBegin...].contains(.waitingForAudio))
        XCTAssertEqual(indicator.states.last, .transcribing)
    }

    func testVoiceControllerWarmsOneCaptureAndReusesItAcrossHolds() {
        let events = CallLog()
        let transcriber = SpyTranscriber(events: events)
        let capture = SpyAudioCapture(events: events)
        let controller = VoiceController(
            preferences: .default,
            transcriber: transcriber,
            captureFactory: { capture },
            injector: SpyTextInjector(),
            indicator: SpyIndicator()
        )

        controller.startCaptureIfNeeded()
        controller.beginRecording()
        capture.deliverPCM()
        controller.finishRecording()
        controller.beginRecording()

        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(capture.stopCount, 0)
        XCTAssertTrue(transcriber.capture === capture)
    }

    func testReplacingSettingsStopsCaptureAndCancelsOldTranscriber() {
        let events = CallLog()
        let oldTranscriber = SpyTranscriber(events: events)
        let replacementTranscriber = SpyTranscriber(events: events)
        let capture = SpyAudioCapture(events: events)
        let controller = VoiceController(
            preferences: .default,
            transcriber: oldTranscriber,
            captureFactory: { capture },
            injector: SpyTextInjector(),
            indicator: SpyIndicator(),
            preferencesSaver: { _ in },
            transcriberFactory: { _ in replacementTranscriber }
        )
        controller.beginRecording()
        events.values = []

        var replacementPreferences = VoicePreferences.default
        replacementPreferences.transcriptionProvider = .system
        controller.apply(preferences: replacementPreferences)

        XCTAssertEqual(events.values, ["transcriber.cancel"])
        XCTAssertNotNil(capture.onStateChange)
    }

    func testReplacingSettingsIgnoresCallbacksFromCancelledTranscriber() {
        let events = CallLog()
        let oldTranscriber = SpyTranscriber(events: events)
        let indicator = SpyIndicator()
        let controller = VoiceController(
            preferences: .default,
            transcriber: oldTranscriber,
            captureFactory: { SpyAudioCapture(events: events) },
            injector: SpyTextInjector(),
            indicator: indicator,
            preferencesSaver: { _ in },
            transcriberFactory: { _ in oldTranscriber }
        )
        let staleCallback = oldTranscriber.onError
        controller.apply(preferences: .default)
        events.values = []
        let staleError = expectation(description: "cancelled transcriber callback is ignored")
        staleError.isInverted = true
        indicator.onState = { state in
            if state == .error { staleError.fulfill() }
        }

        staleCallback?(NSError(domain: "stale", code: 1))

        waitForExpectations(timeout: 0.1)
        XCTAssertTrue(events.values.isEmpty)
        XCTAssertFalse(indicator.states.contains(.error))
    }

    func testFinalTranscriptionSchedulesAndSubmitsThroughInjector() {
        let events = CallLog()
        let transcriber = SpyTranscriber(events: events)
        let injector = SpyTextInjector()
        let indicator = SpyIndicator()
        let scheduler = ControllerManualScheduler()
        var preferences = VoicePreferences.default
        preferences.autoSubmitEnabled = true
        preferences.autoSubmitDelaySeconds = 5
        let controller = VoiceController(
            preferences: preferences,
            transcriber: transcriber,
            captureFactory: { SpyAudioCapture(events: events) },
            injector: injector,
            indicator: indicator,
            autoSubmitScheduler: scheduler
        )
        let scheduled = expectation(description: "auto-submit is scheduled after final commit")
        scheduler.onSchedule = {
            scheduler.onSchedule = nil
            scheduled.fulfill()
        }

        controller.beginRecording()
        controller.finishRecording()
        transcriber.onResult?("解释代码", true)
        wait(for: [scheduled], timeout: 1)
        for index in 0..<preferences.autoSubmitDelaySeconds {
            scheduler.tasks[index].fire()
        }

        XCTAssertEqual(injector.submitCount, 1)
    }

    func testFinalTranscriptionShowsCountdownCelebrationAndDismisses() {
        let events = CallLog()
        let transcriber = SpyTranscriber(events: events)
        let injector = SpyTextInjector()
        let indicator = SpyIndicator()
        let scheduler = ControllerManualScheduler()
        var preferences = VoicePreferences.default
        preferences.autoSubmitEnabled = true
        preferences.autoSubmitDelaySeconds = 3
        let controller = VoiceController(
            preferences: preferences,
            transcriber: transcriber,
            captureFactory: { SpyAudioCapture(events: events) },
            injector: injector,
            indicator: indicator,
            autoSubmitScheduler: scheduler,
            submissionCelebration: SubmissionCelebration(indexSelector: { _ in 1 })
        )
        let scheduled = expectation(description: "countdown starts after final commit")
        scheduler.onSchedule = {
            scheduler.onSchedule = nil
            scheduled.fulfill()
        }

        controller.beginRecording()
        controller.finishRecording()
        transcriber.onResult?("解释代码", true)
        wait(for: [scheduled], timeout: 1)
        XCTAssertEqual(indicator.states.last, .countdown)
        XCTAssertEqual(indicator.texts.last!, "3")

        scheduler.tasks[0].fire()
        XCTAssertEqual(indicator.states.last, .countdown)
        XCTAssertEqual(indicator.texts.last!, "2")
        scheduler.tasks[1].fire()
        XCTAssertEqual(indicator.texts.last!, "1")
        scheduler.tasks[2].fire()
        XCTAssertEqual(injector.submitCount, 1)
        XCTAssertEqual(indicator.states.last, .submitted)
        XCTAssertEqual(indicator.texts.last!, "🌸\n🌸")
        scheduler.tasks[3].fire()
        XCTAssertEqual(indicator.states.last, .hidden)
    }

    func testStartingNewRecordingCancelsPendingSubmission() {
        let events = CallLog()
        let transcriber = SpyTranscriber(events: events)
        let injector = SpyTextInjector()
        let indicator = SpyIndicator()
        let scheduler = ControllerManualScheduler()
        var preferences = VoicePreferences.default
        preferences.autoSubmitEnabled = true
        let controller = VoiceController(
            preferences: preferences,
            transcriber: transcriber,
            captureFactory: { SpyAudioCapture(events: events) },
            injector: injector,
            indicator: indicator,
            autoSubmitScheduler: scheduler
        )
        let scheduled = expectation(description: "auto-submit is scheduled before the next recording")
        scheduler.onSchedule = {
            scheduler.onSchedule = nil
            scheduled.fulfill()
        }
        controller.beginRecording()
        controller.finishRecording()
        transcriber.onResult?("第一段", true)
        wait(for: [scheduled], timeout: 1)

        controller.beginRecording()
        scheduler.tasks[0].fireIgnoringCancellation()

        XCTAssertEqual(injector.submitCount, 0)
        XCTAssertFalse(indicator.states.contains(.submitted))
        XCTAssertEqual(indicator.states.last, .waitingForAudio)
    }

    func testApplyingSettingsCancelsPendingSubmission() {
        let events = CallLog()
        let transcriber = SpyTranscriber(events: events)
        let injector = SpyTextInjector()
        let scheduler = ControllerManualScheduler()
        var preferences = VoicePreferences.default
        preferences.autoSubmitEnabled = true
        let controller = VoiceController(
            preferences: preferences,
            transcriber: transcriber,
            captureFactory: { SpyAudioCapture(events: events) },
            injector: injector,
            indicator: SpyIndicator(),
            preferencesSaver: { _ in },
            transcriberFactory: { _ in transcriber },
            autoSubmitScheduler: scheduler
        )
        let scheduled = expectation(description: "auto-submit is scheduled before settings change")
        scheduler.onSchedule = {
            scheduler.onSchedule = nil
            scheduled.fulfill()
        }
        controller.beginRecording()
        controller.finishRecording()
        transcriber.onResult?("待提交", true)
        wait(for: [scheduled], timeout: 1)

        controller.apply(preferences: .default)
        scheduler.tasks[0].fireIgnoringCancellation()

        XCTAssertEqual(injector.submitCount, 0)
    }

    func testTranscriptionErrorCancelsPendingSubmission() {
        let events = CallLog()
        let transcriber = SpyTranscriber(events: events)
        let injector = SpyTextInjector()
        let scheduler = ControllerManualScheduler()
        var preferences = VoicePreferences.default
        preferences.autoSubmitEnabled = true
        let controller = VoiceController(
            preferences: preferences,
            transcriber: transcriber,
            captureFactory: { SpyAudioCapture(events: events) },
            injector: injector,
            indicator: SpyIndicator(),
            autoSubmitScheduler: scheduler
        )
        let scheduled = expectation(description: "auto-submit is scheduled before transcription error")
        scheduler.onSchedule = {
            scheduler.onSchedule = nil
            scheduled.fulfill()
        }
        let cancelled = expectation(description: "transcription error cancels auto-submit")
        scheduler.onCancel = { cancelled.fulfill() }
        controller.beginRecording()
        controller.finishRecording()
        transcriber.onResult?("待提交", true)
        wait(for: [scheduled], timeout: 1)

        transcriber.onError?(NSError(domain: "test", code: 1))
        wait(for: [cancelled], timeout: 1)
        scheduler.tasks[0].fireIgnoringCancellation()

        XCTAssertEqual(injector.submitCount, 0)
    }

    func testBeginRecordingRecoversStaleWarmCapture() {
        let events = CallLog()
        let capture = SpyAudioCapture(events: events)
        capture.health = AudioCaptureHealth(
            lastFrameNanoseconds: 1,
            pcmDeliveryCount: 0,
            isRunning: true,
            recoveryGeneration: 0
        )
        let scheduler = ManualWatchdogScheduler()
        let controller = VoiceController(
            preferences: .default,
            transcriber: SpyTranscriber(events: events),
            captureFactory: { capture },
            injector: SpyTextInjector(),
            indicator: SpyIndicator(),
            nowNanoseconds: { 500_000_002 },
            watchdogScheduler: scheduler.schedule
        )

        controller.beginRecording()
        scheduler.fireNext()

        XCTAssertEqual(capture.recoveryReasons, ["按键时采集帧已过期"])
    }

    func testWatchdogRecoversOnceAndKeepsRecordingActive() {
        let events = CallLog()
        let capture = SpyAudioCapture(events: events)
        capture.health = AudioCaptureHealth(
            lastFrameNanoseconds: 1_000_000_000,
            pcmDeliveryCount: 4,
            isRunning: true,
            recoveryGeneration: 0
        )
        let scheduler = ManualWatchdogScheduler()
        let transcriber = SpyTranscriber(events: events)
        var preferences = VoicePreferences.default
        preferences.releaseHoldSeconds = 0
        let controller = VoiceController(
            preferences: preferences,
            transcriber: transcriber,
            captureFactory: { capture },
            injector: SpyTextInjector(),
            indicator: SpyIndicator(),
            nowNanoseconds: { 1_000_000_000 },
            watchdogScheduler: scheduler.schedule
        )
        controller.beginRecording()

        scheduler.fireNext()
        capture.deliverPCM()
        controller.finishRecording()

        XCTAssertEqual(capture.recoveryReasons, ["录音 500ms 未收到 PCM"])
        XCTAssertEqual(events.values.filter { $0 == "transcriber.stopInput" }.count, 1)
        XCTAssertEqual(events.values.filter { $0 == "transcriber.cancel" }.count, 0)
    }

    func testPCMBeforeWatchdogAvoidsRecoveryAndFinalizesNormally() {
        let events = CallLog()
        let capture = SpyAudioCapture(events: events)
        capture.health = AudioCaptureHealth(
            lastFrameNanoseconds: 1_000_000_000,
            pcmDeliveryCount: 4,
            isRunning: true,
            recoveryGeneration: 0
        )
        let scheduler = ManualWatchdogScheduler()
        var preferences = VoicePreferences.default
        preferences.releaseHoldSeconds = 0
        let controller = VoiceController(
            preferences: preferences,
            transcriber: SpyTranscriber(events: events),
            captureFactory: { capture },
            injector: SpyTextInjector(),
            indicator: SpyIndicator(),
            nowNanoseconds: { 1_000_000_000 },
            watchdogScheduler: scheduler.schedule
        )
        controller.beginRecording()
        capture.deliverPCM()

        scheduler.fireNext()
        controller.finishRecording()

        XCTAssertTrue(capture.recoveryReasons.isEmpty)
        XCTAssertEqual(events.values.filter { $0 == "transcriber.stopInput" }.count, 1)
        XCTAssertEqual(events.values.filter { $0 == "transcriber.cancel" }.count, 0)
    }

    func testMidRecordingRouteRecoverySuppressesWatchdogRebuild() {
        let events = CallLog()
        let capture = SpyAudioCapture(events: events)
        capture.health = AudioCaptureHealth(
            lastFrameNanoseconds: 1_000_000_000,
            pcmDeliveryCount: 4,
            isRunning: true,
            recoveryGeneration: 2
        )
        let scheduler = ManualWatchdogScheduler()
        let controller = VoiceController(
            preferences: .default,
            transcriber: SpyTranscriber(events: events),
            captureFactory: { capture },
            injector: SpyTextInjector(),
            indicator: SpyIndicator(),
            nowNanoseconds: { 1_000_000_000 },
            watchdogScheduler: scheduler.schedule
        )
        controller.beginRecording()
        capture.health.recoveryGeneration = 3

        scheduler.fireNext()

        XCTAssertTrue(capture.recoveryReasons.isEmpty)
    }

    func testReleaseWithZeroPCMCancelsImmediatelyAndRequestsRecovery() {
        let events = CallLog()
        let capture = SpyAudioCapture(events: events)
        capture.health = AudioCaptureHealth(
            lastFrameNanoseconds: 1_000_000_000,
            pcmDeliveryCount: 4,
            isRunning: true,
            recoveryGeneration: 0
        )
        let indicator = SpyIndicator()
        var preferences = VoicePreferences.default
        preferences.releaseHoldSeconds = 0
        let controller = VoiceController(
            preferences: preferences,
            transcriber: SpyTranscriber(events: events),
            captureFactory: { capture },
            injector: SpyTextInjector(),
            indicator: indicator,
            nowNanoseconds: { 1_000_000_000 }
        )
        controller.beginRecording()
        events.values = []

        controller.finishRecording()

        XCTAssertEqual(events.values, ["transcriber.cancel", "capture.recover"])
        XCTAssertEqual(indicator.states.last, .error)
        XCTAssertEqual(indicator.texts.last, "未收到麦克风音频，已重建采集链路，请重试")
    }

    func testApplicationDidFinishLaunchingStartsControllerAndShowsSettings() {
        let controller = SpyVoiceController()
        let delegate = AppDelegate(controller: controller)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        XCTAssertEqual(controller.startCallCount, 1)
        XCTAssertEqual(controller.showSettingsCallCount, 1)
    }

    func testApplicationDidBecomeActiveShowsSettings() {
        let controller = SpyVoiceController()
        let delegate = AppDelegate(controller: controller)

        delegate.applicationDidBecomeActive(Notification(name: .init("test")))

        XCTAssertEqual(controller.showSettingsCallCount, 1)
    }

    func testSuccessfulRecordingStartRecordsVoiceUsage() {
        let recorder = SpyUsageStatsRecorder()
        let controller = VoiceController(
            preferences: .default,
            transcriber: SpyTranscriber(events: CallLog()),
            captureFactory: { SpyAudioCapture(events: CallLog()) },
            injector: SpyTextInjector(),
            indicator: SpyIndicator(),
            usageStatsRecorder: recorder
        )

        controller.beginRecording()

        XCTAssertEqual(recorder.voiceStartedCount, 1)
    }

    func testFinalCommitRecordsResolvedTextUsage() {
        let events = CallLog()
        let recorder = SpyUsageStatsRecorder()
        var preferences = VoicePreferences.default
        preferences.aliases = ["目标": "/goal"]
        let transcriber = SpyTranscriber(events: events)
        let controller = VoiceController(
            preferences: preferences,
            transcriber: transcriber,
            captureFactory: { SpyAudioCapture(events: events) },
            injector: SpyTextInjector(),
            indicator: SpyIndicator(),
            usageStatsRecorder: recorder
        )

        controller.beginRecording()
        controller.finishRecording()
        let committed = expectation(description: "final commit callback fires")
        recorder.onCommitted = { committed.fulfill() }
        transcriber.onResult?("目标", true)
        wait(for: [committed], timeout: 1)

        XCTAssertEqual(recorder.committedTexts, ["/goal"])
    }

    func testAutoSubmitRecordsUsageWhenSubmitExecutes() {
        let events = CallLog()
        let recorder = SpyUsageStatsRecorder()
        let transcriber = SpyTranscriber(events: events)
        let scheduler = ControllerManualScheduler()
        var preferences = VoicePreferences.default
        preferences.autoSubmitEnabled = true
        preferences.autoSubmitDelaySeconds = 1
        let controller = VoiceController(
            preferences: preferences,
            transcriber: transcriber,
            captureFactory: { SpyAudioCapture(events: events) },
            injector: SpyTextInjector(),
            indicator: SpyIndicator(),
            usageStatsRecorder: recorder,
            autoSubmitScheduler: scheduler
        )

        controller.beginRecording()
        controller.finishRecording()
        transcriber.onResult?("解释代码", true)

        // Wait for tasks to appear on the scheduler (at least one from scheduleTick)
        let deadline = Date().addingTimeInterval(1)
        while scheduler.tasks.isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard !scheduler.tasks.isEmpty else {
            XCTFail("No auto-submit task scheduled")
            return
        }

        scheduler.tasks[0].fire()

        XCTAssertEqual(recorder.autoSubmittedCount, 1)
    }
}

private final class CallLog {
    var values: [String] = []
}

private final class SpyTranscriber: VoiceTranscribing {
    var onResult: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    private let events: CallLog
    private(set) var capture: (any AudioCapturing)?

    init(events: CallLog) {
        self.events = events
    }

    func start(using capture: any AudioCapturing) throws {
        events.values.append("transcriber.start")
        self.capture = capture
    }

    func stopInput() {
        events.values.append("transcriber.stopInput")
    }

    func cancel() {
        events.values.append("transcriber.cancel")
    }
}

private final class SpyAudioCapture: AudioCapturing {
    var onStateChange: ((AudioCaptureState, AudioCaptureMetrics) -> Void)?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onPCM16: ((Data) -> Void)?
    var onSpectrum: (([Double]) -> Void)?
    var health = AudioCaptureHealth()
    private let events: CallLog
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var recoveryReasons: [String] = []

    init(events: CallLog) {
        self.events = events
    }

    func start() throws {
        startCount += 1
        health.isRunning = true
        if health.lastFrameNanoseconds == nil {
            health.lastFrameNanoseconds = DispatchTime.now().uptimeNanoseconds
        }
        events.values.append("capture.start")
        emit(state: .waitingForAudio)
    }

    func stop() {
        stopCount += 1
        events.values.append("capture.stop")
    }

    func recover(reason: String) {
        recoveryReasons.append(reason)
        events.values.append("capture.recover")
    }

    func deliverPCM() {
        health.pcmDeliveryCount &+= 1
        health.consumerDeliveryCount &+= 1
        onPCM16?(Data([0, 0]))
    }

    func emit(state: AudioCaptureState, metrics: AudioCaptureMetrics = AudioCaptureMetrics()) {
        onStateChange?(state, metrics)
    }

    func emit(spectrum: [Double]) {
        onSpectrum?(spectrum)
    }
}

private final class SpyIndicator: VoiceIndicatorPresenting {
    private(set) var states: [VoiceIndicatorState] = []
    private(set) var texts: [String?] = []
    private(set) var levels: [Double] = []
    var onState: ((VoiceIndicatorState) -> Void)?
    var onSpectrum: (([Double]) -> Void)?

    func show(_ state: VoiceIndicatorState, text: String?) {
        states.append(state)
        texts.append(text)
        onState?(state)
    }

    func hide() {
        states.append(.hidden)
        texts.append(nil)
        onState?(.hidden)
    }

    func updateSpectrum(_ levels: [Double]) {
        self.levels.append(contentsOf: levels)
        onSpectrum?(levels)
    }
}

private final class ManualWatchdogScheduler {
    private var actions: [() -> Void] = []

    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) {
        XCTAssertEqual(delay, 0.5)
        actions.append(action)
    }

    func fireNext() {
        actions.removeFirst()()
    }
}

private final class SpyTextInjector: VoiceTextInjecting, VoiceSubmitting {
    private(set) var submitCount = 0

private final class ManualWatchdogScheduler {
    private var actions: [() -> Void] = []

    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) {
        XCTAssertEqual(delay, 0.5)
        actions.append(action)
    }

    func fireNext() {
        actions.removeFirst()()
    }
}

    func replaceVoiceSpan(backspaces: Int, text: String) {}

    func submit() {
        submitCount += 1
    }
}

private final class ControllerManualTask: AutoSubmitCancellable {
    private let action: () -> Void
    private let onCancel: () -> Void
    private(set) var isCancelled = false
    private var didFire = false

    init(action: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.action = action
        self.onCancel = onCancel
    }

    func cancel() {
        isCancelled = true
        onCancel()
    }

    func fire() {
        guard !isCancelled, !didFire else { return }
        didFire = true
        action()
    }

    func fireIgnoringCancellation() {
        guard !didFire else { return }
        didFire = true
        action()
    }
}

private final class ControllerManualScheduler: AutoSubmitScheduling {
    private(set) var tasks: [ControllerManualTask] = []
    var onSchedule: (() -> Void)?
    var onCancel: (() -> Void)?

    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> AutoSubmitCancellable {
        let task = ControllerManualTask(action: action, onCancel: { [weak self] in
            self?.onCancel?()
        })
        tasks.append(task)
        onSchedule?()
        return task
    }
}

private final class SpyVoiceController: VoiceControlling {
    var startCallCount = 0
    var showSettingsCallCount = 0

    func start() {
        startCallCount += 1
    }

    func showSettings() {
        showSettingsCallCount += 1
    }
}

private final class SpyUsageStatsRecorder: UsageStatsRecording {
    private(set) var voiceStartedCount = 0
    private(set) var committedTexts: [String] = []
    private(set) var autoSubmittedCount = 0
    var onCommitted: (() -> Void)?

    func recordVoiceStarted(at date: Date) throws {
        voiceStartedCount += 1
    }

    func recordTranscriptionCommitted(text: String, at date: Date) throws {
        committedTexts.append(text)
        onCommitted?()
    }

    func recordAutoSubmitted(at date: Date) throws {
        autoSubmittedCount += 1
    }
}

// MARK: - 提交庆祝表情

extension AppDelegateTests {
    func testAutoSubmitTextPackShowsTextGrid() {
        let events = CallLog()
        let transcriber = SpyTranscriber(events: events)
        let injector = SpyTextInjector()
        let indicator = SpyIndicator()
        let scheduler = ControllerManualScheduler()
        var preferences = VoicePreferences.default
        preferences.autoSubmitEnabled = true
        preferences.autoSubmitDelaySeconds = 1

        var indices = [0, 1]
        let celebration = SubmissionCelebration(
            pack: .anime,
            indexSelector: { _ in indices.removeFirst() }
        )
        let controller = VoiceController(
            preferences: preferences,
            transcriber: transcriber,
            captureFactory: { SpyAudioCapture(events: events) },
            injector: injector,
            indicator: indicator,
            autoSubmitScheduler: scheduler,
            submissionCelebration: celebration
        )
        let scheduled = expectation(description: "auto-submit scheduled")
        scheduler.onSchedule = {
            scheduler.onSchedule = nil
            scheduled.fulfill()
        }

        controller.beginRecording()
        controller.finishRecording()
        transcriber.onResult?("解释代码", true)
        wait(for: [scheduled], timeout: 1)
        scheduler.tasks[0].fire()

        XCTAssertEqual(indicator.states.last, .submitted)
        XCTAssertEqual(indicator.texts.last, "✨\n🌸")
    }
}
