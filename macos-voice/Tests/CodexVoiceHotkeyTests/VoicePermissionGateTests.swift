import AVFoundation
import XCTest
import Speech
@testable import CodexVoiceHotkey

final class VoicePermissionGateTests: XCTestCase {
    func testRequestsNothingWhenPermissionsAreAlreadyGranted() {
        let permissions = MockVoicePermissions(
            microphoneStatus: .authorized,
            speechStatus: .authorized
        )
        let gate = VoicePermissionGate(authorizer: permissions)
        var didAuthorize = false
        var deniedMessage: String?

        gate.requestAccessIfNeeded(
            onAuthorized: { didAuthorize = true },
            onDenied: { deniedMessage = $0 }
        )

        XCTAssertTrue(didAuthorize)
        XCTAssertNil(deniedMessage)
        XCTAssertEqual(permissions.microphoneRequestCount, 0)
        XCTAssertEqual(permissions.speechRequestCount, 0)
    }

    func testRequestsPermissionsWhenAuthorizationIsNotDetermined() {
        let permissions = MockVoicePermissions(
            microphoneStatus: .notDetermined,
            speechStatus: .notDetermined,
            microphoneRequestResult: true,
            speechRequestResult: .authorized
        )
        let gate = VoicePermissionGate(authorizer: permissions)
        var didAuthorize = false

        gate.requestAccessIfNeeded(
            onAuthorized: { didAuthorize = true },
            onDenied: { _ in XCTFail("Should not deny when both permissions are granted") }
        )

        XCTAssertEqual(permissions.microphoneRequestCount, 1)
        XCTAssertEqual(permissions.speechRequestCount, 1)
        XCTAssertTrue(didAuthorize)
    }

    func testDoesNotStartWhenPermissionIsDenied() {
        let permissions = MockVoicePermissions(
            microphoneStatus: .denied,
            speechStatus: .authorized
        )
        let gate = VoicePermissionGate(authorizer: permissions)
        var didAuthorize = false
        var deniedMessage: String?

        gate.requestAccessIfNeeded(
            onAuthorized: { didAuthorize = true },
            onDenied: { deniedMessage = $0 }
        )

        XCTAssertFalse(didAuthorize)
        XCTAssertNotNil(deniedMessage)
        XCTAssertEqual(permissions.microphoneRequestCount, 0)
        XCTAssertEqual(permissions.speechRequestCount, 0)
    }
}

private final class MockVoicePermissions: VoicePermissionAuthorizing {
    let microphoneAuthorizationStatus: AVAuthorizationStatus
    let speechAuthorizationStatus: SFSpeechRecognizerAuthorizationStatus
    let microphoneRequestResult: Bool
    let speechRequestResult: SFSpeechRecognizerAuthorizationStatus

    private(set) var microphoneRequestCount = 0
    private(set) var speechRequestCount = 0

    init(
        microphoneStatus: AVAuthorizationStatus,
        speechStatus: SFSpeechRecognizerAuthorizationStatus,
        microphoneRequestResult: Bool = true,
        speechRequestResult: SFSpeechRecognizerAuthorizationStatus = .authorized
    ) {
        self.microphoneAuthorizationStatus = microphoneStatus
        self.speechAuthorizationStatus = speechStatus
        self.microphoneRequestResult = microphoneRequestResult
        self.speechRequestResult = speechRequestResult
    }

    func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        microphoneRequestCount += 1
        completion(microphoneRequestResult)
    }

    func requestMicrophoneAuthorization(_ completion: @escaping (Bool) -> Void) {
        requestMicrophoneAccess(completion)
    }

    func requestSpeechRecognitionAuthorization(_ completion: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        speechRequestCount += 1
        completion(speechRequestResult)
    }

    func requestSpeechAuthorization(_ completion: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        requestSpeechRecognitionAuthorization(completion)
    }
}
