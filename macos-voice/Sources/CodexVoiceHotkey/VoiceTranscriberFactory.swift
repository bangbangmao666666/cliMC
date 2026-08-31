enum VoiceTranscriberFactory {
    static func make(preferences: VoicePreferences) -> any VoiceTranscribing {
        switch preferences.transcriptionProvider {
        case .system:
            SpeechTranscriber()
        case .siliconFlow:
            RemoteSpeechTranscriber(settings: preferences.siliconFlow)
        case .volcengine:
            VolcengineSpeechTranscriber(
                apiKey: preferences.volcengineAPIKey,
                appKey: preferences.volcengineAppKey,
                accessKey: preferences.volcengineAccessKey
            )
        }
    }
}
