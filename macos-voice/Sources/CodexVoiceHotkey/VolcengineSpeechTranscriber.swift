import Foundation

enum VolcengineSpeechError: LocalizedError {
    case missingCredentials
    case connection(String)
    case invalidResponse
    case server(code: Int32, message: String)
    case protocolFailure(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "火山引擎 ASR API Key 不能为空。"
        case let .connection(message): "火山引擎 ASR 连接失败：\(message)"
        case .invalidResponse: "火山引擎 ASR 返回了无法识别的结果。"
        case let .server(code, message): "火山引擎 ASR 服务端错误（\(code)）：\(message)"
        case let .protocolFailure(message): "火山引擎 ASR 协议错误：\(message)"
        }
    }
}

protocol VolcengineWebSocket: AnyObject {
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    func resume()
    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping @Sendable (Error?) -> Void
    )
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: VolcengineWebSocket {}

final class VolcengineSpeechTranscriber: VoiceTranscribing {
    typealias SocketFactory = (URLRequest) -> any VolcengineWebSocket

    static let defaultFinalizationTimeout: TimeInterval = 5

    var onResult: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    private static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    private static let legacyEndpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel")!

    private let apiKey: String
    private let appKey: String
    private let accessKey: String
    private let finalizationTimeout: TimeInterval
    private let replayByteLimit: Int
    private let socketFactory: SocketFactory

    private var socket: (any VolcengineWebSocket)?

    // Session-level state (per recording)
    private weak var capture: (any AudioCapturing)?
    private var receiveTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var sessionTracker = VolcengineSessionTracker()
    private var sequence: Int32 = 0
    private var sessionID = UUID().uuidString
    private var isAcceptingInput = false
    private var isFinalizing = false
    private var audioFrameCount = 0
    private var audioByteCount = 0
    private var retryCount = 0
    private let maximumRetryCount = 3
    private var replayBuffer = VolcenginePCMReplayBuffer(byteLimit: 9_600_000)
    private var diagnosticSessionID = "--------"
    private var recordingStartedAt: DispatchTime?
    private var didLogFirstAudio = false
    private var didLogFirstResponse = false

    init(
        apiKey: String,
        appKey: String = "",
        accessKey: String = "",
        session: URLSession = .shared,
        finalizationTimeout: TimeInterval = VolcengineSpeechTranscriber.defaultFinalizationTimeout,
        replayByteLimit: Int = 9_600_000,
        socketFactory: SocketFactory? = nil
    ) {
        self.apiKey = apiKey
        self.appKey = appKey
        self.accessKey = accessKey
        self.finalizationTimeout = finalizationTimeout
        self.replayByteLimit = replayByteLimit
        self.socketFactory = socketFactory ?? { request in
            session.webSocketTask(with: request)
        }
    }

    deinit {
        cancel()
    }

    func start(using capture: any AudioCapturing) throws {
        guard !apiKey.isEmpty || (!appKey.isEmpty && !accessKey.isEmpty) else {
            throw VolcengineSpeechError.missingCredentials
        }
        cancel()
        audioFrameCount = 0
        audioByteCount = 0
        retryCount = 0
        replayBuffer = VolcenginePCMReplayBuffer(byteLimit: replayByteLimit)
        diagnosticSessionID = String(UUID().uuidString.prefix(8))
        recordingStartedAt = .now()
        didLogFirstAudio = false
        didLogFirstResponse = false
        isAcceptingInput = true
        isFinalizing = false

        try connect()
        try beginSession(replay: [])

        self.capture = capture
        capture.onPCM16 = { [weak self] pcm16 in
            self?.consumePCM16(pcm16)
        }
    }

    /// Start a new session on an existing WebSocket connection.
    private func beginSession(replay packets: [Data]) throws {
        sequence = 1
        sessionID = UUID().uuidString
        let vocabulary = CustomVocabulary.load()
        let initialFrame = try VolcengineFrame.initialRequest(sequence: sequence, vocabulary: vocabulary)
        sequence += 1
        let generation = sessionTracker.begin()
        guard let socket else {
            throw VolcengineSpeechError.connection("连接已断开")
        }
        receiveTask?.cancel()
        receiveTask = Task { [weak self, socket] in
            await self?.receiveLoop(for: socket, generation: generation)
        }
        socket.send(.data(initialFrame)) { [weak self, socket] error in
            self?.report(error, stage: "发送首个请求包", generation: generation, socket: socket)
        }
        sessionLog("已发送首个请求包，序号 1")
        for packet in packets {
            try sendPCM16(packet, generation: generation, socket: socket, countAsLiveAudio: false)
        }
        if isFinalizing {
            sendFinalPacket(generation: generation, socket: socket)
        }
    }

