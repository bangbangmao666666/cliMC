import AVFoundation
import Speech

protocol VoicePermissionAuthorizing {
    var microphoneAuthorizationStatus: AVAuthorizationStatus { get }
    var speechAuthorizationStatus: SFSpeechRecognizerAuthorizationStatus { get }
    func requestMicrophoneAuthorization(_ completion: @escaping (Bool) -> Void)
    func requestSpeechAuthorization(_ completion: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void)
}

struct SystemVoicePermissionAuthorizer: VoicePermissionAuthorizing {
    var microphoneAuthorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    var speechAuthorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    func requestMicrophoneAuthorization(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    func requestSpeechAuthorization(_ completion: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        SFSpeechRecognizer.requestAuthorization(completion)
    }
}

final class VoicePermissionGate {
    private let authorizer: VoicePermissionAuthorizing

    init(authorizer: VoicePermissionAuthorizing = SystemVoicePermissionAuthorizer()) {
        self.authorizer = authorizer
    }

    func requestAccessIfNeeded(
        requiresSpeechRecognition: Bool = true,
        onAuthorized: @escaping () -> Void,
        onDenied: @escaping (String) -> Void
    ) {
        let deniedMessage = requiresSpeechRecognition
            ? "未获得麦克风或语音识别权限，热键不会启动。请在系统设置中授权后重启。"
            : "未获得麦克风权限，热键不会启动。请在系统设置中授权后重启。"
        let microphoneStatus = authorizer.microphoneAuthorizationStatus
        let speechStatus = requiresSpeechRecognition ? authorizer.speechAuthorizationStatus : .authorized

        if microphoneStatus == .authorized, speechStatus == .authorized {
            onAuthorized()
            return
        }

        if microphoneStatus == .denied || speechStatus == .denied {
            onDenied(deniedMessage)
            return
        }

        var pendingRequests = 0
        var authorized = true
        var completed = false

        func completeIfNeeded() {
            guard !completed, pendingRequests == 0 else { return }
            completed = true
            if authorized {
                onAuthorized()
            } else {
                onDenied(deniedMessage)
            }
        }

        if microphoneStatus == .notDetermined {
            pendingRequests += 1
            authorizer.requestMicrophoneAuthorization { granted in
                authorized = authorized && granted
                pendingRequests -= 1
                completeIfNeeded()
            }
        } else {
            authorized = authorized && microphoneStatus == .authorized
        }

        if requiresSpeechRecognition && speechStatus == .notDetermined {
            pendingRequests += 1
            authorizer.requestSpeechAuthorization { status in
                authorized = authorized && status == .authorized
                pendingRequests -= 1
                completeIfNeeded()
            }
        } else {
            authorized = authorized && speechStatus == .authorized
        }

        completeIfNeeded()
    }
}
