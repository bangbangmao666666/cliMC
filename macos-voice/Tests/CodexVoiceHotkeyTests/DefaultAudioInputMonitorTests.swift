import CoreAudio
import XCTest
@testable import CodexVoiceHotkey

final class DefaultAudioInputMonitorTests: XCTestCase {
    func testStartRegistersDefaultInputPropertyAndStopRemovesIt() {
        let backend = FakeDefaultAudioInputBackend()
        let monitor = CoreAudioDefaultInputMonitor(backend: backend)
        var changeCount = 0
        monitor.onChange = { changeCount += 1 }

        monitor.start()
        backend.emitChange()
        monitor.stop()
        backend.emitChange()

        XCTAssertEqual(backend.addedSelectors, [kAudioHardwarePropertyDefaultInputDevice])
        XCTAssertEqual(backend.removedSelectors, [kAudioHardwarePropertyDefaultInputDevice])
        XCTAssertEqual(changeCount, 1)
    }

    func testSystemBackendRetriesRegistrationAfterFailure() {
        var addCount = 0
        let backend = SystemDefaultAudioInputBackend(
            addPropertyListener: { _, _, _ in
                addCount += 1
                return addCount == 1 ? OSStatus(-1) : noErr
            }
        )
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        XCTAssertNotEqual(backend.addListener(address: address) {}, noErr)
        XCTAssertEqual(backend.addListener(address: address) {}, noErr)
        XCTAssertEqual(addCount, 2)
    }

    func testMonitorRemainsStartedWhenListenerRemovalFails() {
        let backend = FakeDefaultAudioInputBackend()
        backend.removeStatus = OSStatus(-1)
        let monitor = CoreAudioDefaultInputMonitor(backend: backend)

        monitor.start()
        monitor.stop()
        monitor.start()

        XCTAssertEqual(backend.addedSelectors.count, 1)
        XCTAssertEqual(backend.removedSelectors.count, 1)
    }
}

private final class FakeDefaultAudioInputBackend: DefaultAudioInputBackend {
    private var listener: (() -> Void)?
    private(set) var addedSelectors: [AudioObjectPropertySelector] = []
    private(set) var removedSelectors: [AudioObjectPropertySelector] = []
    var removeStatus: OSStatus = noErr

    func addListener(
        address: AudioObjectPropertyAddress,
        callback: @escaping () -> Void
    ) -> OSStatus {
        addedSelectors.append(address.mSelector)
        listener = callback
        return noErr
    }

    func removeListener(address: AudioObjectPropertyAddress) -> OSStatus {
        removedSelectors.append(address.mSelector)
        if removeStatus == noErr {
            listener = nil
        }
        return removeStatus
    }

    func emitChange() {
        listener?()
    }
}
