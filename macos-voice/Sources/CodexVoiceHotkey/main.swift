import AppKit
import AVFoundation
import Speech

final class VoiceController: VoiceControlling {
    private static let captureStaleThresholdNanoseconds: UInt64 = 500_000_000
    private var preferences: VoicePreferences
    private let injector: any VoiceTextInjecting & VoiceSubmitting
    private let autoSubmitCoordinator: VoiceAutoSubmitCoordinator
    private var transcriber: any VoiceTranscribing
    private let capture: any AudioCapturing
    private let preferencesSaver: (VoicePreferences) throws -> Void
    private let transcriberFactory: (VoicePreferences) -> any VoiceTranscribing
    private let hotkey: HotkeyMonitor
    private let permissionGate: VoicePermissionGate
    private var transcriptionRouter: VoiceTranscriptionRouter
    private let indicator: any VoiceIndicatorPresenting
    private let nowNanoseconds: () -> UInt64
    private let watchdogScheduler: (TimeInterval, @escaping () -> Void) -> Void
    private let statusBar = StatusBarController()
    private var settingsWindow: SettingsWindowController?
    private var showSettingsObserver: NSObjectProtocol?
    private var transcriberGeneration = 0
    private var captureStarted = false
    private var captureState: AudioCaptureState = .idle
    private var isRecording = false
    private let usageStatsRecorder: (any UsageStatsRecording)?
    private let usageStatsStore: UsageStatsStore?
    private var webLauncher: WebLauncher?
    private var releaseHoldTime: TimeInterval
    private var releaseHoldWorkItem: DispatchWorkItem?
    private var celebration: SubmissionCelebration
    private var recordingGeneration: UInt64 = 0
    private var recordingPCMCountBaseline: UInt64 = 0
    private var didRequestWatchdogRecovery = false

    convenience init() {
        let preferences = VoicePreferencesStore.load()
        let pack = CelebrationPack.resolve(preferences.celebrationPackID)
        self.init(
            preferences: preferences,
            transcriber: VoiceTranscriberFactory.make(preferences: preferences),
            captureFactory: { AudioCaptureSession() },
            injector: TerminalInjector(),
            indicator: VoiceIndicator(),
            usageStatsRecorder: UsageStatsStore(),
            submissionCelebration: SubmissionCelebration(pack: pack)
        )
    }

