import Foundation
import XCTest
@testable import VoiceDiagnostics

final class TranscriptionDiagnosticsTests: XCTestCase {
    func testNormalSessionRecordsCaptureRequestResultAndInjection() {
        let harness = DiagnosticHarness(provider: .siliconFlow)

        harness.session.captureFirstFrame(
            metrics: .init(durationMilliseconds: 20, frameCount: 1, byteCount: 640)
        )
        harness.session.recordingStopped(
            metrics: .init(durationMilliseconds: 800, frameCount: 40, byteCount: 25_600)
        )
        harness.session.provider(.requestStarted)
        harness.session.provider(.responseFirstSeen)
        harness.session.finalResult("识别成功")
        harness.session.textInjected()

        XCTAssertEqual(harness.events.map(\.event), [
            .sessionStarted, .captureFirstFrame, .recordingStopped,
            .requestStarted, .responseFirstSeen, .finalResult, .textInjected,
        ])
    }

    func testRemoteWaitEmitsSlowAtTenAndCriticalAtFifteenSeconds() {
        let harness = DiagnosticHarness(provider: .volcengine)
        harness.session.recordingStopped(metrics: .init())
        harness.session.provider(.requestStarted)

        harness.advance(milliseconds: 9_999)
        XCTAssertFalse(harness.events.map(\.event).contains(.slow))
        harness.advance(milliseconds: 1)
        XCTAssertEqual(harness.events.last?.event, .slow)
        harness.advance(milliseconds: 5_000)
        XCTAssertEqual(harness.events.last?.event, .criticalSlow)
    }

    func testSystemWaitStartsAtRecordingStopWithoutProviderRequest() {
        let harness = DiagnosticHarness(provider: .system)

        harness.session.recordingStopped(metrics: .init())
        harness.advance(milliseconds: 10_000)

        XCTAssertEqual(harness.events.last?.event, .slow)
    }

    func testLateSuccessKeepsMarkersAndIgnoresSecondTerminalEvent() {
        let harness = DiagnosticHarness(provider: .siliconFlow)
        harness.session.recordingStopped(metrics: .init())
        harness.session.provider(.requestStarted)
        harness.advance(milliseconds: 15_000)

        harness.session.finalResult("迟到但成功")
        harness.session.fail(
            category: "internal",
            providerCode: nil,
            message: "stale",
            retainedAudio: nil
        )

        XCTAssertEqual(harness.events.map(\.event), [
            .sessionStarted, .recordingStopped, .requestStarted,
            .slow, .criticalSlow, .finalResult,
        ])
        XCTAssertEqual(harness.events.last?.attributes["character_count"], .integer(5))
        XCTAssertEqual(harness.events.last?.elapsedMilliseconds, 15_000)
    }

    func testCancellationPreventsScheduledSlowEvents() {
        let harness = DiagnosticHarness(provider: .siliconFlow)
        harness.session.recordingStopped(metrics: .init())
        harness.session.provider(.requestStarted)

        harness.session.cancel()
        harness.advance(milliseconds: 20_000)

        XCTAssertEqual(harness.events.map(\.event), [
            .sessionStarted, .recordingStopped, .requestStarted, .cancelled,
        ])
    }

    func testPartialAndFinalEventsNeverContainTranscriptText() throws {
        let harness = DiagnosticHarness(provider: .system)
        let secret = "完整敏感转写"

        harness.session.partialResult(secret)
        harness.session.finalResult(secret)

        let encoded = try harness.events.map { event in
            String(data: try JSONEncoder.diagnostic.encode(event), encoding: .utf8)!
        }.joined()
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertEqual(harness.events[1].attributes["character_count"], .integer(secret.count))
    }

    func testTextInjectedRequiresFinalResult() {
        let harness = DiagnosticHarness(provider: .system)

        harness.session.textInjected()
        harness.session.noAudio()
        harness.session.textInjected()

        XCTAssertEqual(harness.events.map(\.event), [.sessionStarted, .noAudio])
    }

    func testRetryMilestoneContainsOnlyAttemptAndReplaySize() {
        let harness = DiagnosticHarness(provider: .volcengine)

        harness.session.provider(.retryStarted(attempt: 1, replayBytes: 6_400))

        XCTAssertEqual(harness.events.last?.event, .retryStarted)
        XCTAssertEqual(harness.events.last?.attributes, [
            "attempt": .integer(1),
            "replay_bytes": .integer(6_400),
        ])
    }
}

private final class DiagnosticHarness {
    private let clock = ManualDiagnosticClock()
    private let scheduler: ManualDiagnosticScheduler
    private let sink = CapturingDiagnosticSink()
    let session: TranscriptionDiagnostics

    init(provider: DiagnosticProvider) {
        scheduler = ManualDiagnosticScheduler(clock: clock)
        session = TranscriptionDiagnostics(
            provider: provider,
            sink: sink,
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            clock: { [clock] in clock.now },
            scheduler: scheduler
        )
    }

    var events: [DiagnosticEvent] { sink.events }

    func advance(milliseconds: Int) {
        scheduler.advance(milliseconds: milliseconds)
    }
}

private final class CapturingDiagnosticSink: DiagnosticEventSink {
    private(set) var events: [DiagnosticEvent] = []
    func write(_ event: DiagnosticEvent) { events.append(event) }
}

private final class ManualDiagnosticClock {
    let origin = Date(timeIntervalSince1970: 1_753_228_800)
    var elapsedMilliseconds = 0
    var now: Date { origin.addingTimeInterval(Double(elapsedMilliseconds) / 1_000) }
}

private final class ManualDiagnosticScheduler: DiagnosticScheduling {
    private struct Entry {
        let deadline: Int
        let token: ManualScheduledDiagnostic
        let action: () -> Void
    }

    private let clock: ManualDiagnosticClock
    private var entries: [Entry] = []

    init(clock: ManualDiagnosticClock) {
        self.clock = clock
    }

    func schedule(after interval: TimeInterval, _ action: @escaping () -> Void) -> DiagnosticScheduled {
        let token = ManualScheduledDiagnostic()
        entries.append(Entry(
            deadline: clock.elapsedMilliseconds + Int(interval * 1_000),
            token: token,
            action: action
        ))
        return token
    }

    func advance(milliseconds: Int) {
        let target = clock.elapsedMilliseconds + milliseconds
        while let next = entries
            .filter({ !$0.token.isCancelled && $0.deadline <= target })
            .min(by: { $0.deadline < $1.deadline }) {
            clock.elapsedMilliseconds = next.deadline
            entries.removeAll { $0.token === next.token }
            if !next.token.isCancelled { next.action() }
        }
        clock.elapsedMilliseconds = target
    }
}

private final class ManualScheduledDiagnostic: DiagnosticScheduled {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}
