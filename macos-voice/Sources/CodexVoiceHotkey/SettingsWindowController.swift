import AppKit

enum AutoSubmitDelayMode: String, CaseIterable {
    case oneSecond
    case threeSeconds
    case fiveSeconds

    var title: String {
        switch self {
        case .oneSecond: "1 秒"
        case .threeSeconds: "3 秒"
        case .fiveSeconds: "5 秒"
        }
    }
}

enum ReleaseHoldMode: String, CaseIterable {
    case off
    case oneSecond
    case twoPointFiveSeconds
    case fiveSeconds

    var title: String {
        switch self {
        case .off: "关闭"
        case .oneSecond: "1 秒"
        case .twoPointFiveSeconds: "2.5 秒"
        case .fiveSeconds: "5 秒"
        }
    }

    var seconds: Double {
        switch self {
        case .off: 0
        case .oneSecond: 1
        case .twoPointFiveSeconds: 2.5
        case .fiveSeconds: 5
        }
    }

    static func mode(for seconds: Double) -> ReleaseHoldMode {
        switch seconds {
        case 0: .off
        case 1: .oneSecond
        case 5: .fiveSeconds
        default: .twoPointFiveSeconds
        }
    }
}

enum SettingsPane: String, CaseIterable {
    case general, transcription, correctionModel

    var title: String {
        switch self {
        case .general: "常规"
        case .transcription: "语音识别"
        case .correctionModel: "纠错大模型"
        }
    }
}

struct AutoSubmitSettingsModel {
    var enabled: Bool
    var mode: AutoSubmitDelayMode

    init(enabled: Bool, delaySeconds: Int) {
        self.enabled = enabled
        switch delaySeconds {
        case 1:
            mode = .oneSecond
        case 3:
            mode = .threeSeconds
        default:
            mode = .fiveSeconds
        }
    }

    var resolvedDelaySeconds: Int {
        switch mode {
        case .oneSecond:
            return 1
        case .threeSeconds:
            return 3
        case .fiveSeconds:
            return 5
        }
    }
}

final class SettingsWindowController: NSWindowController {
    private let initialPreferences: VoicePreferences
    private let onSave: (VoicePreferences) -> Void
    var onOpenUsageStats: (() -> Void)?
    var onOpenVocab: (() -> Void)?
    private let shortcutRecorder: ShortcutRecorderButton
    private let transcriptionProviderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let providerFeatureLabel = NSTextField(labelWithString: "")
    private let apiKeyField = NSSecureTextField(string: "")
    private let deepSeekAPIKeyField = NSSecureTextField(string: "")
    private let deepSeekBaseURLField = NSTextField(string: "")
    private let deepSeekModelField = NSTextField(string: "")
    private let volcengineAPIKeyField = NSSecureTextField(string: "")
    private let contextualCorrectionCheckbox = NSButton(
        checkboxWithTitle: "使用 DeepSeek 上下文纠错",
        target: nil,
        action: nil
    )
    private let autoSubmitCheckbox = NSButton(
        checkboxWithTitle: "自动提交语音输入",
        target: nil,
        action: nil
    )
    private let autoSubmitDelayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var autoSubmitModel: AutoSubmitSettingsModel
    private let releaseHoldPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var releaseHoldMode: ReleaseHoldMode
    private let celebrationPackPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var celebrationPackOptions: [CelebrationPackOption] = []
    private let paneContainer = NSView()
    private var paneViews: [SettingsPane: NSView] = [:]
    private var paneButtons: [SettingsPane: NSButton] = [:]
    private(set) var activePane: SettingsPane = .general

