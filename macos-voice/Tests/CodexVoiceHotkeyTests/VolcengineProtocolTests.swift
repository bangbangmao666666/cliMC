import AVFoundation
import Compression
import Foundation
import XCTest
@testable import CodexVoiceHotkey

final class VolcengineProtocolTests: XCTestCase {
    func testVolcengineDefaultFinalizationTimeoutAllowsSecondPassRecognition() {
        XCTAssertEqual(VolcengineSpeechTranscriber.defaultFinalizationTimeout, 5)
    }

    func testReplayBufferRetainsCompletePacketsWithinLimit() {
        var buffer = VolcenginePCMReplayBuffer(byteLimit: 8)

        XCTAssertTrue(buffer.append(Data(repeating: 1, count: 4)))
        XCTAssertTrue(buffer.append(Data(repeating: 2, count: 4)))
        XCTAssertTrue(buffer.isComplete)
        XCTAssertEqual(buffer.packets.map(\.count), [4, 4])
    }

    func testReplayBufferMarksItselfIncompleteInsteadOfKeepingPartialAudio() {
        var buffer = VolcenginePCMReplayBuffer(byteLimit: 4)

        XCTAssertTrue(buffer.append(Data(repeating: 1, count: 4)))
        XCTAssertFalse(buffer.append(Data(repeating: 2, count: 4)))
        XCTAssertFalse(buffer.isComplete)
        XCTAssertTrue(buffer.packets.isEmpty)
    }

    func testTransientFinalizationTimeoutReplaysCachedPCMExactlyOnce() throws {
        let capture = FakeAudioCapture()
        let first = FakeVolcengineWebSocket()
        let retry = FakeVolcengineWebSocket()
        let replaySent = expectation(description: "cached PCM replayed")
        retry.onSend = { count in
            if count == 3 { replaySent.fulfill() }
        }
        // Provide extra sockets so subsequent retries don't crash before cancel()
        let trailing = [FakeVolcengineWebSocket(), FakeVolcengineWebSocket()]
        var sockets = [first, retry] + trailing
        let transcriber = VolcengineSpeechTranscriber(
            apiKey: "test-key",
            finalizationTimeout: 0.05,
            socketFactory: { _ in sockets.removeFirst() }
        )
        var errors: [Error] = []
        transcriber.onError = { errors.append($0) }

        try transcriber.start(using: capture)
        capture.emitPCM16(Data(repeating: 7, count: 640))
        transcriber.stopInput()

        wait(for: [replaySent], timeout: 1)
        transcriber.cancel()
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(retry.sentData.count, 3)
        XCTAssertEqual(sequence(in: retry.sentData[0]), 1)
        XCTAssertEqual(sequence(in: retry.sentData[1]), 2)
        XCTAssertEqual(sequence(in: retry.sentData[2]), -3)
    }

    func testTransientTimeoutRetriesUpToMaximumBeforeReportingOneFinalError() throws {
        let capture = FakeAudioCapture()
        let first = FakeVolcengineWebSocket()
        let retry1 = FakeVolcengineWebSocket()
        let retry2 = FakeVolcengineWebSocket()
        let retry3 = FakeVolcengineWebSocket()
        var sockets = [first, retry1, retry2, retry3]
        let transcriber = VolcengineSpeechTranscriber(
            apiKey: "test-key",
            finalizationTimeout: 0.02,
            socketFactory: { _ in sockets.removeFirst() }
        )
        let failed = expectation(description: "retry exhausted")
        var errors: [Error] = []
        transcriber.onError = {
            errors.append($0)
            failed.fulfill()
        }

        try transcriber.start(using: capture)
        capture.emitPCM16(Data(repeating: 7, count: 640))
        transcriber.stopInput()

        wait(for: [failed], timeout: 1)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(sockets.isEmpty)
    }

    func testIncompleteReplayCacheSkipsRetry() throws {
        let capture = FakeAudioCapture()
        let socket = FakeVolcengineWebSocket()
        var socketFactoryCallCount = 0
        let transcriber = VolcengineSpeechTranscriber(
            apiKey: "test-key",
            finalizationTimeout: 0.02,
            replayByteLimit: 4,
            socketFactory: { _ in
                socketFactoryCallCount += 1
                return socket
            }
        )
        let failed = expectation(description: "incomplete cache cannot retry")
        transcriber.onError = { _ in failed.fulfill() }

        try transcriber.start(using: capture)
        capture.emitPCM16(Data(repeating: 7, count: 640))
        transcriber.stopInput()

        wait(for: [failed], timeout: 1)
        XCTAssertEqual(socketFactoryCallCount, 1)
    }

    func testServerErrorDoesNotRetry() throws {
        let message = #"{"error":"invalid api key"}"#
        let socket = FakeVolcengineWebSocket(
            nextMessage: .data(makeServerErrorFrame(code: 40_100_100, payload: message))
        )
        var socketFactoryCallCount = 0
        let transcriber = VolcengineSpeechTranscriber(
            apiKey: "test-key",
            finalizationTimeout: 0.02,
            socketFactory: { _ in
                socketFactoryCallCount += 1
                return socket
            }
        )
        let failed = expectation(description: "server error delivered")
        transcriber.onError = { error in
            guard case VolcengineSpeechError.server = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            failed.fulfill()
        }

        try transcriber.start(using: FakeAudioCapture())

        wait(for: [failed], timeout: 1)
        XCTAssertEqual(socketFactoryCallCount, 1)
    }

