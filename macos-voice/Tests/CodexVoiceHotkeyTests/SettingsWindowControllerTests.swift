import XCTest
@testable import CodexVoiceHotkey

final class SettingsWindowControllerTests: XCTestCase {
    func testSettingsPanesHaveStableTitlesInSidebarOrder() {
        XCTAssertEqual(SettingsPane.allCases.map(\.title), [
            "常规", "语音识别", "个性化", "口令与命令",
        ])
    }

    func testSettingsWindowUsesGeneralPaneByDefault() {
        let controller = SettingsWindowController(preferences: .default) { _ in }

        XCTAssertEqual(controller.activePane, .general)
    }

    func testSelectingPaneUpdatesActivePane() {
        let controller = SettingsWindowController(preferences: .default) { _ in }

        controller.selectPane(.transcription)
        controller.selectPane(.general)

        XCTAssertEqual(controller.activePane, .general)
    }

    func testInitializesWithDefaultPreferencesWithoutCrashing() {
        let controller = SettingsWindowController(preferences: .default) { _ in }

        XCTAssertEqual(controller.window?.title, "cliMC 设置")
        XCTAssertNotNil(controller.window)
    }

    func testDeletingAliasRowRemovesItAndExcludesItFromSavedPreferences() {
        var savedPreferences: VoicePreferences?
        let preferences = VoicePreferences.default
        let controller = SettingsWindowController(preferences: preferences) { savedPreferences = $0 }
        let deletedPhrase = preferences.aliases.keys.sorted().first!
        let deleteButton = findButton(titled: "删除", in: controller.window!.contentView!)

        XCTAssertNotNil(deleteButton)
        deleteButton?.performClick(nil)

        let remainingDeleteButtons = findButtons(titled: "删除", in: controller.window!.contentView!)
        XCTAssertEqual(remainingDeleteButtons.count, preferences.aliases.count - 1)
        findButton(titled: "保存", in: controller.window!.contentView!)?.performClick(nil)
        XCTAssertNil(savedPreferences?.aliases[deletedPhrase])
        XCTAssertEqual(savedPreferences?.aliases.count, preferences.aliases.count - 1)
    }

    func testShortcutRecorderIsIdleUntilExplicitlyStarted() {
        var recorder = ShortcutRecorderState()

        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.acceptsKeyPress)

        recorder.toggle()
        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(recorder.acceptsKeyPress)

        recorder.capture()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.acceptsKeyPress)
    }

    func testAutoSubmitSettingsModelDefaultsToFiveSeconds() {
        let model = AutoSubmitSettingsModel(enabled: true, delaySeconds: 10)
        XCTAssertEqual(model.mode, .fiveSeconds)
        XCTAssertEqual(model.resolvedDelaySeconds, 5)
    }

    func testAutoSubmitSettingsModelOneSecond() {
        var model = AutoSubmitSettingsModel(enabled: true, delaySeconds: 5)
        model.mode = .oneSecond
        XCTAssertEqual(model.resolvedDelaySeconds, 1)
    }

    func testAutoSubmitSettingsModelThreeSeconds() {
        var model = AutoSubmitSettingsModel(enabled: true, delaySeconds: 5)
        model.mode = .threeSeconds
        XCTAssertEqual(model.resolvedDelaySeconds, 3)
    }

    func testAutoSubmitSettingsModelFiveSeconds() {
        var model = AutoSubmitSettingsModel(enabled: true, delaySeconds: 5)
        model.mode = .fiveSeconds
        XCTAssertEqual(model.resolvedDelaySeconds, 5)
    }

    func testReleaseHoldModeMapsSecondsToMode() {
        XCTAssertEqual(ReleaseHoldMode.mode(for: 0), .off)
        XCTAssertEqual(ReleaseHoldMode.mode(for: 1), .oneSecond)
        XCTAssertEqual(ReleaseHoldMode.mode(for: 2.5), .twoPointFiveSeconds)
        XCTAssertEqual(ReleaseHoldMode.mode(for: 5), .fiveSeconds)
    }

    func testReleaseHoldModeResolvesSeconds() {
        XCTAssertEqual(ReleaseHoldMode.off.seconds, 0)
        XCTAssertEqual(ReleaseHoldMode.oneSecond.seconds, 1)
        XCTAssertEqual(ReleaseHoldMode.twoPointFiveSeconds.seconds, 2.5)
        XCTAssertEqual(ReleaseHoldMode.fiveSeconds.seconds, 5)
    }

    func testCelebrationPackOptionsContainOnlyBuiltInPacks() {
        let options = CelebrationPackOption.all()

        XCTAssertTrue(options.allSatisfy(\.isBuiltIn))
        XCTAssertEqual(options.map(\.pack.id), ["classic", "anime", "kaomoji"])
    }

    private func findButton(titled title: String, in view: NSView) -> NSButton? {
        findButtons(titled: title, in: view).first
    }

    private func findButtons(titled title: String, in view: NSView) -> [NSButton] {
        let buttons = (view as? NSButton).map { [$0] } ?? []
        return buttons.filter { $0.title == title } + view.subviews.flatMap { findButtons(titled: title, in: $0) }
    }
}