    init(
        preferences: VoicePreferences,
        onSave: @escaping (VoicePreferences) -> Void
    ) {
        self.initialPreferences = preferences
        self.onSave = onSave
        self.celebrationPackOptions = CelebrationPackOption.all()
        self.shortcutRecorder = ShortcutRecorderButton(shortcut: preferences.shortcut)
        self.autoSubmitModel = AutoSubmitSettingsModel(
            enabled: preferences.autoSubmitEnabled,
            delaySeconds: preferences.autoSubmitDelaySeconds
        )
        self.releaseHoldMode = ReleaseHoldMode.mode(for: preferences.releaseHoldSeconds)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "cliMC 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        let sidebar = buildSidebar()
        let content = NSStackView()
        content.orientation = .vertical
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        root.addSubview(content)

        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(paneContainer)
        paneContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.distribution = .gravityAreas
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        buttons.addView(NSView(), in: .leading)
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(save)
        content.addArrangedSubview(buttons)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 148),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        addPane(buildGeneralPane(), for: .general)
        addPane(buildTranscriptionPane(), for: .transcription)
        addPane(buildCorrectionModelPane(), for: .correctionModel)
        selectPane(.general)
    }

    private func buildSidebar() -> NSStackView {
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 4
        sidebar.edgeInsets = NSEdgeInsets(top: 20, left: 12, bottom: 20, right: 12)
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        for pane in SettingsPane.allCases {
            let button = NSButton(title: pane.title, target: self, action: #selector(paneSelected))
            button.tag = SettingsPane.allCases.firstIndex(of: pane) ?? 0
            button.alignment = .left
            button.bezelStyle = .rounded
            button.setButtonType(.toggle)
            button.contentTintColor = .labelColor
            button.widthAnchor.constraint(equalToConstant: 124).isActive = true
            sidebar.addArrangedSubview(button)
            paneButtons[pane] = button
        }
        return sidebar
    }

    private func buildPaneStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func buildGeneralPane() -> NSView {
        let pane = buildPaneStack()
        pane.addArrangedSubview(sectionLabel("快捷键"))
        let shortcutHint = NSTextField(labelWithString: "点击后按下快捷键组合；支持 ⌥ Option、⌘ Command、⌃ Control、⇧ Shift。")
        shortcutHint.textColor = .secondaryLabelColor
        shortcutHint.font = .systemFont(ofSize: 12)
        pane.addArrangedSubview(shortcutHint)
        shortcutRecorder.widthAnchor.constraint(equalToConstant: 180).isActive = true
        pane.addArrangedSubview(shortcutRecorder)

        pane.addArrangedSubview(sectionLabel("自动提交"))
        autoSubmitCheckbox.state = autoSubmitModel.enabled ? .on : .off
        autoSubmitCheckbox.target = self
        autoSubmitCheckbox.action = #selector(autoSubmitChanged)
        pane.addArrangedSubview(autoSubmitCheckbox)

        AutoSubmitDelayMode.allCases.forEach { mode in
            autoSubmitDelayPopup.addItem(withTitle: mode.title)
            autoSubmitDelayPopup.lastItem?.representedObject = mode.rawValue
        }
        autoSubmitDelayPopup.selectItem(withTitle: autoSubmitModel.mode.title)
        autoSubmitDelayPopup.target = self
        autoSubmitDelayPopup.action = #selector(autoSubmitDelayChanged)
        autoSubmitDelayPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        pane.addArrangedSubview(autoSubmitDelayPopup)
        updateAutoSubmitControls()

        let releaseHoldHint = NSTextField(labelWithString: "松开热键后继续录音的缓冲时间，用于火山引擎二遍识别；关闭后立即定稿。")
        releaseHoldHint.textColor = .secondaryLabelColor
        releaseHoldHint.font = .systemFont(ofSize: 12)
        releaseHoldHint.maximumNumberOfLines = 0
        releaseHoldHint.preferredMaxLayoutWidth = 460
        pane.addArrangedSubview(releaseHoldHint)
        ReleaseHoldMode.allCases.forEach { mode in
            releaseHoldPopup.addItem(withTitle: mode.title)
            releaseHoldPopup.lastItem?.representedObject = mode.rawValue
        }
        releaseHoldPopup.selectItem(withTitle: releaseHoldMode.title)
        releaseHoldPopup.target = self
        releaseHoldPopup.action = #selector(releaseHoldChanged)
        releaseHoldPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        pane.addArrangedSubview(releaseHoldPopup)

        pane.addArrangedSubview(sectionLabel("提交庆祝表情"))
        let celebrationHint = NSTextField(labelWithString: "语音自动提交后随机弹出的内置表情包。")
        celebrationHint.textColor = .secondaryLabelColor
        celebrationHint.font = .systemFont(ofSize: 12)
        celebrationHint.maximumNumberOfLines = 0
        celebrationHint.preferredMaxLayoutWidth = 460
        pane.addArrangedSubview(celebrationHint)
        rebuildCelebrationPackPopup()
        celebrationPackPopup.target = self
        celebrationPackPopup.action = #selector(celebrationPackChanged)
        celebrationPackPopup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        pane.addArrangedSubview(celebrationPackPopup)

        let statsButton = NSButton(title: "查看使用统计…", target: self, action: #selector(openUsageStats))
        statsButton.bezelStyle = .rounded
        pane.addArrangedSubview(statsButton)
        return pane
    }

    private func buildTranscriptionPane() -> NSView {
        let pane = buildPaneStack()
        pane.addArrangedSubview(sectionLabel("语音识别"))
        VoiceTranscriptionProvider.allCases.forEach { provider in
            transcriptionProviderPopup.addItem(withTitle: provider.displayName)
            transcriptionProviderPopup.lastItem?.representedObject = provider.rawValue
        }
        transcriptionProviderPopup.selectItem(withTitle: initialPreferences.transcriptionProvider.displayName)
        transcriptionProviderPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        pane.addArrangedSubview(transcriptionProviderPopup)

        providerFeatureLabel.textColor = .secondaryLabelColor
        providerFeatureLabel.font = .systemFont(ofSize: 12)
        providerFeatureLabel.maximumNumberOfLines = 0
        providerFeatureLabel.preferredMaxLayoutWidth = 460
        pane.addArrangedSubview(providerFeatureLabel)
        addFieldRow(root: pane, title: "API Key", field: apiKeyField, value: initialPreferences.siliconFlow.apiKey)
        addFieldRow(root: pane, title: "新版 API Key", field: volcengineAPIKeyField, value: initialPreferences.volcengineAPIKey)
        updateProviderDetails()
        transcriptionProviderPopup.target = self
        transcriptionProviderPopup.action = #selector(providerChanged)
        return pane
    }

    private func buildCorrectionModelPane() -> NSView {
        let pane = buildPaneStack()
        pane.addArrangedSubview(sectionLabel("上下文纠错"))
        contextualCorrectionCheckbox.state = initialPreferences.contextualCorrectionEnabled ? .on : .off
        pane.addArrangedSubview(contextualCorrectionCheckbox)
        let correctionPrivacyHint = NSTextField(labelWithString: "启用后，每次最终转写文本会发送给所配置的大模型做中英文上下文纠错。仅提交转写文本和词表术语，不上传音频；请求失败时保留 ASR 原文。")
        correctionPrivacyHint.textColor = .secondaryLabelColor
        correctionPrivacyHint.font = .systemFont(ofSize: 12)
        correctionPrivacyHint.maximumNumberOfLines = 0
        correctionPrivacyHint.preferredMaxLayoutWidth = 460
        pane.addArrangedSubview(correctionPrivacyHint)
        addFieldRow(root: pane, title: "API Key", field: deepSeekAPIKeyField, value: initialPreferences.deepSeek.apiKey)
        addFieldRow(root: pane, title: "API 地址", field: deepSeekBaseURLField, value: initialPreferences.deepSeek.baseURL)
        addFieldRow(root: pane, title: "模型名称", field: deepSeekModelField, value: initialPreferences.deepSeek.model)

        pane.addArrangedSubview(sectionLabel("纠错参考词表"))
        let vocabularyHint = NSTextField(labelWithString: "词表中的热词和纠错目标会作为上下文传给大模型参考；最多包含权重最高的 80 个热词。")
        vocabularyHint.textColor = .secondaryLabelColor
        vocabularyHint.font = .systemFont(ofSize: 12)
        vocabularyHint.maximumNumberOfLines = 0
        vocabularyHint.preferredMaxLayoutWidth = 460
        pane.addArrangedSubview(vocabularyHint)
        let vocabButton = NSButton(title: "管理热词与纠错词…", target: self, action: #selector(openVocab))
        vocabButton.bezelStyle = .rounded
        pane.addArrangedSubview(vocabButton)
        return pane
    }

    private func addPane(_ pane: NSView, for kind: SettingsPane) {
        paneContainer.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
            pane.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            pane.bottomAnchor.constraint(lessThanOrEqualTo: paneContainer.bottomAnchor),
        ])
        paneViews[kind] = pane
    }

    @objc private func paneSelected(_ sender: NSButton) {
        guard SettingsPane.allCases.indices.contains(sender.tag) else { return }
        selectPane(SettingsPane.allCases[sender.tag])
    }

    func selectPane(_ pane: SettingsPane) {
        activePane = pane
        paneViews.forEach { kind, view in view.isHidden = kind != pane }
        paneButtons.forEach { kind, button in
            button.state = kind == pane ? .on : .off
            button.contentTintColor = kind == pane ? .controlAccentColor : .labelColor
        }
    }

    @objc private func providerChanged() { updateProviderDetails() }

    @objc private func autoSubmitChanged() {
        autoSubmitModel.enabled = autoSubmitCheckbox.state == .on
        updateAutoSubmitControls()
    }

    @objc private func autoSubmitDelayChanged() {
        guard let raw = autoSubmitDelayPopup.selectedItem?.representedObject as? String,
              let mode = AutoSubmitDelayMode(rawValue: raw)
        else { return }
        autoSubmitModel.mode = mode
        updateAutoSubmitControls()
    }

    @objc private func releaseHoldChanged() {
        guard let raw = releaseHoldPopup.selectedItem?.representedObject as? String,
              let mode = ReleaseHoldMode(rawValue: raw)
        else { return }
        releaseHoldMode = mode
    }

    private func updateAutoSubmitControls() {
        autoSubmitDelayPopup.isEnabled = autoSubmitModel.enabled
    }

    private func updateProviderDetails() {
        guard let raw = transcriptionProviderPopup.selectedItem?.representedObject as? String,
              let provider = VoiceTranscriptionProvider(rawValue: raw) else { return }
        providerFeatureLabel.stringValue = provider.featureDescription
        let isSiliconFlow = provider == .siliconFlow
        let isVolcengine = provider == .volcengine
        apiKeyField.superview?.isHidden = !isSiliconFlow
        volcengineAPIKeyField.superview?.isHidden = !isVolcengine
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        return label
    }

    private func addFieldRow(root: NSStackView, title: String, field: NSTextField, value: String) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 96).isActive = true

        field.stringValue = value
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true

        row.addArrangedSubview(label)
        row.addArrangedSubview(field)
        root.addArrangedSubview(row)
    }

    @objc private func cancel() {
        close()
    }

    @objc private func openUsageStats() {
        close()
        onOpenUsageStats?()
    }

    @objc private func openVocab() {
        close()
        onOpenVocab?()
    }

    @objc private func save() {
        let shortcut = shortcutRecorder.shortcut
        guard let rawProvider = transcriptionProviderPopup.selectedItem?.representedObject as? String,
              let provider = VoiceTranscriptionProvider(rawValue: rawProvider)
        else { return }
        let siliconFlow = SiliconFlowSettings(apiKey: apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        let deepSeekBaseURL = deepSeekBaseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let deepSeekModel = deepSeekModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let deepSeek = DeepSeekSettings(
            apiKey: deepSeekAPIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: deepSeekBaseURL.isEmpty ? DeepSeekSettings.defaultBaseURL : deepSeekBaseURL,
            model: deepSeekModel.isEmpty ? DeepSeekSettings.defaultModel : deepSeekModel
        )
        let volcengineAPIKey = volcengineAPIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(VoicePreferences(
            shortcut: shortcut,
            aliases: initialPreferences.aliases,
            transcriptionProvider: provider,
            siliconFlow: siliconFlow,
            deepSeek: deepSeek,
            contextualCorrectionEnabled: contextualCorrectionCheckbox.state == .on,
            volcengineAppKey: initialPreferences.volcengineAppKey,
            volcengineAccessKey: initialPreferences.volcengineAccessKey,
            volcengineAPIKey: volcengineAPIKey,
            autoSubmitEnabled: autoSubmitCheckbox.state == .on,
            autoSubmitDelaySeconds: autoSubmitModel.resolvedDelaySeconds,
            releaseHoldSeconds: releaseHoldMode.seconds,
            celebrationPackID: selectedCelebrationPackID()
        ))
        close()
    }

    private func rebuildCelebrationPackPopup() {
        celebrationPackPopup.removeAllItems()
        for option in celebrationPackOptions {
            celebrationPackPopup.addItem(withTitle: option.pack.displayName)
            celebrationPackPopup.lastItem?.representedObject = option.pack.id
        }
        let currentID = initialPreferences.celebrationPackID
        if let item = celebrationPackPopup.itemArray.first(where: { ($0.representedObject as? String) == currentID }) {
            celebrationPackPopup.select(item)
        } else if let first = celebrationPackPopup.itemArray.first {
            celebrationPackPopup.select(first)
        }
    }

    private func selectedCelebrationPackID() -> String {
        (celebrationPackPopup.selectedItem?.representedObject as? String) ?? CelebrationPack.default.id
    }

    @objc private func celebrationPackChanged() {}

}