    init(
        preferences: VoicePreferences,
        transcriber: any VoiceTranscribing,
        captureFactory: @escaping () -> any AudioCapturing,
        injector: any VoiceTextInjecting & VoiceSubmitting,
        indicator: any VoiceIndicatorPresenting,
        usageStatsRecorder: (any UsageStatsRecording)? = nil,
        preferencesSaver: @escaping (VoicePreferences) throws -> Void = VoicePreferencesStore.save,
        transcriberFactory: @escaping (VoicePreferences) -> any VoiceTranscribing = VoiceTranscriberFactory.make,
        autoSubmitScheduler: any AutoSubmitScheduling = DispatchAutoSubmitScheduler(),
        submissionCelebration: SubmissionCelebration? = nil,
        nowNanoseconds: @escaping () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        watchdogScheduler: @escaping (
            TimeInterval,
            @escaping () -> Void
        ) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        let resolvedCelebration = submissionCelebration ?? SubmissionCelebration(
            pack: CelebrationPack.resolve(preferences.celebrationPackID)
        )
        releaseHoldTime = VoicePreferences.normalizedReleaseHoldSeconds(preferences.releaseHoldSeconds)
        self.preferences = preferences
        self.transcriber = transcriber
        capture = captureFactory()
        self.preferencesSaver = preferencesSaver
        self.transcriberFactory = transcriberFactory
        self.injector = injector
        self.indicator = indicator
        self.usageStatsRecorder = usageStatsRecorder
        self.usageStatsStore = usageStatsRecorder as? UsageStatsStore
        self.celebration = resolvedCelebration
        autoSubmitCoordinator = VoiceAutoSubmitCoordinator(
            enabled: preferences.autoSubmitEnabled,
            delaySeconds: preferences.autoSubmitDelaySeconds,
            scheduler: autoSubmitScheduler,
            submit: { injector.submit() },
            onAutoSubmitted: { [weak usageStatsRecorder] in
                do {
                    try usageStatsRecorder?.recordAutoSubmitted(at: Date())
                } catch {
                    log("无法写入自动提交统计：\(error.localizedDescription)")
                }
            },
            onCountdown: { [weak indicator] seconds in
                indicator?.show(.countdown, text: String(seconds))
            },
            onSubmitted: { [weak indicator] in
                indicator?.show(.submitted, text: resolvedCelebration.next().joined(separator: "\n"))
            },
            onDismiss: { [weak indicator] in
                indicator?.hide()
            }
        )
        self.nowNanoseconds = nowNanoseconds
        self.watchdogScheduler = watchdogScheduler
        hotkey = HotkeyMonitor(shortcut: preferences.shortcut)
        permissionGate = VoicePermissionGate()
        transcriptionRouter = VoiceTranscriptionRouter(
            aliases: preferences.aliases,
            injector: injector,
            indicator: indicator,
            corrections: { CustomVocabulary.load().corrections },
            knownTerms: Self.contextualCorrectionTerms,
            contextualCorrector: Self.makeContextualCorrector(
                preferences,
                usageStatsRecorder: self.usageStatsRecorder
            )
        )
        bindTranscriptionRouterCallbacks()
        bindTranscriberCallbacks()
        hotkey.onPress = { [weak self] in self?.beginRecording() }
        hotkey.onRelease = { [weak self] in self?.finishRecording() }
        let autoSubmitCoordinator = self.autoSubmitCoordinator
        hotkey.onUserActivity = { [weak autoSubmitCoordinator] in
            autoSubmitCoordinator?.cancelPending()
        }
        hotkey.onStatus = { message in log(message) }
        statusBar.onOpenSettings = { [weak self] in self?.showSettings() }
        statusBar.onOpenUsageStats = { [weak self] in self?.showUsageStats() }
        showSettingsObserver = LaunchCommandCenter.observeShowSettings { [weak self] in
            self?.showSettings()
        }
    }

    deinit {
        if captureStarted {
            capture.stop()
        }
    }

