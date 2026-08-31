import Foundation

protocol AutoSubmitCancellable: AnyObject {
    func cancel()
}

protocol AutoSubmitScheduling {
    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> AutoSubmitCancellable
}

private final class DispatchAutoSubmitTask: AutoSubmitCancellable {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

struct DispatchAutoSubmitScheduler: AutoSubmitScheduling {
    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> AutoSubmitCancellable {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return DispatchAutoSubmitTask(workItem: item)
    }
}

final class VoiceAutoSubmitCoordinator {
    private var enabled: Bool
    private var delaySeconds: Int
    private let scheduler: any AutoSubmitScheduling
    private let submit: () -> Void
    private let onAutoSubmitted: () -> Void
    private let onCountdown: (Int) -> Void
    private let onSubmitted: () -> Void
    private let onDismiss: () -> Void
    private var pending: (any AutoSubmitCancellable)?
    private var generation = 0
    private var feedbackVisible = false

    init(
        enabled: Bool,
        delaySeconds: Int,
        scheduler: any AutoSubmitScheduling = DispatchAutoSubmitScheduler(),
        submit: @escaping () -> Void,
        onAutoSubmitted: @escaping () -> Void = {},
        onCountdown: @escaping (Int) -> Void = { _ in },
        onSubmitted: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void = {}
    ) {
        self.enabled = enabled
        self.delaySeconds = VoicePreferences.normalizedAutoSubmitDelay(delaySeconds)
        self.scheduler = scheduler
        self.submit = submit
        self.onAutoSubmitted = onAutoSubmitted
        self.onCountdown = onCountdown
        self.onSubmitted = onSubmitted
        self.onDismiss = onDismiss
    }

    func update(enabled: Bool, delaySeconds: Int) {
        cancelPending()
        self.enabled = enabled
        self.delaySeconds = VoicePreferences.normalizedAutoSubmitDelay(delaySeconds)
    }

    func scheduleAfterCommit(text: String) {
        cancelPending()
        guard enabled,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        feedbackVisible = true
        let scheduledGeneration = generation
        onCountdown(delaySeconds)
        scheduleTick(remainingSeconds: delaySeconds, generation: scheduledGeneration)
    }

    func cancelPending() {
        generation += 1
        pending?.cancel()
        pending = nil
        guard feedbackVisible else { return }
        feedbackVisible = false
        onDismiss()
    }

    private func scheduleTick(remainingSeconds: Int, generation: Int) {
        pending = scheduler.schedule(after: 1) { [weak self] in
            guard let self,
                  self.generation == generation,
                  self.feedbackVisible
            else { return }
            self.pending = nil

            if remainingSeconds > 1 {
                let nextRemaining = remainingSeconds - 1
                self.onCountdown(nextRemaining)
                self.scheduleTick(
                    remainingSeconds: nextRemaining,
                    generation: generation
                )
                return
            }

            self.submit()
            self.onAutoSubmitted()
            self.onSubmitted()
            self.scheduleDismiss(generation: generation)
        }
    }

    private func scheduleDismiss(generation: Int) {
        pending = scheduler.schedule(after: 1.6) { [weak self] in
            guard let self,
                  self.generation == generation,
                  self.feedbackVisible
            else { return }
            self.pending = nil
            self.feedbackVisible = false
            self.onDismiss()
        }
    }
}
