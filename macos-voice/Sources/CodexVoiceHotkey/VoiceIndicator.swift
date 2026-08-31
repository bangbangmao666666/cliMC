import AppKit
import CoreGraphics

enum VoiceIndicatorState {
    case hidden
    case waitingForAudio
    case listening
    case transcribing
    case countdown
    case submitted
    case error

    var label: String {
        switch self {
        case .hidden: ""
        case .waitingForAudio: "正在等待麦克风音频"
        case .listening: "正在录音"
        case .transcribing: "正在转写"
        case .countdown: ""
        case .submitted: ""
        case .error: "转写失败"
        }
    }
}

enum VoiceIndicatorBarColor: Equatable {
    case recording
    case transcribing
}

enum VoiceIndicatorVisualStyle: Equatable {
    case none
    case levelBars(color: VoiceIndicatorBarColor, animated: Bool)
    case statusText(color: VoiceIndicatorBarColor)
    case errorText
}

extension VoiceIndicatorState {
    var visualStyle: VoiceIndicatorVisualStyle {
        switch self {
        case .hidden:
            return .none
        case .waitingForAudio, .listening:
            return .levelBars(color: .recording, animated: false)
        case .transcribing:
            return .levelBars(color: .transcribing, animated: true)
        case .countdown, .submitted:
            return .statusText(color: .transcribing)
        case .error:
            return .errorText
        }
    }
}

enum LevelBarGeometry {
    static let barCount = 7
    static let minimumHeight: CGFloat = 8
    static let maximumHeight: CGFloat = 30

    static func sanitizedLevels(_ rawLevels: [Double]) -> [Double] {
        (0..<barCount).map { index in
            guard rawLevels.indices.contains(index), rawLevels[index].isFinite else {
                return 0
            }
            return min(max(rawLevels[index], 0), 1)
        }
    }

    static func heights(for rawLevels: [Double]) -> [CGFloat] {
        let availableHeight = maximumHeight - minimumHeight
        return sanitizedLevels(rawLevels).map {
            minimumHeight + availableHeight * CGFloat($0)
        }
    }
}

struct VoiceLevelSmoother {
    private static let expansionExponent = 0.65
    private static let deadband = 0.035
    private static let attackFactor = 0.90
    private static let releaseFactor = 0.25

    private(set) var displayedLevel: Double

    init(initialLevel: Double = 0) {
        displayedLevel = Self.sanitized(initialLevel)
    }

    static func expandedLevel(for rawLevel: Double) -> Double {
        pow(sanitized(rawLevel), expansionExponent)
    }

    mutating func update(to rawTarget: Double) -> Double {
        let target = Self.expandedLevel(for: rawTarget)
        guard abs(target - displayedLevel) >= Self.deadband else {
            return displayedLevel
        }
        let factor = target > displayedLevel ? Self.attackFactor : Self.releaseFactor
        displayedLevel += (target - displayedLevel) * factor
        return displayedLevel
    }

    mutating func reset() {
        displayedLevel = 0
    }

    private static func sanitized(_ rawLevel: Double) -> Double {
        guard rawLevel.isFinite else { return 0 }
        return min(max(rawLevel, 0), 1)
    }
}

struct VoiceSpectrumSmoother {
    private(set) var smoothers: [VoiceLevelSmoother]

    var displayedLevels: [Double] {
        smoothers.map(\.displayedLevel)
    }

    init(initialLevels: [Double] = []) {
        smoothers = LevelBarGeometry.sanitizedLevels(initialLevels).map {
            VoiceLevelSmoother(initialLevel: $0)
        }
    }

    mutating func update(to rawLevels: [Double]) -> [Double] {
        let targets = LevelBarGeometry.sanitizedLevels(rawLevels)
        return smoothers.indices.map { smoothers[$0].update(to: targets[$0]) }
    }

    mutating func reset() {
        for index in smoothers.indices {
            smoothers[index].reset()
        }
    }
}

