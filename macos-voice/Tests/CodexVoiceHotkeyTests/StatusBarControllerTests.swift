import XCTest
@testable import CodexVoiceHotkey

final class StatusBarControllerTests: XCTestCase {
    func testUsageStatsMenuItemInvokesCallback() {
        let controller = StatusBarController()
        var callCount = 0
        controller.onOpenUsageStats = { callCount += 1 }

        controller.openUsageStatsForTesting()

        XCTAssertEqual(callCount, 1)
    }

    func testUsageStatsMenuItemDoesNotCrashWithoutCallback() {
        let controller = StatusBarController()

        controller.openUsageStatsForTesting()

        // No crash is the assertion
    }
}