    func start() {
        log("正在检查麦克风和语音识别权限…")
        permissionGate.requestAccessIfNeeded(
            requiresSpeechRecognition: preferences.transcriptionProvider == .system,
            onAuthorized: { [weak self] in
                self?.startCaptureIfNeeded()
                _ = self?.hotkey.start()
            },
            onDenied: { message in
                log(message)
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "cliMC 需要辅助功能权限"
                    alert.informativeText = "请打开“系统设置 → 隐私与安全性 → 辅助功能”，添加并启用 cliMC，然后退出并重新打开 cliMC。"
                    alert.addButton(withTitle: "知道了")
                    alert.addButton(withTitle: "退出 cliMC")
                    if alert.runModal() == .alertSecondButtonReturn {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        )
    }

    func startCaptureIfNeeded() {
        guard !captureStarted else { return }
        bindCaptureCallbacks()
        do {
            try capture.start()
            captureStarted = true
        } catch {
            log("无法预热 AirPods 麦克风：\(error.localizedDescription)")
        }
    }

    private func bindCaptureCallbacks() {
        capture.onStateChange = { [weak self] state, _ in
            let updateState = { [weak self] in
                guard let self else { return }
                self.captureState = state
                guard self.isRecording else { return }
                switch state {
                case .waitingForAudio:
                    self.indicator.show(.waitingForAudio, text: nil)
                case .capturing:
                    self.indicator.show(.listening, text: nil)
                case .idle, .preparing, .stopping:
                    break
                }
            }
            if Thread.isMainThread {
                updateState()
            } else {
                DispatchQueue.main.async(execute: updateState)
            }
        }
        capture.onSpectrum = { [weak self] levels in
            let updateSpectrum = { [weak self] in
                guard let self, self.isRecording else { return }
                self.indicator.updateSpectrum(levels)
            }
            if Thread.isMainThread {
                updateSpectrum()
            } else {
                DispatchQueue.main.async(execute: updateSpectrum)
            }
        }
    }

    func beginRecording() {
        autoSubmitCoordinator.cancelPending()
        if let workItem = releaseHoldWorkItem {
            releaseHoldWorkItem = nil
            workItem.cancel()
            isRecording = false
            transcriber.stopInput()
            transcriptionRouter.finishRecording()
            statusBar.update(isRecording: false)
            autoSubmitCoordinator.cancelPending()
            log("释放缓冲被新录音中断，正在定稿…")
        }
        guard !isRecording else { return }
        startCaptureIfNeeded()
        guard captureStarted else { return }

        let now = nowNanoseconds()
        let captureHealth = capture.health
        var didRequestPreflightRecovery = false
        if let lastFrame = captureHealth.lastFrameNanoseconds {
            if now < lastFrame ||
                now - lastFrame >= Self.captureStaleThresholdNanoseconds {
                log("按键时检测到采集帧已过期，正在重建。")
                didRequestPreflightRecovery = true
                capture.recover(reason: "按键时采集帧已过期")
            }
        } else {
            log("按键时没有采集帧，正在重建。")
            didRequestPreflightRecovery = true
            capture.recover(reason: "按键时没有采集帧")
        }

        recordingGeneration &+= 1
        let generation = recordingGeneration
        recordingPCMCountBaseline = capture.health.consumerDeliveryCount
        let recordingRecoveryGenerationBaseline = capture.health.recoveryGeneration
        didRequestWatchdogRecovery = false
        do {
            transcriptionRouter.beginRecording()
            isRecording = true
            try transcriber.start(using: capture)
            watchdogScheduler(0.5) { [weak self] in
                guard let self,
                      self.isRecording,
                      self.recordingGeneration == generation,
                      !self.didRequestWatchdogRecovery,
                      !didRequestPreflightRecovery,
                      self.capture.health.recoveryGeneration == recordingRecoveryGenerationBaseline,
                      self.capture.health.consumerDeliveryCount == self.recordingPCMCountBaseline
                else { return }

                self.didRequestWatchdogRecovery = true
                self.indicator.show(.waitingForAudio, text: nil)
                log("录音 500ms 未收到 PCM，正在重建采集链路并继续录音。")
                self.capture.recover(reason: "录音 500ms 未收到 PCM")
            }
            switch captureState {
            case .capturing:
                indicator.show(.listening, text: nil)
            case .idle, .preparing, .waitingForAudio, .stopping:
                indicator.show(.waitingForAudio, text: nil)
            }
            statusBar.update(isRecording: true)
            recordUsage { recorder in
                try recorder.recordVoiceStarted(at: Date())
            }
            log("开始录音（\(preferences.shortcut.displayName)）…")
        } catch {
            isRecording = false
            recordingGeneration &+= 1
            transcriber.cancel()
            log("无法开始录音：\(error.localizedDescription)")
        }
    }

    func finishRecording() {
        guard isRecording else { return }
        let health = capture.health
        guard health.consumerDeliveryCount > recordingPCMCountBaseline else {
            isRecording = false
            recordingGeneration &+= 1
            transcriber.cancel()
            _ = transcriptionRouter.finishRecording()
            statusBar.update(isRecording: false)
            indicator.show(
                .error,
                text: "未收到麦克风音频，已重建采集链路，请重试"
            )
            log(
                "结束录音时 PCM 仍为 0；基线 \(recordingPCMCountBaseline)，"
                + "当前 \(health.consumerDeliveryCount)，恢复代次 \(health.recoveryGeneration)。"
            )
            capture.recover(reason: "松键时 PCM 仍为 0")
            return
        }

        recordingGeneration &+= 1 // The watchdog must not fire after the user releases the shortcut.
        if releaseHoldTime <= 0 {
            isRecording = false
            transcriber.stopInput()
            let committedImmediately = transcriptionRouter.finishRecording()
            statusBar.update(isRecording: false)
            if !committedImmediately {
                indicator.show(.transcribing, text: nil)
            }
            log("结束录音（无释放缓冲）…")
            return
        }

        indicator.show(.waitingForAudio, text: "缓冲")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isRecording = false
            self.transcriber.stopInput()
            let committedImmediately = self.transcriptionRouter.finishRecording()
            self.statusBar.update(isRecording: false)
            if !committedImmediately {
                self.indicator.show(.transcribing, text: nil)
            }
            log("结束录音（释放后缓冲 \(String(format: "%.1f", self.releaseHoldTime)) 秒）…")
        }
        releaseHoldWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseHoldTime, execute: workItem)
    }