final class VoiceIndicator {
    private let normalSize = NSSize(width: 72, height: 36)
    private let celebrationSize = NSSize(width: 96, height: 56)
    private let errorSize = NSSize(width: 260, height: 36)
    private let panel: NSPanel
    private let content: VoiceIndicatorContentView

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: normalSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        content = VoiceIndicatorContentView(frame: NSRect(origin: .zero, size: normalSize))
        panel.contentView = content
    }

    func show(_ state: VoiceIndicatorState, text: String? = nil) {
        guard state != .hidden else {
            hide()
            return
        }
        let size: NSSize
        if state == .error {
            size = errorSize
        } else if state == .submitted {
            size = celebrationSize
        } else {
            size = normalSize
        }
        panel.setFrame(NSRect(origin: preferredOrigin(for: size), size: size), display: true)
        content.frame = NSRect(origin: .zero, size: size)
        content.apply(state, text: text)
        panel.orderFrontRegardless()
    }

    func updateLevel(_ level: Double) {
        updateSpectrum([Double](repeating: level, count: LevelBarGeometry.barCount))
    }

    func updateSpectrum(_ levels: [Double]) {
        let update: () -> Void = { [weak self] in
            self?.content.updateSpectrum(levels)
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    func hide() {
        content.apply(.hidden, text: nil)
        panel.orderOut(nil)
    }

    var panelFrameSizeForTesting: NSSize { panel.frame.size }

    private func preferredOrigin(for size: NSSize) -> NSPoint {
        let inset: CGFloat = 16
        let frame = terminalWindowFrame() ?? NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(
            x: frame.maxX - size.width - inset,
            y: frame.minY + inset
        )
    }

    private func terminalWindowFrame() -> NSRect? {
        guard let terminal = NSWorkspace.shared.frontmostApplication,
              terminal.bundleIdentifier == "com.apple.Terminal",
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]],
              let window = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == terminal.processIdentifier &&
                  ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
              }),
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              var cgFrame = CGRect(dictionaryRepresentation: bounds)
        else {
            return nil
        }

        let desktopHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? cgFrame.maxY
        cgFrame.origin.y = desktopHeight - cgFrame.maxY
        return cgFrame
    }
}

extension VoiceIndicator: VoiceIndicatorPresenting {}

final class VoiceIndicatorContentView: NSView {
    private let barLayers = (0..<7).map { _ in CALayer() }
    private let label = NSTextField(labelWithString: "")
    private let textGrid = NSView()
    private let gridLabels = (0..<2).map { _ in NSTextField(labelWithString: "") }
    private var currentState: VoiceIndicatorState = .hidden
    private var spectrumSmoother = VoiceSpectrumSmoother()

    /// 供测试读取：当前是否在展示文字。
    var isDisplayingText: Bool { !label.isHidden || !textGrid.isHidden }
    var displayedGridTexts: [String] {
        textGrid.isHidden ? [] : gridLabels.map(\.stringValue)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.93).cgColor
        layer?.cornerRadius = 18

        for bar in barLayers {
            bar.cornerRadius = LevelBarGeometry.minimumHeight / 2
            layer?.addSublayer(bar)
        }

        label.textColor = .labelColor
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.wantsLayer = true
        label.isHidden = true
        addSubview(label)