    /// Clean up session state but keep the WebSocket connection alive.
    private func endSession() {
        sessionTracker.invalidate()
        isAcceptingInput = false
        isFinalizing = false
        detachCapture()
        finalizationTask?.cancel()
        finalizationTask = nil
        receiveTask?.cancel()
        receiveTask = nil
    }

    private func beginSocketSession(replay packets: [Data]) throws {
        try connect()
        try beginSession(replay: packets)
    }

    private func connect() throws {
        let request = makeRequest()
        let socket = socketFactory(request)
        self.socket = socket
        socket.resume()
        sessionLog("建立连接：资源 \(request.value(forHTTPHeaderField: "X-Api-Resource-Id") ?? "未知")")
    }

    private func makeRequest() -> URLRequest {
        let legacy = apiKey.isEmpty
        let resourceID = legacy ? "volc.bigasr.sauc.duration" : "volc.seedasr.sauc.duration"
        var request = URLRequest(url: legacy ? Self.legacyEndpoint : Self.endpoint)
        if legacy {
            request.setValue(appKey, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        } else {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        }
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        return request
    }

    func stopInput() {
        guard isAcceptingInput,
              let generation = sessionTracker.activeGeneration,
              let socket,
              isActive(generation, socket: socket) else { return }
        isAcceptingInput = false
        isFinalizing = true
        detachCapture()
        log("火山 ASR 停止输入：已发送音频帧 \(audioFrameCount)，PCM \(audioByteCount) bytes，结束序号 \(sequence)")

        sendFinalPacket(generation: generation, socket: socket)
    }

    func cancel() {
        endSession()
        let sock = socket
        socket = nil
        sock?.cancel(with: .goingAway, reason: nil)
    }

    private func consumePCM16(_ pcm16: Data) {
        guard let generation = sessionTracker.activeGeneration, let socket else { return }
        guard isAcceptingInput, !pcm16.isEmpty, isActive(generation, socket: socket) else { return }
        if !didLogFirstAudio, let recordingStartedAt {
            didLogFirstAudio = true
            let elapsed = DispatchTime.now().uptimeNanoseconds - recordingStartedAt.uptimeNanoseconds
            sessionLog("热键会话到首个 PCM \(String(format: "%.1f", Double(elapsed) / 1_000_000)) ms")
        }
        _ = replayBuffer.append(pcm16)

        do {
            try sendPCM16(pcm16, generation: generation, socket: socket, countAsLiveAudio: true)
        } catch {
            guard isActive(generation, socket: socket) else { return }
            log("火山 ASR 音频帧编码失败：\(error.localizedDescription)")
            onError?(error)
            cancel()
        }
    }

    private func sendPCM16(
        _ pcm16: Data,
        generation: VolcengineSessionGeneration,
        socket: any VolcengineWebSocket,
        countAsLiveAudio: Bool
    ) throws {
        let frame = try VolcengineFrame.audio(
            pcm16,
            sequence: sequence,
            sessionID: sessionID,
            isFinal: false
        )
        let frameSequence = sequence
        sequence += 1
        if countAsLiveAudio {
            audioFrameCount += 1
            audioByteCount += pcm16.count
            if audioFrameCount == 1 || audioFrameCount % 20 == 0 {
                log("火山 ASR 音频帧 #\(audioFrameCount)：PCM \(pcm16.count) bytes，累计 \(audioByteCount) bytes，序号 \(frameSequence)")
            }
        }
        socket.send(.data(frame)) { [weak self, socket] error in
            self?.report(error, stage: "发送音频包", generation: generation, socket: socket)
        }
    }

    private func sendFinalPacket(
        generation: VolcengineSessionGeneration,
        socket: any VolcengineWebSocket
    ) {
        let frame = Self.finalAudioFrame(sequence: sequence)
        sequence += 1
        socket.send(.data(frame)) { [weak self, socket] error in
            self?.report(error, stage: "发送结束包", generation: generation, socket: socket)
        }
        scheduleFinalizationTimeout(generation: generation, socket: socket)
    }

    private func scheduleFinalizationTimeout(
        generation: VolcengineSessionGeneration,
        socket: any VolcengineWebSocket
    ) {
        finalizationTask?.cancel()
        let nanoseconds = UInt64(max(0, finalizationTimeout) * 1_000_000_000)
        finalizationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self, self.isFinalizing, self.isActive(generation, socket: socket) else { return }
            self.handleTransientFailure(
                .connection("等待最终识别结果超时"),
                generation: generation,
                socket: socket
            )
        }
    }