struct ShortcutRecorderState {
    private(set) var isRecording = false

    var acceptsKeyPress: Bool { isRecording }

    mutating func toggle() {
        isRecording.toggle()
    }

    mutating func capture() {
        isRecording = false
    }
}

private final class ShortcutRecorderButton: NSButton {
    private(set) var shortcut: VoiceShortcut
    private var recorderState = ShortcutRecorderState()

    init(shortcut: VoiceShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        title = shortcut.displayName
        bezelStyle = .rounded
        isBordered = true
        focusRingType = .exterior
        target = self
        action = #selector(toggleRecording)
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func toggleRecording() {
        recorderState.toggle()
        title = recorderState.isRecording ? "请按下快捷键…" : shortcut.displayName
        if recorderState.isRecording {
            window?.makeFirstResponder(self)
        } else {
            window?.makeFirstResponder(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard recorderState.acceptsKeyPress else { return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.isEmpty,
              let keyName = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
              !keyName.isEmpty else { return }
        let normalizedName = keyName.count == 1 ? keyName.uppercased() : keyName
        shortcut = VoiceShortcut(
            keyCode: Int64(event.keyCode),
            modifiers: flags.cgEventFlags,
            keyName: normalizedName
        )
        recorderState.capture()
        title = shortcut.displayName
        window?.makeFirstResponder(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recorderState.acceptsKeyPress else { return false }
        keyDown(with: event)
        return true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private extension NSEvent.ModifierFlags {
    var cgEventFlags: CGEventFlags {
        var result: CGEventFlags = []
        if contains(.command) { result.insert(.maskCommand) }
        if contains(.control) { result.insert(.maskControl) }
        if contains(.option) { result.insert(.maskAlternate) }
        if contains(.shift) { result.insert(.maskShift) }
        return result
    }
}