        textGrid.wantsLayer = true
        textGrid.isHidden = true
        addSubview(textGrid)
        for gridLabel in gridLabels {
            gridLabel.textColor = .labelColor
            gridLabel.alignment = .center
            gridLabel.lineBreakMode = .byTruncatingTail
            textGrid.addSubview(gridLabel)
        }

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 8, y: 5, width: bounds.width - 16, height: 26)
        let gridInset: CGFloat = 8
        let cellWidth = (bounds.width - gridInset * 2) / 2
        let cellHeight = bounds.height - gridInset * 2
        textGrid.frame = NSRect(
            x: gridInset,
            y: gridInset,
            width: bounds.width - gridInset * 2,
            height: cellHeight
        )
        for (index, gridLabel) in gridLabels.enumerated() {
            gridLabel.frame = NSRect(
                x: CGFloat(index) * cellWidth,
                y: 0,
                width: cellWidth,
                height: cellHeight
            )
        }
        if currentState != .transcribing {
            setBarHeights(LevelBarGeometry.heights(for: spectrumSmoother.displayedLevels))
        }
    }

    func apply(_ state: VoiceIndicatorState, text: String? = nil) {
        if state == currentState {
            if state == .error {
                updateErrorLabel(text)
            } else if state == .countdown {
                updateStatusLabel(text)
            } else if state == .submitted {
                applySubmittedContent(text: text)
            }
            return
        }

        currentState = state
        stopBarAnimations()
        spectrumSmoother.reset()

        switch state.visualStyle {
        case .none:
            label.isHidden = true
            clearTextGrid()
            if let labelLayer = label.layer {
                labelLayer.removeAnimation(forKey: "celebrationPop")
                labelLayer.transform = CATransform3DIdentity
            }
            setBarsHidden(true)
        case .levelBars(let color, let animated):
            label.isHidden = true
            clearTextGrid()
            setBarsHidden(false)
            setBarColor(color)
            setBarHeights(LevelBarGeometry.heights(for: []))
            if animated {
                startTranscribingAnimation()
            }
        case .statusText(let color):
            setBarsHidden(true)
            label.textColor = color == .transcribing ? .systemIndigo : .systemRed
            label.font = .systemFont(ofSize: 22, weight: .semibold)
            if state == .submitted {
                applySubmittedContent(text: text)
                playCelebrationPop()
            } else {
                clearTextGrid()
                label.isHidden = false
                updateStatusLabel(text)
            }
        case .errorText:
            setBarsHidden(true)
            clearTextGrid()
            label.isHidden = false
            label.textColor = .labelColor
            label.font = .systemFont(ofSize: 13, weight: .medium)
            updateErrorLabel(text)
        }
    }

    private func applySubmittedContent(text: String?) {
        label.isHidden = true
        updateTextGrid(text)
    }

    private func updateTextGrid(_ text: String?) {
        let items = text?.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init) ?? Array(repeating: "✨", count: 2)
        let cells = Array((items + Array(repeating: "✨", count: 2)).prefix(2))
        let font: NSFont = cells.contains { $0.unicodeScalars.count > 2 }
            ? .systemFont(ofSize: 12, weight: .medium)
            : .systemFont(ofSize: 28, weight: .semibold)
        for (gridLabel, cell) in zip(gridLabels, cells) {
            gridLabel.stringValue = cell
            gridLabel.font = font
        }
        textGrid.isHidden = false
    }

    private func clearTextGrid() {
        textGrid.isHidden = true
        gridLabels.forEach { $0.stringValue = "" }
        if let gridLayer = textGrid.layer {
            gridLayer.removeAnimation(forKey: "celebrationPop")
            gridLayer.transform = CATransform3DIdentity
        }
    }

    func updateSpectrum(_ rawLevels: [Double]) {
        guard currentState == .listening else { return }
        let displayedLevels = spectrumSmoother.update(to: rawLevels)
        setBarHeights(LevelBarGeometry.heights(for: displayedLevels))
    }

    private func updateErrorLabel(_ text: String?) {
        let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleaned, !cleaned.isEmpty {
            label.stringValue = cleaned
        } else {
            label.stringValue = VoiceIndicatorState.error.label
        }
    }

    private func updateStatusLabel(_ text: String?) {
        label.stringValue = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func setBarColor(_ color: VoiceIndicatorBarColor) {
        let nsColor: NSColor = color == .recording ? .systemRed : .systemIndigo
        barLayers.forEach { $0.backgroundColor = nsColor.cgColor }
    }

    private func setBarsHidden(_ hidden: Bool) {
        barLayers.forEach { $0.isHidden = hidden }
    }

    private func setBarHeights(_ heights: [CGFloat]) {
        let barWidth: CGFloat = 4
        let gap: CGFloat = 4
        let totalWidth = CGFloat(barLayers.count) * barWidth
            + CGFloat(barLayers.count - 1) * gap
        let startX = (bounds.width - totalWidth) / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in barLayers.enumerated() {
            let height = heights[index]
            bar.cornerRadius = min(barWidth / 2, height / 2)
            bar.frame = NSRect(
                x: startX + CGFloat(index) * (barWidth + gap),
                y: (bounds.height - height) / 2,
                width: barWidth,
                height: height
            )
        }
        CATransaction.commit()
    }

    /// 提交瞬间给表情来一个「弹一下 + 轻微摇摆」的庆祝动效，
    /// 让成功反馈更有盲盒拆开的惊喜感。
    private func playCelebrationPop() {
        guard !textGrid.isHidden, let gridLayer = textGrid.layer else { return }
        let size = textGrid.bounds.size
        let cx = size.width / 2
        let cy = size.height / 2
        func transform(scale s: CGFloat, rotation r: CGFloat) -> CATransform3D {
            var t = CATransform3DIdentity
            t = CATransform3DTranslate(t, cx, cy, 0)
            t = CATransform3DRotate(t, r, 0, 0, 1)
            t = CATransform3DScale(t, s, s, 1)
            t = CATransform3DTranslate(t, -cx, -cy, 0)
            return t
        }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = [
            transform(scale: 0.2, rotation: 0),
            transform(scale: 1.22, rotation: -0.12),
            transform(scale: 0.9, rotation: 0.06),
            transform(scale: 1.0, rotation: 0)
        ]
        animation.keyTimes = [0, 0.45, 0.75, 1.0]
        animation.duration = 0.5
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut)
        ]
        animation.fillMode = .forwards
        gridLayer.add(animation, forKey: "celebrationPop")
        gridLayer.transform = transform(scale: 1.0, rotation: 0)
    }

    private func startTranscribingAnimation() {
        let heights: [CGFloat] = [22, 26, 30, 25, 29, 24, 21]
        for (index, bar) in barLayers.enumerated() {
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = 1
            animation.toValue = heights[index] / LevelBarGeometry.minimumHeight
            animation.duration = 0.55
            animation.beginTime = bar.convertTime(CACurrentMediaTime(), from: nil)
                + Double(index) * 0.08
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(animation, forKey: "transcribing")
        }
    }

    private func stopBarAnimations() {
        barLayers.forEach { $0.removeAllAnimations() }
    }
}
