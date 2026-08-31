import XCTest
@testable import CodexVoiceHotkey

final class VoicePreferencesTests: XCTestCase {
    func testDefaultPreferencesUseOptionEAndDefaultAliases() {
        let preferences = VoicePreferences.default

        XCTAssertEqual(preferences.shortcut, .optionE)
        XCTAssertEqual(preferences.aliases["目标"], "/goal")
        XCTAssertEqual(preferences.transcriptionProvider, .siliconFlow)
        XCTAssertEqual(preferences.siliconFlow.apiKey, "")
    }

    func testLegacyPreferencesDefaultMissingRemoteSettingsToRemoteValues() throws {
        let legacyJSON = """
        {
          "aliases": {
            "目标": "/goal"
          }
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(VoicePreferences.self, from: legacyJSON)

        XCTAssertEqual(preferences.shortcut, .optionE)
        XCTAssertEqual(preferences.transcriptionProvider, .siliconFlow)
        XCTAssertEqual(preferences.aliases["目标"], "/goal")
        XCTAssertEqual(preferences.aliases["新对话"], "/new")
        XCTAssertEqual(preferences.aliases["压缩"], "/compact")
        XCTAssertEqual(preferences.aliases["清屏"], "/clear")
    }

    func testLegacyRemoteProviderMigratesToSiliconFlow() throws {
        let legacyJSON = """
        {
          "transcriptionProvider": "remote",
          "remoteSTT": {"baseURL":"https://old.example/v1","apiKey":"legacy-key","model":"old-model"}
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(VoicePreferences.self, from: legacyJSON)

        XCTAssertEqual(preferences.transcriptionProvider, .siliconFlow)
        XCTAssertEqual(preferences.siliconFlow.apiKey, "legacy-key")
    }

    func testProviderDescriptionsExplainLatencyAndAccuracyTradeoffs() {
        XCTAssertTrue(VoiceTranscriptionProvider.system.featureDescription.contains("实时"))
        XCTAssertTrue(VoiceTranscriptionProvider.siliconFlow.featureDescription.contains("不实时"))
        XCTAssertTrue(VoiceTranscriptionProvider.volcengine.featureDescription.contains("新版"))
    }

    func testSiliconFlowEndpointAndModelAreFixed() {
        XCTAssertEqual(SiliconFlowSettings.baseURL, "https://api.siliconflow.cn/v1")
        XCTAssertEqual(SiliconFlowSettings.model, "FunAudioLLM/SenseVoiceSmall")
    }

    func testAutoSubmitDefaultsToDisabledWithFiveSecondDelay() {
        XCTAssertFalse(VoicePreferences.default.autoSubmitEnabled)
        XCTAssertEqual(VoicePreferences.default.autoSubmitDelaySeconds, 5)
    }

    func testLegacyPreferencesDefaultAutoSubmitWithoutBreakingDecode() throws {
        let data = #"{"aliases":{"目标":"/goal"}}"#.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(VoicePreferences.self, from: data)

        XCTAssertFalse(preferences.autoSubmitEnabled)
        XCTAssertEqual(preferences.autoSubmitDelaySeconds, 5)
    }

    func testAutoSubmitPreferencesRoundTrip() throws {
        var preferences = VoicePreferences.default
        preferences.autoSubmitEnabled = true
        preferences.autoSubmitDelaySeconds = 10

        let decoded = try JSONDecoder().decode(
            VoicePreferences.self,
            from: JSONEncoder().encode(preferences)
        )

        XCTAssertTrue(decoded.autoSubmitEnabled)
        XCTAssertEqual(decoded.autoSubmitDelaySeconds, 10)
    }

    func testAutoSubmitDelayIsConstrainedToOneThroughSixtySeconds() {
        XCTAssertEqual(VoicePreferences.normalizedAutoSubmitDelay(0), 1)
        XCTAssertEqual(VoicePreferences.normalizedAutoSubmitDelay(7), 7)
        XCTAssertEqual(VoicePreferences.normalizedAutoSubmitDelay(61), 60)
    }

    func testReleaseHoldDefaultsToTwoPointFiveSeconds() {
        XCTAssertEqual(VoicePreferences.default.releaseHoldSeconds, 2.5)
    }

    func testReleaseHoldIsConstrainedToZeroThroughTenSeconds() {
        XCTAssertEqual(VoicePreferences.normalizedReleaseHoldSeconds(-1), 0)
        XCTAssertEqual(VoicePreferences.normalizedReleaseHoldSeconds(2.5), 2.5)
        XCTAssertEqual(VoicePreferences.normalizedReleaseHoldSeconds(11), 10)
    }

    func testReleaseHoldPreferencesRoundTrip() throws {
        var preferences = VoicePreferences.default
        preferences.releaseHoldSeconds = 1

        let decoded = try JSONDecoder().decode(
            VoicePreferences.self,
            from: JSONEncoder().encode(preferences)
        )

        XCTAssertEqual(decoded.releaseHoldSeconds, 1)
    }

    func testLegacyPreferencesDefaultReleaseHoldWithoutBreakingDecode() throws {
        let data = #"{"aliases":{"目标":"/goal"}}"#.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(VoicePreferences.self, from: data)

        XCTAssertEqual(preferences.releaseHoldSeconds, 2.5)
    }

    func testVolcengineStoresAppKeyAndAccessKeySeparately() throws {
        let preferences = VoicePreferences(
            shortcut: .optionE,
            aliases: [:],
            transcriptionProvider: .volcengine,
            volcengineAppKey: "app-key",
            volcengineAccessKey: "access-key"
        )

        let decoded = try JSONDecoder().decode(VoicePreferences.self, from: JSONEncoder().encode(preferences))

        XCTAssertEqual(decoded.volcengineAppKey, "app-key")
        XCTAssertEqual(decoded.volcengineAccessKey, "access-key")
    }

    func testShortcutBindingRequiresConfiguredModifiers() {
        var state = HotkeyState(shortcut: .commandShiftR)

        XCTAssertEqual(
            state.transition(keyCode: 15, isKeyDown: true, modifierFlags: [.maskCommand, .maskShift]),
            .press
        )
        XCTAssertEqual(
            state.transition(keyCode: 15, isKeyDown: true, modifierFlags: [.maskCommand]),
            .none
        )
    }

    func testOptionERequiresOptionModifier() {
        var state = HotkeyState(shortcut: .optionE)

        XCTAssertEqual(
            state.transition(keyCode: 14, isKeyDown: true, modifierFlags: []),
            .none
        )
        XCTAssertEqual(
            state.transition(keyCode: 14, isKeyDown: true, modifierFlags: [.maskAlternate]),
            .press
        )
    }

    func testShortcutCanBeCreatedFromAnyModifierCombination() {
        let shortcut = VoiceShortcut(
            keyCode: 14,
            modifiers: [.maskAlternate, .maskCommand, .maskControl, .maskShift],
            keyName: "E"
        )

        XCTAssertEqual(shortcut.displayName, "⌥⌘⌃⇧E")
        XCTAssertTrue(shortcut.matches([.maskAlternate, .maskCommand, .maskControl, .maskShift]))
        XCTAssertFalse(shortcut.matches([.maskAlternate, .maskCommand, .maskControl]))
    }

    func testShortcutPersistsKeyCodeAndModifiers() throws {
        let shortcut = VoiceShortcut(keyCode: 14, modifiers: [.maskAlternate, .maskShift], keyName: "E")

        let data = try JSONEncoder().encode(shortcut)
        let decoded = try JSONDecoder().decode(VoiceShortcut.self, from: data)

        XCTAssertEqual(decoded, shortcut)
    }

    func testDefaultCelebrationPackIsAnime() {
        XCTAssertEqual(VoicePreferences.default.celebrationPackID, "anime")
    }

    func testLegacyPreferencesDefaultCelebrationPackToAnime() throws {
        let data = #"{"aliases":{"目标":"/goal"}}"#.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(VoicePreferences.self, from: data)

        XCTAssertEqual(preferences.celebrationPackID, "anime")
    }

    func testCelebrationPackPreferencesRoundTrip() throws {
        var preferences = VoicePreferences.default
        preferences.celebrationPackID = "kaomoji"

        let decoded = try JSONDecoder().decode(
            VoicePreferences.self,
            from: JSONEncoder().encode(preferences)
        )

        XCTAssertEqual(decoded.celebrationPackID, "kaomoji")
    }

}
