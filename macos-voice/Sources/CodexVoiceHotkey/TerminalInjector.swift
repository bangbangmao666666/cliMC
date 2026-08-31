import AppKit
import Carbon.HIToolbox

// MARK: - PID-targeted event helpers

/// Returns the process identifier of the frontmost application.
private func frontmostPid() -> pid_t? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
        log("无法获取前端应用的进程 ID。")
        return nil
    }
    return frontApp.processIdentifier as pid_t?
}

/// Post a single key event (keyDown + keyUp) to a specific process.
@discardableResult
private func postKeyToPid(_ keyCode: CGKeyCode, pid: pid_t, flags: CGEventFlags = []) -> Bool {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
    else {
        return false
    }
    down.flags = flags
    up.flags = flags
    down.setIntegerValueField(.eventSourceUserData, value: VoiceSyntheticEvent.marker)
    up.setIntegerValueField(.eventSourceUserData, value: VoiceSyntheticEvent.marker)
    down.postToPid(pid)
    up.postToPid(pid)
    return true
}

/// Post a Return key event directly to the frontmost application process.
/// Apple Terminal's alternate-screen PTY can misinterpret CGEvent-sourced
/// Enter (via `.cghidEventTap`) as a newline instead of a submit event.
/// Targeting the specific process PID avoids that filtering layer.
private func postReturnToFrontmostApp() -> Bool {
    guard let pid = frontmostPid() else { return false }
    return postKeyToPid(CGKeyCode(kVK_Return), pid: pid)
}

struct ReplacementOperation: Equatable {
    let backspaces: Int
    let textToInsert: String
}

enum TerminalInjectionOperation: Equatable {
    case replacement(ReplacementOperation)
    case submit
}

struct TerminalInjectionQueue {
    private var operations: [TerminalInjectionOperation] = []

    mutating func enqueueReplacement(_ operation: ReplacementOperation) {
        operations.append(.replacement(operation))
    }

    mutating func enqueueSubmit() {
        operations.append(.submit)
    }

    mutating func takeNext() -> TerminalInjectionOperation? {
        guard !operations.isEmpty else { return nil }
        return operations.removeFirst()
    }

    mutating func clear() {
        operations.removeAll()
    }
}

final class TerminalInjector {
    private var pendingOperations = TerminalInjectionQueue()
    private var pendingCompletions: [() -> Void] = []
    private var isInjecting = false
    private var needsDeferredRestore = false

    // Session-level clipboard management: snapshot ONCE at session start,
    // restore ONCE at session end.  This avoids race conditions from saving
    // and restoring the clipboard after every individual paste operation.
    private var clipboardSnapshot: [[NSPasteboard.PasteboardType: Data]]? = nil

    // Paste-settle tracking.  Cmd+V is delivered to the target app
    // asynchronously via CGEvent, so the app reads the pasteboard some time
    // after we post it.  Restoring the original clipboard snapshot too soon
    // overwrites the transcription before the paste is consumed, and the app
    // ends up pasting the stale snapshot.  We therefore refuse to restore
    // until `pasteSettleInterval` has elapsed since the last paste.
    private var lastPasteAt: Date?
    private let pasteSettleInterval: TimeInterval = 0.3
    private var deferredRestoreWorkItem: DispatchWorkItem?

