enum AudioCaptureState: Equatable {
    case idle
    case preparing
    case waitingForAudio
    case capturing
    case stopping
}

struct AudioCaptureMetrics: Equatable {
    var frameCount = 0
    var byteCount = 0
    var didReceiveAudio = false
}

struct AudioCaptureLifecycle {
    private(set) var state: AudioCaptureState = .idle
    private(set) var metrics = AudioCaptureMetrics()

    mutating func start() {
        metrics = AudioCaptureMetrics()
        state = .waitingForAudio
    }

    mutating func receive(frameByteCount: Int) {
        metrics.frameCount += 1
        metrics.byteCount += frameByteCount
        metrics.didReceiveAudio = true
        state = .capturing
    }

    mutating func waitForAudio() {
        state = .waitingForAudio
    }

    mutating func stop() {
        state = .stopping
    }
}