    func testSessionGenerationRejectsReplacedAndInvalidatedSessions() {
        var tracker = VolcengineSessionTracker()
        let first = tracker.begin()

        XCTAssertTrue(tracker.isActive(first))

        let replacement = tracker.begin()
        XCTAssertNotEqual(first, replacement)
        XCTAssertFalse(tracker.isActive(first))
        XCTAssertTrue(tracker.isActive(replacement))

        tracker.invalidate(replacement)
        XCTAssertFalse(tracker.isActive(replacement))
    }

    func testStartConnectionFrameContainsEventAndJSONPayload() throws {
        let frame = try VolcengineFrame.startConnection()
        XCTAssertEqual(frame[0], 0x14)
        XCTAssertEqual(frame[1], 0x14)
        XCTAssertEqual(frame[2], 0x10)
        XCTAssertEqual(frame.suffix(2), Data("{}".utf8))
    }

    func testInitialRequestUsesCodexCommandRecognitionParameters() throws {
        let frame = try VolcengineFrame.initialRequest(sequence: 1)
        let request = try initialRequestJSON(from: frame)
        let options = try XCTUnwrap(request["request"] as? [String: Any])

        XCTAssertEqual(options["model_name"] as? String, "bigmodel")
        XCTAssertEqual(options["enable_nonstream"] as? Bool, true)
        XCTAssertEqual(options["enable_itn"] as? Bool, false)
        XCTAssertEqual(options["enable_speaker_info"] as? Bool, false)
        XCTAssertEqual(options["enable_punc"] as? Bool, false)
        XCTAssertEqual(options["enable_ddc"] as? Bool, false)
        XCTAssertEqual(options["show_utterances"] as? Bool, false)
        XCTAssertEqual(options["result_type"] as? String, "full")
    }

    func testAudioFrameMatchesPythonDemoSequenceAndGzipFormat() throws {
        let frame = try VolcengineFrame.audio(Data(repeating: 1, count: 1024), sequence: 7, sessionID: "session", isFinal: false)
        XCTAssertEqual(frame[0], 0x11)
        XCTAssertEqual(frame[1], 0x21)
        XCTAssertEqual(frame[2], 0x11)
        XCTAssertEqual(frame[4..<8], Data([0, 0, 0, 7]))
        XCTAssertNotEqual(frame.suffix(3), Data(repeating: 1, count: 3))
    }

    func testVolcengineAudioFrameUsesSequenceAfterInitialRequest() throws {
        _ = try VolcengineFrame.initialRequest(sequence: 1)
        let frame = try VolcengineFrame.audio(
            Data(repeating: 0, count: 640),
            sequence: 2,
            sessionID: "test",
            isFinal: false
        )

        XCTAssertFalse(frame.isEmpty)
        XCTAssertEqual(frame[4..<8], Data([0, 0, 0, 2]))
    }

    func testVolcengineConsumesSharedPCMAndFinalizesTheNextSequence() throws {
        let capture = FakeAudioCapture()
        let socket = FakeVolcengineWebSocket()
        let transcriber = VolcengineSpeechTranscriber(
            apiKey: "test-key",
            finalizationTimeout: 10,
            socketFactory: { _ in socket }
        )

        try transcriber.start(using: capture)
        capture.emitPCM16(Data(repeating: 0, count: 640))
        transcriber.stopInput()
        capture.emitPCM16(Data(repeating: 1, count: 640))

        XCTAssertEqual(socket.sentData.count, 3)
        XCTAssertTrue(socket.didResume)
        XCTAssertFalse(socket.didCancel, "stopInput must keep receiving until a final response or timeout")
        guard socket.sentData.count == 3 else {
            transcriber.cancel()
            return
        }
        XCTAssertEqual(sequence(in: socket.sentData[0]), 1)
        XCTAssertEqual(sequence(in: socket.sentData[1]), 2)
        XCTAssertEqual(sequence(in: socket.sentData[2]), -3)
        XCTAssertEqual(socket.sentData[1][1], 0x21)
        XCTAssertEqual(socket.sentData[2][1], 0x23)
        XCTAssertEqual(socket.sentData[2][8..<12], Data([0, 0, 0, 20]))
        XCTAssertEqual(
            socket.sentData[2].dropFirst(12),
            Data([
                0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
                0x03, 0x00,
                0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
            ])
        )

        transcriber.cancel()
        XCTAssertTrue(socket.didCancel, "cancel must tear down an abandoned session immediately")
    }

