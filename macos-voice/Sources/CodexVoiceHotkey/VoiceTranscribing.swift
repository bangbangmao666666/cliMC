import Foundation

protocol VoiceTranscribing: AnyObject {
    var onResult: ((String, Bool) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func start(using capture: AudioCapturing) throws
    func stopInput()
    func cancel()
}