    private func handleResult(text: String, isFinal: Bool) {
        log(isFinal ? "收到最终转写：\(text)" : "收到部分转写：\(text)")
        transcriptionRouter.handleResult(text: text, isFinal: isFinal, isRecording: isRecording)
    }

    private func bindTranscriberCallbacks() {
        transcriberGeneration += 1
        let generation = transcriberGeneration
        transcriber.onResult = { [weak self] text, isFinal in
            DispatchQueue.main.async {
                guard let self, self.transcriberGeneration == generation else { return }
                self.handleResult(text: text, isFinal: isFinal)
            }
        }
        transcriber.onError = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.transcriberGeneration == generation else { return }
                self.cancelCurrentSession()
                let detail = error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
                let shortDetail = detail.replacingOccurrences(of: "SiliconFlow ", with: "")
                self.indicator.show(.error, text: "转写失败：\(shortDetail)")
                self.statusBar.update(isRecording: false)
                log("语音识别错误：\(detail)")
            }
        }
    }

    func showSettings() {
        log("显示设置窗口。")
        DispatchQueue.main.async { [weak self] in
            self?.presentSettingsWindow()
        }
    }

    private func presentSettingsWindow() {
        if let window = settingsWindow?.window {
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        let controller = SettingsWindowController(
            preferences: preferences,
            onSave: { [weak self] preferences in
                self?.apply(preferences: preferences)
            }
        )
        controller.onOpenUsageStats = { [weak self] in self?.showUsageStats() }
        controller.onOpenVocab = { [weak self] in self?.showVocab() }
        settingsWindow = controller
        controller.window?.center()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func apply(preferences: VoicePreferences) {
        do {
            try preferencesSaver(preferences)
            self.preferences = preferences
            autoSubmitCoordinator.update(
                enabled: preferences.autoSubmitEnabled,
                delaySeconds: preferences.autoSubmitDelaySeconds
            )
            releaseHoldTime = VoicePreferences.normalizedReleaseHoldSeconds(preferences.releaseHoldSeconds)
            celebration.pack = CelebrationPack.resolve(preferences.celebrationPackID)
            hotkey.update(shortcut: preferences.shortcut)
            cancelCurrentSession()
            transcriber = transcriberFactory(preferences)
            bindTranscriberCallbacks()
            transcriptionRouter = VoiceTranscriptionRouter(
                aliases: preferences.aliases,
                injector: injector,
                indicator: indicator,
                corrections: { CustomVocabulary.load().corrections },
                knownTerms: Self.contextualCorrectionTerms,
                contextualCorrector: Self.makeContextualCorrector(
                    preferences,
                    usageStatsRecorder: self.usageStatsRecorder
                )
            )
            bindTranscriptionRouterCallbacks()
            log("设置已保存：快捷键 \(preferences.shortcut.displayName)，口令 \(preferences.aliases.count) 条。")
        } catch {
            log("无法保存设置：\(error.localizedDescription)")
        }
    }

    private func cancelCurrentSession() {
        releaseHoldWorkItem?.cancel()
        releaseHoldWorkItem = nil
        autoSubmitCoordinator.cancelPending()
        isRecording = false
        recordingGeneration &+= 1
        transcriber.cancel()
        indicator.hide()
        statusBar.update(isRecording: false)
        transcriptionRouter.cancelRecording()
    }

    private func bindTranscriptionRouterCallbacks() {
        let autoSubmitCoordinator = self.autoSubmitCoordinator
        let usageStatsRecorder = self.usageStatsRecorder
        transcriptionRouter.onFinalCommit = { [weak autoSubmitCoordinator, weak usageStatsRecorder] text in
            autoSubmitCoordinator?.scheduleAfterCommit(text: text)
            do {
                try usageStatsRecorder?.recordTranscriptionCommitted(text: text, at: Date())
            } catch {
                log("无法写入转写统计：\(error.localizedDescription)")
            }
        }
    }

    private static func makeContextualCorrector(
        _ preferences: VoicePreferences,
        usageStatsRecorder: (any UsageStatsRecording)?
    ) -> ContextualTranscriptionCorrecting? {
        guard preferences.contextualCorrectionEnabled,
              !preferences.deepSeek.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return DeepSeekContextualTranscriptionCorrector(settings: preferences.deepSeek) { [weak usageStatsRecorder] succeeded, rewriteCount in
            DispatchQueue.main.async {
                do {
                    try usageStatsRecorder?.recordDeepSeekCorrection(
                        succeeded: succeeded,
                        rewriteCount: rewriteCount,
                        at: Date()
                    )
                } catch {
                    log("无法写入 DeepSeek 纠错统计：\(error.localizedDescription)")
                }
            }
        }
    }

    private static func contextualCorrectionTerms() -> [String] {
        let vocabulary = CustomVocabulary.load()
        let hotwords = vocabulary.hotwords.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.prefix(80).map(\.key)
        return Array(Set(hotwords + Array(vocabulary.corrections.values)))
    }

    private func recordUsage(_ action: (any UsageStatsRecording) throws -> Void) {
        guard let usageStatsRecorder else { return }
        do {
            try action(usageStatsRecorder)
        } catch {
            log("无法写入使用统计：\(error.localizedDescription)")
        }
    }

    func showUsageStats() {
        log("打开使用统计。")
        DispatchQueue.main.async { [weak self] in
            self?.presentWeb(path: "/stats/")
        }
    }

    func showVocab() {
        log("打开自定义热词。")
        DispatchQueue.main.async { [weak self] in
            self?.presentWeb(path: "/vocab/")
        }
    }

    private func presentWeb(path: String) {
        if let launcher = webLauncher, launcher.port != nil {
            launcher.openInBrowser(path: path)
            return
        }

        let scriptPath: String = {
            if let bundlePath = Bundle.main.url(forResource: "web-server", withExtension: "py")?.path,
               FileManager.default.fileExists(atPath: bundlePath) {
                return bundlePath
            }
            let cwd = FileManager.default.currentDirectoryPath
            let cwdScript = "\(cwd)/scripts/web-server.py"
            if FileManager.default.fileExists(atPath: cwdScript) {
                return cwdScript
            }
            if let projectDir = ProcessInfo.processInfo.environment["CODECX_STT_PROJECT"] {
                let envScript = "\(projectDir)/macos-voice/scripts/web-server.py"
                if FileManager.default.fileExists(atPath: envScript) {
                    return envScript
                }
            }
            return cwdScript
        }()

        log("Web 脚本路径：\(scriptPath)")
        let launcher = WebLauncher(pythonScriptPath: scriptPath)
        guard launcher.start() != nil else {
            log("无法启动 Web 服务器")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "无法打开"
            alert.informativeText = "本地服务启动失败。请确认已安装 Python 3，并查看 /private/tmp/codex-voice-hotkey.log。"
            alert.addButton(withTitle: "知道了")
            alert.runModal()
            return
        }
        webLauncher = launcher
        launcher.openInBrowser(path: path)
    }
}

func runApp() {
        let lockURL = URL(fileURLWithPath: "/private/tmp/com.codex.voice-hotkey.lock")
        guard let singleInstanceLock = StartupGate.acquire(
            bundleIdentifier: "local.climc.app",
            lockURL: lockURL,
            lockProvider: SingleInstanceLock.acquire(at:),
            activator: { bundleIdentifier in
                log("检测到已有 cliMC 实例，正在激活它。")
                StartupGate.activateRunningInstance(bundleIdentifier: bundleIdentifier)
            },
            requestShowSettings: {
                log("请求已有 cliMC 实例显示设置窗口。")
                LaunchCommandCenter.requestShowSettings()
            }
        ) else {
            return
        }

    _ = singleInstanceLock
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

runApp()