    func saveClipboardIfNeeded() {
        guard clipboardSnapshot == nil else { return }
        let board = NSPasteboard.general
        let snapshot: [[NSPasteboard.PasteboardType: Data]] = (board.pasteboardItems ?? []).compactMap { item in
            var typeData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typeData[type] = data
                }
            }
            return typeData.isEmpty ? nil : typeData
        }
        clipboardSnapshot = snapshot
        lastPasteAt = nil
        log("已保存剪贴板快照（\(snapshot.count) 项）")
    }

    func restoreClipboard() {
        guard let snapshot = clipboardSnapshot, !snapshot.isEmpty else {
            clipboardSnapshot = nil
            cancelDeferredRestore()
            return
        }

        // Defer clipboard restoration when an injection operation is in
        // flight so that the pending Cmd+V reads the intended text, not the
        // restored clipboard content.
        if isInjecting {
            needsDeferredRestore = true
            return
        }

        needsDeferredRestore = false

        // Also defer until the target application has had time to consume the
        // last Cmd+V paste.  Restoring the snapshot too soon overwrites the
        // pasteboard before the app reads it, so the app pastes the stale
        // snapshot instead of the transcription.
        if isWithinPasteSettleWindow() {
            scheduleDeferredRestore()
            return
        }

        cancelDeferredRestore()
        let board = NSPasteboard.general
        board.clearContents()
        for typeData in snapshot {
            let item = NSPasteboardItem()
            for (type, data) in typeData {
                item.setData(data, forType: type)
            }
            board.writeObjects([item])
        }
        clipboardSnapshot = nil
        lastPasteAt = nil
        log("已恢复剪贴板快照（\(snapshot.count) 项）")
    }

    private func isWithinPasteSettleWindow() -> Bool {
        guard let lastPasteAt else { return false }
        return Date().timeIntervalSince(lastPasteAt) < pasteSettleInterval
    }

    private func scheduleDeferredRestore() {
        let delay = nextRestoreDelay()
        let workItem = DispatchWorkItem { [weak self] in
            self?.restoreClipboard()
        }
        deferredRestoreWorkItem?.cancel()
        deferredRestoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func nextRestoreDelay() -> TimeInterval {
        guard let lastPasteAt else { return pasteSettleInterval }
        return max(0, pasteSettleInterval - Date().timeIntervalSince(lastPasteAt))
    }

    private func cancelDeferredRestore() {
        deferredRestoreWorkItem?.cancel()
        deferredRestoreWorkItem = nil
    }

    /// Test-only hook to simulate a recent paste without posting real key
    /// events.  Pass `nil` to clear the paste timestamp.
    func setLastPasteAtForTesting(_ date: Date?) {
        lastPasteAt = date
    }

    func replaceVoiceSpan(backspaces: Int, text: String) {
        replaceVoiceSpan(backspaces: backspaces, text: text, completion: {})
    }

    func replaceVoiceSpan(
        backspaces: Int,
        text: String,
        completion: @escaping () -> Void
    ) {
        guard backspaces > 0 || !text.isEmpty else {
            completion()
            return
        }
        pendingOperations.enqueueReplacement(
            ReplacementOperation(backspaces: backspaces, textToInsert: text)
        )
        pendingCompletions.append(completion)
        injectNextOperation()
    }

    func submit() {
        pendingOperations.enqueueSubmit()
        pendingCompletions.append({})
        injectNextOperation()
    }

    /// Post Delete key events to a specific process PID.
    private func postBackspaces(_ count: Int, pid: pid_t) {
        guard count > 0 else { return }
        for _ in 0..<count {
            postKeyToPid(CGKeyCode(kVK_Delete), pid: pid)
        }
    }

    private func injectNextOperation() {
        guard !isInjecting,
              let operation = pendingOperations.takeNext(),
              !pendingCompletions.isEmpty
        else { return }
        isInjecting = true
        let completion = pendingCompletions.removeFirst()

        switch operation {
        case .replacement(let replacement):
            guard let pid = frontmostPid() else {
                completion()
                finishOperation(after: .milliseconds(0), completion: {})
                return
            }
            log("注入开始：backspaces=\(replacement.backspaces) text=\"\(replacement.textToInsert)\" pid=\(pid)")
            postBackspaces(replacement.backspaces, pid: pid)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(18)) { [weak self] in
                guard let self else { return }
                self.paste(replacement.textToInsert, pid: pid)
                let now = Date()
                log("注入完成：text=\"\(replacement.textToInsert)\" at=\(now.timeIntervalSince1970)")
                self.finishOperation(after: .milliseconds(32), completion: completion)
            }
        case .submit:
            if !postReturnToFrontmostApp() {
                log("无法发送自动提交按键。")
            }
            finishOperation(after: .milliseconds(32), completion: completion)
        }
    }

    /// Clear any pending injection operations.  Safe to call from outside
    /// the injection pipeline (e.g. when a session is cancelled).
    func cancelPending() {
        pendingOperations.clear()
        pendingCompletions.removeAll()
    }

    private func finishOperation(
        after delay: DispatchTimeInterval,
        completion: @escaping () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            completion()
            self.isInjecting = false

            if self.needsDeferredRestore {
                self.needsDeferredRestore = false
                self.restoreClipboard()
                return
            }

            self.injectNextOperation()
        }
    }

    /// Paste text via Cmd+V.  Clipboard is set immediately before the paste;
    /// we do NOT save/restore here — that is handled at session boundaries by
    /// `saveClipboardIfNeeded` / `restoreClipboard`.
    private func paste(_ text: String, pid: pid_t) {
        guard !text.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        lastPasteAt = Date()
        postKeyToPid(CGKeyCode(kVK_ANSI_V), pid: pid, flags: .maskCommand)
    }

}

extension TerminalInjector: VoiceTextInjecting, VoiceSubmitting {}
