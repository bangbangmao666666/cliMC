import CoreGraphics

enum VoiceSyntheticEvent {
    static let marker: Int64 = 0x434C_494D_43
}

enum InputActivityClassifier {
    static func shouldNotify(type: CGEventType, marker: Int64) -> Bool {
        guard marker != VoiceSyntheticEvent.marker else { return false }
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return true
        default:
            return false
        }
    }
}
