import AVFoundation
import XCTest
@testable import CodexVoiceHotkey

final class RemoteSpeechTranscriberTests: XCTestCase {
    func testReplacedUploadCompletionCannotReportOrLeaveNewUploadUncancelled() throws {
        let client = DeferredRemoteTranscriptionClient()
        let transcriber = RemoteSpeechTranscriber(client: client)
        let firstRequestStarted = expectation(description: "first upload started")
        let secondRequestStarted = expectation(description: "second upload started")
        let staleResult = expectation(description: "stale result ignored")
        staleResult.isInverted = true
        let resultAfterCancellation = expectation(description: "cancelled replacement result ignored")
        resultAfterCancellation.isInverted = true
        client.onRequestStarted = { requestCount in
            if requestCount == 1 {
                firstRequestStarted.fulfill()
            } else if requestCount == 2 {
                secondRequestStarted.fulfill()
            }
        }
        transcriber.onResult = { text, _ in
            if text == "first" {
                staleResult.fulfill()
            } else if text == "second" {
                resultAfterCancellation.fulfill()
            }
        }

        try startAndStopRecording(transcriber, capture: TestAudioCapture())
        wait(for: [firstRequestStarted], timeout: 1)

        try startAndStopRecording(transcriber, capture: TestAudioCapture())
        wait(for: [secondRequestStarted], timeout: 1)

        client.succeedRequest(at: 0, with: "first")
        wait(for: [staleResult], timeout: 0.1)

        transcriber.cancel()
        client.succeedRequest(at: 1, with: "second")
        wait(for: [resultAfterCancellation], timeout: 0.1)
    }

    func testReplacedUploadFailureDoesNotReportIntoNewSession() throws {
        let client = DeferredRemoteTranscriptionClient()
        let transcriber = RemoteSpeechTranscriber(client: client)
        let firstRequestStarted = expectation(description: "first upload started")
        let secondRequestStarted = expectation(description: "second upload started")
        let staleError = expectation(description: "stale error ignored")
        staleError.isInverted = true
        let newestResult = expectation(description: "newest result reported")
        client.onRequestStarted = { requestCount in
            if requestCount == 1 {
                firstRequestStarted.fulfill()
            } else if requestCount == 2 {
                secondRequestStarted.fulfill()
            }
        }
        transcriber.onError = { _ in staleError.fulfill() }
        transcriber.onResult = { text, _ in
            if text == "second" {
                newestResult.fulfill()
            }
        }

        try startAndStopRecording(transcriber, capture: TestAudioCapture())
        wait(for: [firstRequestStarted], timeout: 1)

        try startAndStopRecording(transcriber, capture: TestAudioCapture())
        wait(for: [secondRequestStarted], timeout: 1)

        client.failRequest(at: 0, with: TestError.failed)
        wait(for: [staleError], timeout: 0.1)
        client.succeedRequest(at: 1, with: "second")
        wait(for: [newestResult], timeout: 1)
    }

    func testZeroFramesReportsNoAudioOnlyAfterRelease() throws {
        let transcriber = RemoteSpeechTranscriber(client: DeferredRemoteTranscriptionClient())
        let capture = TestAudioCapture()
        let noAudio = expectation(description: "no audio reported after release")
        transcriber.onError = { error in
            guard case RemoteSpeechTranscriberError.noAudio = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            noAudio.fulfill()
        }

        try transcriber.start(using: capture)

        wait(for: [], timeout: 0.05)
        transcriber.stopInput()
        wait(for: [noAudio], timeout: 1)
    }

    private func startAndStopRecording(
        _ transcriber: RemoteSpeechTranscriber,
        capture: TestAudioCapture
    ) throws {
        try transcriber.start(using: capture)
        capture.emit(try makeAudioBuffer())
        transcriber.stopInput()
    }
}

private final class TestAudioCapture: AudioCapturing {
    var onStateChange: ((AudioCaptureState, AudioCaptureMetrics) -> Void)?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onPCM16: ((Data) -> Void)?
    var onSpectrum: (([Double]) -> Void)?
    var health = AudioCaptureHealth()

    func start() throws {}
    func stop() {}
    func recover(reason: String) {}

    func emit(_ buffer: AVAudioPCMBuffer) {
        onBuffer?(buffer)
    }
}

private final class DeferredRemoteTranscriptionClient: RemoteTranscriptionClient {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<String, Error>] = []
    var onRequestStarted: ((Int) -> Void)?

    func transcribe(fileURL: URL, filename: String, contentType: String?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            let requestCount = continuations.count
            lock.unlock()
            onRequestStarted?(requestCount)
        }
    }

    func succeedRequest(at index: Int, with text: String) {
        resumeRequest(at: index, with: .success(text))
    }

    func failRequest(at index: Int, with error: Error) {
        resumeRequest(at: index, with: .failure(error))
    }

    private func resumeRequest(at index: Int, with result: Result<String, Error>) {
        lock.lock()
        let continuation = continuations[index]
        lock.unlock()
        continuation.resume(with: result)
    }
}

private enum TestError: Error {
    case failed
}

private func makeAudioBuffer() throws -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
    buffer.frameLength = 1
    guard let samples = buffer.int16ChannelData?.pointee else {
        throw NSError(domain: "RemoteSpeechTranscriberTests", code: 1)
    }
    samples[0] = 1_234
    return buffer
}