    private func receiveLoop(for socket: any VolcengineWebSocket, generation: VolcengineSessionGeneration) async {
        while !Task.isCancelled, isActive(generation, socket: socket) {
            do {
                let message = try await socket.receive()
                guard isActive(generation, socket: socket) else { return }
                if !didLogFirstResponse {
                    didLogFirstResponse = true
                    sessionLog("收到首个服务端响应")
                }
                switch message {
                case .data(let data):
                    log("火山 ASR 收到二进制响应：\(data.count) bytes")
                case .string(let text):
                    log("火山 ASR 收到文本响应：\(text.prefix(300))")
                @unknown default:
                    log("火山 ASR 收到未知 WebSocket 消息")
                }
                guard case let .data(data) = message else {
                    continue
                }
                switch try VolcengineInboundFrame.parse(data) {
                case .result(let result):
                    log("火山 ASR 解析结果：文本 \(result.text.count) 字符，最终结果 \(result.isFinal)")
                    if !result.text.isEmpty {
                        guard isActive(generation, socket: socket) else { return }
                        onResult?(result.text, result.isFinal)
                    }
                    if result.isFinal {
                        finishSession(generation: generation, socket: socket)
                        return
                    }
                case let .serverError(code, message):
                    let error = VolcengineSpeechError.server(code: code, message: message)
                    log(error.localizedDescription)
                    onError?(error)
                    cancel()
                    return
                }
            } catch is CancellationError {
                return
            } catch let error as VolcengineSpeechError {
                guard isActive(generation, socket: socket) else { return }
                onError?(error)
                cancel()
                return
            } catch {
                guard isActive(generation, socket: socket) else { return }
                log("火山 ASR WebSocket 接收失败：\(error.localizedDescription)")
                handleTransientFailure(
                    .connection(error.localizedDescription),
                    generation: generation,
                    socket: socket
                )
                return
            }
        }
    }

    private func finishSession(
        generation: VolcengineSessionGeneration,
        socket: any VolcengineWebSocket
    ) {
        guard isActive(generation, socket: socket) else { return }
        endSession()
        self.socket = nil
        socket.cancel(with: .normalClosure, reason: nil)
    }

    private func detachCapture() {
        capture?.onPCM16 = nil
        capture = nil
    }

    private func report(
        _ error: Error?,
        stage: String,
        generation: VolcengineSessionGeneration,
        socket: any VolcengineWebSocket
    ) {
        guard let error, isActive(generation, socket: socket) else { return }
        log("火山 ASR \(stage)失败：\(error.localizedDescription)")
        handleTransientFailure(
            .connection("\(stage)：\(error.localizedDescription)"),
            generation: generation,
            socket: socket
        )
    }

    private func handleTransientFailure(
        _ error: VolcengineSpeechError,
        generation: VolcengineSessionGeneration,
        socket: any VolcengineWebSocket
    ) {
        guard isActive(generation, socket: socket) else { return }
        let canRetry = retryCount < maximumRetryCount
            && replayBuffer.isComplete
            && !replayBuffer.packets.isEmpty
        if canRetry {
            retryCount += 1
            finalizationTask?.cancel()
            finalizationTask = nil
            receiveTask?.cancel()
            receiveTask = nil
            sessionTracker.invalidate(generation)
            self.socket = nil
            socket.cancel(with: .goingAway, reason: nil)
            sessionLog("临时失败，正在重试 \(retryCount)/\(maximumRetryCount)，重放 \(replayBuffer.byteCount) bytes：\(error.localizedDescription)")
            do {
                try beginSocketSession(replay: replayBuffer.packets)
            } catch {
                onError?(error)
                cancel()
            }
            return
        }
        onError?(error)
        cancel()
    }

    private func isActive(_ generation: VolcengineSessionGeneration, socket: any VolcengineWebSocket) -> Bool {
        guard sessionTracker.isActive(generation), let activeSocket = self.socket else { return false }
        return ObjectIdentifier(activeSocket) == ObjectIdentifier(socket)
    }

    private func sessionLog(_ message: String) {
        log("[\(diagnosticSessionID)] 火山 ASR \(message)")
    }

    private static func finalAudioFrame(sequence: Int32) -> Data {
        // libcompression does not emit a stream for zero-byte input. The SAUC
        // final packet still requires a gzip-compressed empty audio payload, so
        // use the canonical empty gzip member instead of inventing an audio byte.
        let emptyGzip = Data([
            0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
            0x03, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])
        var frame = Data([0x11, 0x23, 0x11, 0x00])
        appendBigEndian(-sequence, to: &frame)
        appendBigEndian(Int32(emptyGzip.count), to: &frame)
        frame.append(emptyGzip)
        return frame
    }

    private static func appendBigEndian(_ value: Int32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
