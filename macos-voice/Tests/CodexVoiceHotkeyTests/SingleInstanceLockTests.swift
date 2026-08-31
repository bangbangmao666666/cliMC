import XCTest
@testable import CodexVoiceHotkey

final class SingleInstanceLockTests: XCTestCase {
    func testSecondLockAcquisitionFailsWhileFirstIsHeld() throws {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("lock")

        let firstLock = try SingleInstanceLock.acquire(at: lockURL)
        XCTAssertNotNil(firstLock)
        XCTAssertNil(try SingleInstanceLock.acquire(at: lockURL))
    }
}
