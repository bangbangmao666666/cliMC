import AVFoundation
import Foundation

struct AudioCaptureHealth: Equatable {
    var lastFrameNanoseconds: UInt64?
    var pcmDeliveryCount: UInt64 = 0
    var consumerDeliveryCount: UInt64 = 0
    var isRunning = false
    var recoveryGeneration: UInt64 = 0
}

protocol AudioCapturing: AnyObject {
    var onStateChange: ((AudioCaptureState, AudioCaptureMetrics) -> Void)? { get set }
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    var onPCM16: ((Data) -> Void)? { get set }
    var onSpectrum: (([Double]) -> Void)? { get set }
    var health: AudioCaptureHealth { get }
    func start() throws
    func stop()
    func recover(reason: String)
}

protocol AudioCaptureEngine: AnyObject {
    var inputFormat: AVAudioFormat { get }
    var configurationChangeObject: AnyObject { get }
    func installTap(format: AVAudioFormat, _ handler: @escaping (AVAudioPCMBuffer) -> Void)
    func removeTap()
    func prepare()
    func start() throws
    func stop()
}

final class AudioCaptureSession: AudioCapturing {
    var onStateChange: ((AudioCaptureState, AudioCaptureMetrics) -> Void)? {
        get { synchronously { stateChangeHandler } }
        set { synchronously { stateChangeHandler = newValue } }
    }

