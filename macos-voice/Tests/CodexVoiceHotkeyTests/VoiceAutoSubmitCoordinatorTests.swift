import XCTest
@testable import CodexVoiceHotkey

final class VoiceAutoSubmitCoordinatorTests: XCTestCase {
    func testDisabledCoordinatorDoesNotSchedule() {
        let scheduler = ManualAutoSubmitScheduler()
        let coordinator = VoiceAutoSubmitCoordinator(
            enabled: false,
            delaySeconds: 5,
            scheduler: scheduler,
            submit: {}
        )

        coordinator.scheduleAfterCommit(text: "解释代码")

        XCTAssertTrue(scheduler.tasks.isEmpty)
    }

    func testCountdownSubmitsThenDismissesCelebration() {
        let scheduler = ManualAutoSubmitScheduler()
        var countdown: [Int] = []
        var submitCount = 0
        var submittedCount = 0
        var dismissCount = 0
        let coordinator = VoiceAutoSubmitCoordinator(
            enabled: true,
            delaySeconds: 3,
            scheduler: scheduler,
            submit: { submitCount += 1 },
            onCountdown: { countdown.append($0) },
            onSubmitted: { submittedCount += 1 },
            onDismiss: { dismissCount += 1 }
        )

        coordinator.scheduleAfterCommit(text: "解释代码")

        XCTAssertEqual(countdown, [3])
        XCTAssertEqual(scheduler.delays, [1])
        scheduler.tasks[0].fire()
        XCTAssertEqual(countdown, [3, 2])
        XCTAssertEqual(scheduler.delays, [1, 1])
        scheduler.tasks[1].fire()
        XCTAssertEqual(countdown, [3, 2, 1])
        XCTAssertEqual(scheduler.delays, [1, 1, 1])
        scheduler.tasks[2].fire()
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(submittedCount, 1)
        XCTAssertEqual(dismissCount, 0)
        XCTAssertEqual(scheduler.delays, [1, 1, 1, 1.6])
        scheduler.tasks[3].fire()
        XCTAssertEqual(dismissCount, 1)
    }

    func testCancellationDismissesCountdownAndMakesStaleCallbackANoOp() {
        let scheduler = ManualAutoSubmitScheduler()
        var submitCount = 0
        var countdown: [Int] = []
        var submittedCount = 0
        var dismissCount = 0
        let coordinator = VoiceAutoSubmitCoordinator(
            enabled: true,
            delaySeconds: 5,
            scheduler: scheduler,
            submit: { submitCount += 1 },
            onCountdown: { countdown.append($0) },
            onSubmitted: { submittedCount += 1 },
            onDismiss: { dismissCount += 1 }
        )
        coordinator.scheduleAfterCommit(text: "第一段")

        coordinator.cancelPending()
        scheduler.tasks[0].fireIgnoringCancellation()

        XCTAssertEqual(countdown, [5])
        XCTAssertEqual(submitCount, 0)
        XCTAssertEqual(submittedCount, 0)
        XCTAssertEqual(dismissCount, 1)
    }

    func testNewCommitInvalidatesOlderTimer() {
        let scheduler = ManualAutoSubmitScheduler()
        var submitCount = 0
        var countdown: [Int] = []
        var dismissCount = 0
        let coordinator = VoiceAutoSubmitCoordinator(
            enabled: true,
            delaySeconds: 1,
            scheduler: scheduler,
            submit: { submitCount += 1 },
            onCountdown: { countdown.append($0) },
            onDismiss: { dismissCount += 1 }
        )
        coordinator.scheduleAfterCommit(text: "第一段")
        coordinator.scheduleAfterCommit(text: "第二段")

        scheduler.tasks[0].fireIgnoringCancellation()
        scheduler.tasks[1].fire()

        XCTAssertEqual(countdown, [1, 1])
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(dismissCount, 1)
    }

    func testAutoSubmittedCallbackFiresOnlyWhenSubmitExecutes() {
        let scheduler = ManualAutoSubmitScheduler()
        var submitCount = 0
        var autoSubmittedCount = 0
        let coordinator = VoiceAutoSubmitCoordinator(
            enabled: true,
            delaySeconds: 1,
            scheduler: scheduler,
            submit: { submitCount += 1 },
            onAutoSubmitted: { autoSubmittedCount += 1 }
        )

        coordinator.scheduleAfterCommit(text: "hello")
        scheduler.tasks[0].fire()

        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(autoSubmittedCount, 1)
    }

    func testAutoSubmittedDoesNotFireOnCancelledCountdown() {
        let scheduler = ManualAutoSubmitScheduler()
        var submitCount = 0
        var autoSubmittedCount = 0
        let coordinator = VoiceAutoSubmitCoordinator(
            enabled: true,
            delaySeconds: 1,
            scheduler: scheduler,
            submit: { submitCount += 1 },
            onAutoSubmitted: { autoSubmittedCount += 1 }
        )

        coordinator.scheduleAfterCommit(text: "取消掉")
        coordinator.cancelPending()
        scheduler.tasks[0].fireIgnoringCancellation()

        XCTAssertEqual(submitCount, 0)
        XCTAssertEqual(autoSubmittedCount, 0)
    }

    func testEmptyCommitAndSettingsReplacementCancelPendingTimer() {
        let scheduler = ManualAutoSubmitScheduler()
        var submitCount = 0
        var dismissCount = 0
        let coordinator = VoiceAutoSubmitCoordinator(
            enabled: true,
            delaySeconds: 5,
            scheduler: scheduler,
            submit: { submitCount += 1 },
            onDismiss: { dismissCount += 1 }
        )
        coordinator.scheduleAfterCommit(text: "待提交")

        coordinator.update(enabled: false, delaySeconds: 10)
        coordinator.scheduleAfterCommit(text: "   ")
        scheduler.tasks[0].fireIgnoringCancellation()

        XCTAssertEqual(submitCount, 0)
        XCTAssertEqual(dismissCount, 1)
    }
}

private final class ManualAutoSubmitTask: AutoSubmitCancellable {
    private let action: () -> Void
    private(set) var isCancelled = false
    private var didFire = false

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func cancel() {
        isCancelled = true
    }

    func fire() {
        guard !isCancelled, !didFire else { return }
        didFire = true
        action()
    }

    func fireIgnoringCancellation() {
        guard !didFire else { return }
        didFire = true
        action()
    }
}

private final class ManualAutoSubmitScheduler: AutoSubmitScheduling {
    private(set) var delays: [TimeInterval] = []
    private(set) var tasks: [ManualAutoSubmitTask] = []

    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> AutoSubmitCancellable {
        delays.append(delay)
        let task = ManualAutoSubmitTask(action: action)
        tasks.append(task)
        return task
    }
}
