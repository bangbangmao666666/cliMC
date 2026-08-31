import Speech

final class SpeechTranscriberSessionGate {
    typealias Generation = UInt64

    private var nextGeneration: Generation = 0
    private var activeGeneration: Generation?

    func begin() -> Generation {
        nextGeneration &+= 1
        activeGeneration = nextGeneration
        return nextGeneration
    }

    func isCurrent(_ generation: Generation) -> Bool {
        activeGeneration == generation
    }

    @discardableResult
    func finish(_ generation: Generation) -> Bool {
        guard activeGeneration == generation else { return false }
        activeGeneration = nil
        return true
    }

    func invalidate() {
        activeGeneration = nil
    }
}

final class SpeechTranscriber: VoiceTranscribing {
    var onResult: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private weak var capture: (any AudioCapturing)?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let sessionGate = SpeechTranscriberSessionGate()

    func start(using capture: any AudioCapturing) throws {
        cancel()
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "CodexVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "中文语音识别暂不可用"])
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        let generation = sessionGate.begin()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error, generation: generation)
        }
        self.capture = capture
        capture.onBuffer = { [weak request] buffer in
            request?.append(buffer)
        }
    }

    func stopInput() {
        detachCapture()
        request?.endAudio()
    }

    func cancel() {
        sessionGate.invalidate()
        detachCapture()
        request?.endAudio()
        task?.cancel()
        cleanup()
    }

    private func handle(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        generation: SpeechTranscriberSessionGate.Generation
    ) {
        guard sessionGate.isCurrent(generation) else { return }

        if let result {
            onResult?(result.bestTranscription.formattedString, result.isFinal)
            if result.isFinal { finish(generation: generation) }
        }
        if let error, sessionGate.isCurrent(generation) {
            onError?(error)
            finish(generation: generation)
        }
    }

    private func finish(generation: SpeechTranscriberSessionGate.Generation) {
        guard sessionGate.finish(generation) else { return }
        detachCapture()
        cleanup()
    }

    private func detachCapture() {
        capture?.onBuffer = nil
        capture = nil
    }

    private func cleanup() {
        request = nil
        task = nil
    }
}