    var onBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { synchronously { bufferHandler } }
        set { synchronously { bufferHandler = newValue } }
    }

    var onPCM16: ((Data) -> Void)? {
        get { synchronously { pcm16Handler } }
        set { synchronously { pcm16Handler = newValue } }
    }

    var onSpectrum: (([Double]) -> Void)? {
        get { synchronously { spectrumHandler } }
        set { synchronously { spectrumHandler = newValue } }
    }

    private let engine: any AudioCaptureEngine
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let notificationCenter: NotificationCenter
    private let inputMonitor: any DefaultAudioInputMonitoring
    private let retryDelay: TimeInterval
    private let nowNanoseconds: () -> UInt64
    private var configurationChangeObserver: NSObjectProtocol?
    private var tapInstalled = false
    private var converter: AVAudioConverter?
    private var lifecycle = AudioCaptureLifecycle()
    private var retryWorkItem: DispatchWorkItem?
    private var isRunning = false
    private var stateChangeHandler: ((AudioCaptureState, AudioCaptureMetrics) -> Void)?
    private var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var pcm16Handler: ((Data) -> Void)?
    private var spectrumHandler: (([Double]) -> Void)?
    private let spectrumAnalyzer = AudioSpectrumAnalyzer()
    private var spectrumThrottle = AudioLevelThrottle(maxUpdatesPerSecond: 30)
    private var engineStartRequestedAt: DispatchTime?
    private var didLogFirstFrame = false
    private var lastFrameNanoseconds: UInt64?
    private var pcmDeliveryCount: UInt64 = 0
    private var consumerDeliveryCount: UInt64 = 0
    private var recoveryGeneration: UInt64 = 0
    private var tapInstallationGeneration: UInt64 = 0

    init(
        engine: any AudioCaptureEngine = AVAudioEngineCaptureEngine(),
        notificationCenter: NotificationCenter = .default,
        inputMonitor: any DefaultAudioInputMonitoring = CoreAudioDefaultInputMonitor(),
        retryDelay: TimeInterval = 0.5,
        nowNanoseconds: @escaping () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        queue: DispatchQueue = DispatchQueue(label: "local.climc.audio-capture")
    ) {
        self.engine = engine
        self.notificationCenter = notificationCenter
        self.inputMonitor = inputMonitor
        self.retryDelay = retryDelay
        self.nowNanoseconds = nowNanoseconds
        self.queue = queue
        queue.setSpecific(key: queueKey, value: ())
        inputMonitor.onChange = { [weak self] in
            self?.recover(reason: "默认输入设备变化")
        }
        configurationChangeObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine.configurationChangeObject,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                self?.handleConfigurationChange()
            }
        }
    }

    deinit {
        if let configurationChangeObserver {
            notificationCenter.removeObserver(configurationChangeObserver)
        }
        synchronously { stopCapture(notifyStateChange: false) }
    }

    var health: AudioCaptureHealth {
        synchronously {
            AudioCaptureHealth(
                lastFrameNanoseconds: lastFrameNanoseconds,
                pcmDeliveryCount: pcmDeliveryCount,
                consumerDeliveryCount: consumerDeliveryCount,
                isRunning: isRunning,
                recoveryGeneration: recoveryGeneration
            )
        }
    }

    func start() throws {
        synchronously {
            guard !isRunning else { return }
            isRunning = true
            inputMonitor.start()
            engineStartRequestedAt = .now()
            didLogFirstFrame = false
            spectrumAnalyzer.reset()
            spectrumThrottle.reset()
            lifecycle.start()
            publishStateChange()
            installTapAndStartEngine()
        }
    }

    func stop() {
        synchronously { stopCapture(notifyStateChange: true) }
    }

    func recover(reason: String) {
        synchronously {
            requestRecovery(reason: reason)
        }
    }

    private func handleConfigurationChange() {
        requestRecovery(reason: "AVAudioEngine 配置变化")
    }

    private func requestRecovery(reason: String) {
        guard isRunning else { return }
        guard retryWorkItem == nil else {
            log("音频采集恢复已在进行，合并触发：\(reason)。")
            return
        }

        recoveryGeneration &+= 1
        lastFrameNanoseconds = nil
        engineStartRequestedAt = .now()
        didLogFirstFrame = false
        lifecycle.waitForAudio()
        publishStateChange()
        log("音频采集开始恢复：\(reason)，代次 \(recoveryGeneration)。")
        removeTap()
        engine.stop()
        scheduleRetry()
    }

    private func installTapAndStartEngine() {
        guard isRunning, !tapInstalled else { return }

        let inputFormat = engine.inputFormat
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            log("音频采集等待可用的输入路由。")
            scheduleRetry()
            return
        }
        guard let pcm16Format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            log("音频采集无法创建 16kHz PCM 输出格式。")
            scheduleRetry()
            return
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: pcm16Format) else {
            log("音频采集无法创建 PCM 格式转换器。")
            scheduleRetry()
            return
        }

        self.converter = converter
        tapInstallationGeneration &+= 1
        let tapGeneration = tapInstallationGeneration
        engine.installTap(format: inputFormat) { [weak self] buffer in
            guard let self else { return }
            let ingressNanoseconds = self.nowNanoseconds()
            guard let ownedBuffer = Self.copy(buffer) else {
                log("音频采集无法复制输入 buffer。")
                return
            }
            self.queue.async { [weak self] in
                self?.process(
                    ownedBuffer,
                    tapGeneration: tapGeneration,
                    ingressNanoseconds: ingressNanoseconds
                )
            }
        }
        tapInstalled = true
        engine.prepare()

        do {
            try engine.start()
        } catch {
            log("音频采集启动失败，将等待路由稳定后重试：\(error.localizedDescription)")
            removeTap()
            engine.stop()
            scheduleRetry()
        }
    }

    private func process(
        _ buffer: AVAudioPCMBuffer,
        tapGeneration: UInt64,
        ingressNanoseconds: UInt64
    ) {
        guard isRunning,
              tapGeneration == tapInstallationGeneration,
              buffer.frameLength > 0
        else { return }
        lastFrameNanoseconds = ingressNanoseconds

        if !didLogFirstFrame, let engineStartRequestedAt {
            didLogFirstFrame = true
            let elapsed = DispatchTime.now().uptimeNanoseconds - engineStartRequestedAt.uptimeNanoseconds
            log("AirPods 采集首帧延迟 \(String(format: "%.1f", Double(elapsed) / 1_000_000)) ms。")
        }

        let shouldPublishCapturing = lifecycle.state != .capturing
        lifecycle.receive(frameByteCount: byteCount(in: buffer))
        spectrumAnalyzer.append(buffer)
        if let spectrumHandler,
           spectrumThrottle.shouldPublish(atNanoseconds: nowNanoseconds()) {
            spectrumHandler(spectrumAnalyzer.levels())
        }
        if shouldPublishCapturing {
            publishStateChange()
        }

        let deliveredRawBuffer = bufferHandler != nil
        if let bufferHandler {
            consumerDeliveryCount &+= 1
            bufferHandler(buffer)
        }
        guard isRunning,
              let pcm16Handler,
              let convertedBuffer = convert(buffer),
              let pcm16Data = pcm16Data(from: convertedBuffer),
              !pcm16Data.isEmpty
        else { return }
        pcmDeliveryCount &+= 1
        if !deliveredRawBuffer {
            consumerDeliveryCount &+= 1
        }
        pcm16Handler(pcm16Data)
    }

    private func stopCapture(notifyStateChange: Bool) {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        inputMonitor.stop()
        guard isRunning else { return }

        isRunning = false
        removeTap()
        engine.stop()
        converter = nil
        spectrumAnalyzer.reset()
        spectrumThrottle.reset()
        lifecycle.stop()
        if notifyStateChange {
            publishStateChange()
        }
    }

    private func removeTap() {
        guard tapInstalled else { return }
        tapInstallationGeneration &+= 1
        engine.removeTap()
        tapInstalled = false
        converter = nil
    }

    private func scheduleRetry() {
        guard isRunning, retryWorkItem == nil else { return }

        let retry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItem = nil
            self.installTapAndStartEngine()
        }
        retryWorkItem = retry
        queue.asyncAfter(deadline: .now() + retryDelay, execute: retry)
    }

    private func publishStateChange() {
        stateChangeHandler?(lifecycle.state, lifecycle.metrics)
    }

    private func byteCount(in buffer: AVAudioPCMBuffer) -> Int {
        Int(buffer.frameLength) * Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }

        let ratio = converter.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var suppliedInput = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return buffer
        }
        return conversionError == nil ? output : nil
    }

    private func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channel = buffer.int16ChannelData?.pointee else { return nil }

        var data = Data(capacity: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
        for index in 0..<Int(buffer.frameLength) {
            var sample = channel[index].littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            let source = sourceBuffers[index]
            guard let sourceData = source.mData,
                  let destinationData = destinationBuffers[index].mData,
                  source.mDataByteSize <= destinationBuffers[index].mDataByteSize
            else { return nil }
            destinationData.copyMemory(from: sourceData, byteCount: Int(source.mDataByteSize))
            destinationBuffers[index].mDataByteSize = source.mDataByteSize
        }
        return copy
    }

    private func synchronously<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try work()
        }
        return try queue.sync(execute: work)
    }
}

private final class AVAudioEngineCaptureEngine: AudioCaptureEngine {
    private let engine = AVAudioEngine()

    var inputFormat: AVAudioFormat {
        engine.inputNode.inputFormat(forBus: 0)
    }

    var configurationChangeObject: AnyObject { engine }

    func installTap(format: AVAudioFormat, _ handler: @escaping (AVAudioPCMBuffer) -> Void) {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            handler(buffer)
        }
    }

    func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    func prepare() {
        engine.prepare()
    }

    func start() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
    }
}
