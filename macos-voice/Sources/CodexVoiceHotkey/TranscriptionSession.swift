import Foundation

enum TranscriptionDeliveryAction: Equatable {
    case preview(String)
    case commit(String)
    case none
}

final class TranscriptionSession {
    private(set) var latestText = ""
    private(set) var hasCommitted = false
    private var pendingCommitText: String?

    func receive(text: String, isFinal: Bool, isRecording: Bool) -> TranscriptionDeliveryAction {
        latestText = text
        if isRecording {
            if isFinal {
                hasCommitted = true
                return .commit(text)
            }
            return .preview(text)
        }

        if isFinal {
            pendingCommitText = nil
            hasCommitted = true
            return .commit(text)
        }

        return .none
    }

    func finishRecording() -> String? {
        defer { pendingCommitText = nil }
        guard !hasCommitted else { return nil }
        return pendingCommitText
    }
}
