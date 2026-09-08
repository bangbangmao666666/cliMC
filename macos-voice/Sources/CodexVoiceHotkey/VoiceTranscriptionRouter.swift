import Foundation

protocol VoiceTextInjecting: AnyObject {
    func replaceVoiceSpan(backspaces: Int, text: String)
    func replaceVoiceSpan(
        backspaces: Int,
        text: String,
        completion: @escaping () -> Void
    )
    func saveClipboardIfNeeded()
    func restoreClipboard()
    func cancelPending()
}

extension VoiceTextInjecting {
    func replaceVoiceSpan(
        backspaces: Int,
        text: String,
        completion: @escaping () -> Void
    ) {
        replaceVoiceSpan(backspaces: backspaces, text: text)
        completion()
    }
    func saveClipboardIfNeeded() {}
    func restoreClipboard() {}
    func cancelPending() {}
}

protocol VoiceSubmitting: AnyObject {
    func submit()
}

protocol VoiceIndicatorPresenting: AnyObject {
    /// 展示某个状态的文字内容（倒计时秒数 / 庆祝 emoji / 错误信息）。
    func show(_ state: VoiceIndicatorState, text: String?)
    func updateSpectrum(_ levels: [Double])
    func hide()
}

extension VoiceIndicatorPresenting {
    func updateSpectrum(_ levels: [Double]) {}
}

final class VoiceTranscriptionRouter {
    var onFinalCommit: ((String) -> Void)?

    private let injector: VoiceTextInjecting
    private let indicator: VoiceIndicatorPresenting
    private let commandResolver: NaturalVoiceCommandResolver
    private let session = TranscriptionSession()
    /// Full text of whatever is currently displayed in the terminal input
    /// field.  Used both to compute the minimal delta against the next
    /// partial result and to know how much to backspace when the final
    /// result is committed.
    private var displayedVoiceText = ""

    init(
        aliases: [String: String],
        injector: VoiceTextInjecting,
        indicator: VoiceIndicatorPresenting
    ) {
        self.commandResolver = NaturalVoiceCommandResolver(aliases: aliases)
        self.injector = injector
        self.indicator = indicator
    }

    func beginRecording() {
        displayedVoiceText = ""
        indicator.show(.listening, text: nil)
        injector.saveClipboardIfNeeded()
    }

    func handleResult(text: String, isFinal: Bool, isRecording: Bool) {
        let action = session.receive(text: text, isFinal: isFinal, isRecording: isRecording)
        let now = Date()
        switch action {
        case .preview(let previewText):
            log("ASR 部分结果到达 text=\"\(text)\" at=\(now.timeIntervalSince1970)")
            indicator.show(.listening, text: nil)
            // Push the minimal delta into the input field so the user sees
            // text appear in real time.  Rather than backspacing the whole
            // previous preview and re-pasting the full new text (which sends
            // O(n²) key events and races the terminal's PTY round-trip), we
            // only backspace the trailing characters that changed and paste
            // the new suffix.  This keeps the common append-only case to a
            // single short paste with zero backspaces.
            injectLivePreview(previewText)
        case .commit(let committedText):
            log("ASR 最终结果到达 text=\"\(text)\" at=\(now.timeIntervalSince1970)")
            indicator.hide()
            commitVoiceSpan(committedText)
        case .none:
            break
        }
    }

    /// Replace the previous live preview with a new one using the smallest
    /// possible edit: backspace only the trailing characters of the previous
    /// preview that are not a prefix of the new text, then paste only the
    /// new trailing suffix.
    private func injectLivePreview(_ text: String) {
        let previous = displayedVoiceText
        let prefixCount = Self.commonPrefixCount(previous, text)
        let backspaces = previous.count - prefixCount
        let suffix = String(text.dropFirst(prefixCount))
        displayedVoiceText = text
        let now = Date()
        log("实时预览注入：backspaces=\(backspaces) suffix=\"\(suffix)\" full=\"\(text)\" at=\(now.timeIntervalSince1970)")
        guard backspaces > 0 || !suffix.isEmpty else { return }
        injector.replaceVoiceSpan(backspaces: backspaces, text: suffix)
    }

    /// Called when recording is cancelled before the final commit.
    func cancelRecording() {
        injector.cancelPending()
        injector.restoreClipboard()
    }

    @discardableResult
    func finishRecording() -> Bool {
        if let text = session.finishRecording() {
            indicator.hide()
            commitVoiceSpan(text)
            return true
        }
        if !session.hasCommitted {
            injector.restoreClipboard()
        }
        return false
    }

    private func commitVoiceSpan(_ text: String) {
        let nextText = commandResolver.resolve(text) ?? text
        let prefixCount = Self.commonPrefixCount(displayedVoiceText, nextText)
        let backspaces = displayedVoiceText.count - prefixCount
        let suffix = String(nextText.dropFirst(prefixCount))
        displayedVoiceText = nextText
        if backspaces > 0 || !suffix.isEmpty {
            injector.replaceVoiceSpan(
                backspaces: backspaces,
                text: suffix
            ) { [weak self] in
                guard let self else { return }
                self.onFinalCommit?(nextText)
                self.injector.restoreClipboard()
            }
        } else {
            onFinalCommit?(nextText)
            injector.restoreClipboard()
        }
    }

    /// Number of leading grapheme clusters shared by both strings.
    private static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var count = 0
        var ai = a.startIndex
        var bi = b.startIndex
        while ai < a.endIndex && bi < b.endIndex && a[ai] == b[bi] {
            count += 1
            a.formIndex(after: &ai)
            b.formIndex(after: &bi)
        }
        return count
    }
}
