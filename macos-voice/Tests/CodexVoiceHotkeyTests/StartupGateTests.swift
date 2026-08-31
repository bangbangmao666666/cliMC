import XCTest
@testable import CodexVoiceHotkey

final class StartupGateTests: XCTestCase {
    func testSecondLaunchActivatesExistingInstance() {
        var activatedBundleIdentifiers: [String] = []
        var requestedShowSettings = false
        let lockProvider: (URL) throws -> SingleInstanceLock? = { _ in nil }
        let activator: (String) -> Void = { activatedBundleIdentifiers.append($0) }

        let lock = StartupGate.acquire(
            bundleIdentifier: "local.climc.app",
            lockURL: URL(fileURLWithPath: "/private/tmp/test.lock"),
            lockProvider: lockProvider,
            activator: activator,
            requestShowSettings: {
                requestedShowSettings = true
            }
        )

        XCTAssertNil(lock)
        XCTAssertEqual(activatedBundleIdentifiers, ["local.climc.app"])
        XCTAssertTrue(requestedShowSettings)
    }

    func testSelectionIgnoresCurrentProcess() {
        let selected = StartupGate.selectActivationTarget(
            from: [
                .init(processIdentifier: 111),
                .init(processIdentifier: 222),
            ],
            excluding: 111
        )

        XCTAssertEqual(selected?.processIdentifier, 222)
    }
}