    func testStaleSendFailureCannotCancelReplacementSession() throws {
        let firstCapture = FakeAudioCapture()
        let replacementCapture = FakeAudioCapture()
        let firstSocket = FakeVolcengineWebSocket(completesSendsImmediately: false)
        let replacementSocket = FakeVolcengineWebSocket()
        var sockets: [FakeVolcengineWebSocket] = [firstSocket, replacementSocket]
        let transcriber = VolcengineSpeechTranscriber(
            apiKey: "test-key",
            finalizationTimeout: 10,
            socketFactory: { _ in sockets.removeFirst() }
        )
        var errors: [Error] = []
        transcriber.onError = { errors.append($0) }

        try transcriber.start(using: firstCapture)
        try transcriber.start(using: replacementCapture)
        firstSocket.completeNextSend(with: TestError.staleCallback)
        replacementCapture.emitPCM16(Data(repeating: 0, count: 640))

        XCTAssertTrue(firstSocket.didCancel)
        XCTAssertFalse(replacementSocket.didCancel, "an old send callback must not tear down the replacement socket")
        XCTAssertTrue(errors.isEmpty, "an old send callback must not emit an error for the replacement session")
        XCTAssertEqual(replacementSocket.sentData.count, 2, "the replacement session must continue accepting audio")

        transcriber.cancel()
    }

    func testASRResponseExtractsTextAndFinalFlag() throws {
        let payload = Data(#"{"text":"你好世界","is_final":true}"#.utf8)
        let result = try VolcengineFrame.parseResponse(payload, event: .asrResponse)
        XCTAssertEqual(result.text, "你好世界")
        XCTAssertTrue(result.isFinal)
    }

    func testServerErrorFramePreservesCodeAndMessage() throws {
        let message = #"{"error":"waiting next packet timeout"}"#
        let frame = makeServerErrorFrame(code: 45_000_081, payload: message)

        let parsed = try VolcengineInboundFrame.parse(frame)

        XCTAssertEqual(
            parsed,
            .serverError(code: 45_000_081, message: message)
        )
    }

    private func initialRequestJSON(from frame: Data) throws -> [String: Any] {
        XCTAssertGreaterThanOrEqual(frame.count, 12)
        let payloadLength = Int(
            Int32(bigEndian: frame[8..<12].withUnsafeBytes {
                $0.loadUnaligned(as: Int32.self)
            })
        )
        XCTAssertGreaterThanOrEqual(payloadLength, 0)
        XCTAssertGreaterThanOrEqual(frame.count, 12 + payloadLength)
        let compressed = frame.subdata(in: 12..<(12 + payloadLength))
        let payload = try decompressGzipRequestPayload(compressed)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
    }

    private func decompressGzipRequestPayload(_ data: Data) throws -> Data {
        guard data.count >= 18, data[0] == 0x1f, data[1] == 0x8b else {
            throw VolcengineSpeechError.invalidResponse
        }
        let compressed = data.subdata(in: 10..<(data.count - 8))
        var output = Data(count: 4_096)
        let outputCapacity = output.count
        let size = output.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    outputCapacity,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard size > 0 else {
            throw VolcengineSpeechError.invalidResponse
        }
        return output.prefix(size)
    }

    private func sequence(in frame: Data) -> Int32 {
        Int32(bigEndian: frame[4..<8].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
    }

}

private func makeServerErrorFrame(code: Int32, payload: String) -> Data {
    let payloadData = Data(payload.utf8)
    var frame = Data([0x11, 0xf0, 0x10, 0x00])
    appendBigEndian(code, to: &frame)
    appendBigEndian(Int32(payloadData.count), to: &frame)
    frame.append(payloadData)
    return frame
}

private func appendBigEndian(_ value: Int32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

private final class FakeAudioCapture: AudioCapturing {
    var onStateChange: ((AudioCaptureState, AudioCaptureMetrics) -> Void)?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onPCM16: ((Data) -> Void)?
    var onSpectrum: (([Double]) -> Void)?
    var health = AudioCaptureHealth()

    func start() throws {}
    func stop() {}
    func recover(reason: String) {}

    func emitPCM16(_ data: Data) {
        onPCM16?(data)
    }
}

private final class FakeVolcengineWebSocket: VolcengineWebSocket {
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    private(set) var sentData: [Data] = []
    private(set) var didResume = false
    private(set) var didCancel = false
    private let completesSendsImmediately: Bool
    private var sendCompletions: [@Sendable (Error?) -> Void] = []
    private var nextMessage: URLSessionWebSocketTask.Message?
    var onSend: ((Int) -> Void)?

    init(
        completesSendsImmediately: Bool = true,
        nextMessage: URLSessionWebSocketTask.Message? = nil
    ) {
        self.completesSendsImmediately = completesSendsImmediately
        self.nextMessage = nextMessage
    }

    func resume() {
        didResume = true
    }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        if case let .data(data) = message {
            sentData.append(data)
            onSend?(sentData.count)
        }
        if completesSendsImmediately {
            completionHandler(nil)
        } else {
            sendCompletions.append(completionHandler)
        }
    }

    func completeNextSend(with error: Error?) {
        sendCompletions.removeFirst()(error)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if let nextMessage {
            self.nextMessage = nil
            return nextMessage
        }
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        didCancel = true
    }
}

private enum TestError: Error {
    case staleCallback
}
