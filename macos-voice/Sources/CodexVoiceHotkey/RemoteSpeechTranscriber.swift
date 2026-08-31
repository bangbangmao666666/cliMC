import AVFoundation
import Foundation

enum RemoteSpeechTranscriberError: LocalizedError {
    case noAudio

    var errorDescription: String? {
        switch self {
        case .noAudio:
            "松开按键后仍未检测到可转写的音频，请检查麦克风输入后重试。"
        }
    }
}

protocol RemoteTranscriptionClient: AnyObject {
    func transcribe(fileURL: URL, filename: String, contentType: String?) async throws -> String
}

extension SiliconFlowTranscriptionClient: RemoteTranscriptionClient {}

final class RemoteSpeechTranscriber: VoiceTranscribing {
    var onResult: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    private let client: any RemoteTranscriptionClient
    private weak var capture: (any AudioCapturing)?
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var transcriptionTask: Task<Void, Never>?
    private var isAcceptingInput = false
    private var recordingStartedAt: Date?
    private var audioBufferCount = 0
    private var audioWriteErrorCount = 0
    private var nextRecordingGeneration: UInt64 = 0
    private var currentRecordingGeneration: UInt64?

    init(settings: SiliconFlowSettings, session: URLSession = .shared) {
        client = SiliconFlowTranscriptionClient(
            baseURL: SiliconFlowSettings.baseURL,
            apiKey: settings.apiKey,
            model: SiliconFlowSettings.model,
            session: session
        )
    }

    init(client: any RemoteTranscriptionClient) {
        self.client = client
    }

    func start(using capture: any AudioCapturing) throws {
        cancel()
        let generation = beginRecordingGeneration()
        isAcceptingInput = true
        audioBufferCount = 0
        audioWriteErrorCount = 0
        self.capture = capture
        capture.onBuffer = { [weak self] buffer in
            self?.consume(buffer, for: generation)
        }
        log("远程转写已就绪，等待共享音频输入。")
    }

    func stopInput() {
        guard isAcceptingInput, let generation = currentRecordingGeneration else { return }
        isAcceptingInput = false
        detachCapture()

        guard let url = recordingURL else {
            cleanupRecording()
            log("远程转写在用户松开按键后确认没有收到音频。")
            guard isCurrentRecordingGeneration(generation) else { return }
            onError?(RemoteSpeechTranscriberError.noAudio)
            return
        }

        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        // AVAudioFile must be released before another task reads the WAV file;
        // otherwise its header may not be finalized yet.
        recordingFile = nil
        recordingURL = nil
        recordingStartedAt = nil
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
        log("本地录音已停止：时长 \(String(format: "%.2f", duration)) 秒，收到 \(audioBufferCount) 个 buffer，写入错误 \(audioWriteErrorCount) 次，文件 \(fileSize) bytes。")
        log("录音文件已关闭，准备读取并上传：\(url.path)。")

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            log("远程转写任务已创建：\(url.lastPathComponent)。")
            defer {
                try? FileManager.default.removeItem(at: url)
                if self.isCurrentRecordingGeneration(generation) {
                    self.transcriptionTask = nil
                    log("远程转写任务已清理：\(url.lastPathComponent)。")
                }
            }
            do {
                let text = try await self.client.transcribe(
                    fileURL: url,
                    filename: url.lastPathComponent,
                    contentType: "audio/wav"
                )
                guard !Task.isCancelled, self.isCurrentRecordingGeneration(generation) else { return }
                self.onResult?(text, true)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.isCurrentRecordingGeneration(generation) else { return }
                let failedURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("codex-voice-failed-\(UUID().uuidString).wav")
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.copyItem(at: url, to: failedURL)
                    log("失败音频已保留：\(failedURL.path)。")
                }
                self.onError?(error)
            }
        }
    }

    func cancel() {
        currentRecordingGeneration = nil
        isAcceptingInput = false
        detachCapture()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        let url = recordingURL
        cleanupRecording()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer, for generation: UInt64) {
        guard isAcceptingInput,
              isCurrentRecordingGeneration(generation),
              buffer.frameLength > 0
        else { return }

        if recordingFile == nil {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("climc-\(UUID().uuidString).wav")
            do {
                recordingFile = try AVAudioFile(
                    forWriting: url,
                    settings: buffer.format.settings,
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved
                )
                recordingURL = url
                recordingStartedAt = Date()
                log("共享音频首帧已创建录音文件：\(buffer.format.sampleRate) Hz，\(buffer.format.channelCount) 声道，文件 \(url.path)。")
            } catch {
                guard isCurrentRecordingGeneration(generation) else { return }
                isAcceptingInput = false
                detachCapture()
                cleanupRecording()
                log("创建录音文件失败：\(error.localizedDescription)。")
                onError?(error)
                return
            }
        }

        guard let recordingFile else { return }
        audioBufferCount += 1
        do {
            try recordingFile.write(from: buffer)
        } catch {
            audioWriteErrorCount += 1
            if audioWriteErrorCount <= 3 {
                log("音频写入失败：\(error.localizedDescription)。")
            }
        }
    }

    private func detachCapture() {
        capture?.onBuffer = nil
        capture = nil
    }

    private func cleanupRecording() {
        recordingFile = nil
        recordingURL = nil
        recordingStartedAt = nil
    }

    private func beginRecordingGeneration() -> UInt64 {
        nextRecordingGeneration &+= 1
        currentRecordingGeneration = nextRecordingGeneration
        return nextRecordingGeneration
    }

    private func isCurrentRecordingGeneration(_ generation: UInt64) -> Bool {
        currentRecordingGeneration == generation
    }
}
