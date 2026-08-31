import XCTest
@testable import CodexVoiceHotkey

final class AudioLevelThrottleTests: XCTestCase {
    func testThrottlePublishesImmediatelyThenAtThirtyHertz() {
        var throttle = AudioLevelThrottle(maxUpdatesPerSecond: 30)

        XCTAssertTrue(throttle.shouldPublish(atNanoseconds: 1_000_000_000))
        XCTAssertFalse(throttle.shouldPublish(atNanoseconds: 1_020_000_000))
        XCTAssertTrue(throttle.shouldPublish(atNanoseconds: 1_034_000_000))
    }

    func testThrottleResetAllowsImmediatePublication() {
        var throttle = AudioLevelThrottle(maxUpdatesPerSecond: 30)
        _ = throttle.shouldPublish(atNanoseconds: 1_000_000_000)

        throttle.reset()

        XCTAssertTrue(throttle.shouldPublish(atNanoseconds: 1_001_000_000))
    }
}
