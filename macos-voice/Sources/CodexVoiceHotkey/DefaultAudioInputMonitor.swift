import CoreAudio
import Foundation

protocol DefaultAudioInputMonitoring: AnyObject {
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
}

protocol DefaultAudioInputBackend: AnyObject {
    func addListener(
        address: AudioObjectPropertyAddress,
        callback: @escaping () -> Void
    ) -> OSStatus
    func removeListener(address: AudioObjectPropertyAddress) -> OSStatus
}

final class SystemDefaultAudioInputBackend: DefaultAudioInputBackend {
    typealias AddPropertyListener = (
        inout AudioObjectPropertyAddress,
        DispatchQueue,
        @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus

    private let queue = DispatchQueue(label: "local.climc.default-audio-input")
    private let addPropertyListener: AddPropertyListener
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    init(
        addPropertyListener: @escaping AddPropertyListener = { address, queue, block in
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                block
            )
        }
    ) {
        self.addPropertyListener = addPropertyListener
    }

    func addListener(
        address: AudioObjectPropertyAddress,
        callback: @escaping () -> Void
    ) -> OSStatus {
        guard listenerBlock == nil else { return noErr }
        let block: AudioObjectPropertyListenerBlock = { _, _ in callback() }
        var mutableAddress = address
        let status = addPropertyListener(&mutableAddress, queue, block)
        if status == noErr {
            listenerBlock = block
        }
        return status
    }

    func removeListener(address: AudioObjectPropertyAddress) -> OSStatus {
        guard let listenerBlock else { return noErr }
        var mutableAddress = address
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &mutableAddress,
            queue,
            listenerBlock
        )
        if status == noErr {
            self.listenerBlock = nil
        }
        return status
    }
}

final class CoreAudioDefaultInputMonitor: DefaultAudioInputMonitoring {
    var onChange: (() -> Void)?

    private let backend: any DefaultAudioInputBackend
    private var isStarted = false
    private let address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(backend: any DefaultAudioInputBackend = SystemDefaultAudioInputBackend()) {
        self.backend = backend
    }

    deinit {
        stop()
    }

    func start() {
        guard !isStarted else { return }
        let status = backend.addListener(address: address) { [weak self] in
            self?.onChange?()
        }
        guard status == noErr else {
            log("无法监听默认麦克风变化：OSStatus \(status)")
            return
        }
        isStarted = true
    }

    func stop() {
        guard isStarted else { return }
        let status = backend.removeListener(address: address)
        if status != noErr {
            log("无法停止默认麦克风监听：OSStatus \(status)")
            return
        }
        isStarted = false
    }
}
