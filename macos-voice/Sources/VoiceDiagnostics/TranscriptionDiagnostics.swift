import Foundation

public struct TranscriptionDiagnosticMetrics: Equatable, Sendable {
    public let durationMilliseconds: Int
    public let frameCount: Int
    public let byteCount: Int

    public init(
        durationMilliseconds: Int = 0,
        frameCount: Int = 0,
        byteCount: Int = 0
    ) {
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.frameCount = max(0, frameCount)
        self.byteCount = max(0, byteCount)
    }

    var attributes: [String: DiagnosticAttributeValue] {
        [
            "duration_ms": .integer(durationMilliseconds),
            "frame_count": .integer(frameCount),
            "byte_count": .integer(byteCount),
        ]
    }
}

public enum TranscriberDiagnosticMilestone: Equatable, Sendable {
    case requestStarted
    case responseFirstSeen
    case retryStarted(attempt: Int, replayBytes: Int)
    case audioProgress(frameCount: Int, byteCount: Int)
}

public protocol DiagnosticScheduled: AnyObject {
    func cancel()
}

public protocol DiagnosticScheduling: AnyObject {
    func schedule(
        after interval: TimeInterval,
        _ action: @escaping () -> Void
    ) -> DiagnosticScheduled
}

public final class DispatchDiagnosticScheduler: DiagnosticScheduling {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .global(qos: .utility)) {
        self.queue = queue
    }

    public func schedule(
        after interval: TimeInterval,
        _ action: @escaping () -> Void
    ) -> DiagnosticScheduled {
        let item = DispatchWorkItem(block: action)
        queue.asyncAfter(deadline: .now() + max(0, interval), execute: item)
        return DispatchScheduledDiagnostic(item: item)
    }
}

private final class DispatchScheduledDiagnostic: DiagnosticScheduled {
    private let item: DispatchWorkItem
    init(item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}

public final class TranscriptionDiagnostics: @unchecked Sendable {
    public let sessionID: UUID

    private let providerName: DiagnosticProvider
    private let sink: DiagnosticEventSink
    private let clock: () -> Date
    private let scheduler: DiagnosticScheduling
    private let startedAt: Date
    private let lock = NSLock()
    private var didCaptureFirstFrame = false
    private var didStartWait = false
    private var terminalEvent: DiagnosticEventName?
    private var slowTask: DiagnosticScheduled?
    private var criticalSlowTask: DiagnosticScheduled?

    public init(
        provider: DiagnosticProvider,
        sink: DiagnosticEventSink,
        sessionID: UUID = UUID(),
        clock: @escaping () -> Date = Date.init,
        scheduler: DiagnosticScheduling = DispatchDiagnosticScheduler()
    ) {
        self.providerName = provider
        self.sink = sink
        self.sessionID = sessionID
        self.clock = clock
        self.scheduler = scheduler
        startedAt = clock()
        emit(.sessionStarted)
    }

    public func captureFirstFrame(metrics: TranscriptionDiagnosticMetrics) {
        lock.lock()
        guard !didCaptureFirstFrame, terminalEvent == nil else {
            lock.unlock()
            return
        }
        didCaptureFirstFrame = true
        lock.unlock()
        emit(.captureFirstFrame, attributes: metrics.attributes)
    }

    public func recordingStopped(metrics: TranscriptionDiagnosticMetrics) {
        guard isOpen else { return }
        emit(.recordingStopped, attributes: metrics.attributes)
        if providerName == .system {
            startWaitTimersIfNeeded()
        }
    }

    public func provider(_ milestone: TranscriberDiagnosticMilestone) {
        guard isOpen else { return }
        switch milestone {
        case .requestStarted:
            emit(.requestStarted)
            startWaitTimersIfNeeded()
        case .responseFirstSeen:
            emit(.responseFirstSeen)
        case .retryStarted(let attempt, let replayBytes):
            emit(.retryStarted, attributes: [
                "attempt": .integer(max(0, attempt)),
                "replay_bytes": .integer(max(0, replayBytes)),
            ])
        case .audioProgress:
            break
        }
    }

    public func partialResult(_ text: String) {
        guard isOpen else { return }
        emit(.partialResult, attributes: transcriptAttributes(text))
    }

    public func finalResult(_ text: String) {
        finish(.finalResult, attributes: transcriptAttributes(text))
    }

    public func textInjected() {
        lock.lock()
        let accepted = terminalEvent == .finalResult
        lock.unlock()
        if accepted { emit(.textInjected) }
    }

    public func noAudio() {
        finish(.noAudio)
    }

    public func fail(
        category: String,
        providerCode: String?,
        message: String,
        retainedAudio: String?
    ) {
        var attributes: [String: DiagnosticAttributeValue] = [
            "error_category": .string(category),
            "error_message": .string(String(message.prefix(300))),
        ]
        if let providerCode, !providerCode.isEmpty {
            attributes["provider_code"] = .string(providerCode)
        }
        if let retainedAudio, !retainedAudio.isEmpty {
            attributes["retained_audio"] = .string(retainedAudio)
        }
        finish(.failed, attributes: attributes)
    }

    public func cancel() {
        finish(.cancelled)
    }

    private var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminalEvent == nil
    }

    private func startWaitTimersIfNeeded() {
        lock.lock()
        guard !didStartWait, terminalEvent == nil else {
            lock.unlock()
            return
        }
        didStartWait = true
        slowTask = scheduler.schedule(after: 10) { [weak self] in
            self?.emitMarkerIfOpen(.slow)
        }
        criticalSlowTask = scheduler.schedule(after: 15) { [weak self] in
            self?.emitMarkerIfOpen(.criticalSlow)
        }
        lock.unlock()
    }

    private func emitMarkerIfOpen(_ name: DiagnosticEventName) {
        guard isOpen else { return }
        emit(name)
    }

    private func finish(
        _ name: DiagnosticEventName,
        attributes: [String: DiagnosticAttributeValue] = [:]
    ) {
        lock.lock()
        guard terminalEvent == nil else {
            lock.unlock()
            return
        }
        terminalEvent = name
        let slowTask = slowTask
        let criticalSlowTask = criticalSlowTask
        self.slowTask = nil
        self.criticalSlowTask = nil
        lock.unlock()

        slowTask?.cancel()
        criticalSlowTask?.cancel()
        emit(name, attributes: attributes)
    }

    private func transcriptAttributes(_ text: String) -> [String: DiagnosticAttributeValue] {
        let metadata = TranscriptMetadata.make(text: text)
        var attributes: [String: DiagnosticAttributeValue] = [
            "character_count": .integer(metadata.characterCount),
            "text_digest": .string(metadata.digest),
        ]
        if let preview = metadata.preview {
            attributes["preview"] = .string(preview)
        }
        return attributes
    }

    private func emit(
        _ name: DiagnosticEventName,
        attributes: [String: DiagnosticAttributeValue] = [:]
    ) {
        let date = clock()
        sink.write(DiagnosticEvent(
            timestamp: date,
            sessionID: sessionID,
            event: name,
            provider: providerName,
            elapsedMilliseconds: Int(max(0, date.timeIntervalSince(startedAt) * 1_000)),
            attributes: attributes
        ))
    }
}
