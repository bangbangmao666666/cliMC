import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum HotkeyAction: Equatable {
    case none
    case consume
    case press
    case release
}

struct HotkeyState {
    private var isHeld = false
    let shortcut: VoiceShortcut

    init(shortcut: VoiceShortcut = .optionE) {
        self.shortcut = shortcut
    }

    mutating func transition(keyCode: Int64, isKeyDown: Bool, modifierFlags: CGEventFlags) -> HotkeyAction {
        guard keyCode == shortcut.keyCode else { return .none }
        if isKeyDown {
            guard shortcut.matches(modifierFlags) else { return .none }
            if isHeld { return .consume }
            isHeld = true
            return .press
        }
        if !isKeyDown, isHeld {
            isHeld = false
            return .release
        }
        return .none
    }

    mutating func modifiersChanged(_ modifierFlags: CGEventFlags) -> HotkeyAction {
        guard isHeld else { return .none }
        let required = shortcut.modifiers
        guard modifierFlags.contains(required) else {
            isHeld = false
            return .release
        }
        return .none
    }
}

final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onUserActivity: (() -> Void)?
    var onStatus: ((String) -> Void)?

    private var eventTap: CFMachPort?
    private var source: CFRunLoopSource?
    private var state: HotkeyState

    init(shortcut: VoiceShortcut = .optionE) {
        state = HotkeyState(shortcut: shortcut)
    }

    func update(shortcut: VoiceShortcut) {
        state = HotkeyState(shortcut: shortcut)
    }

    @discardableResult
    func start() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let accessibilityOptions = [promptKey: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(accessibilityOptions) {
            onStatus?("已请求“辅助功能”权限。请在系统设置中打开 cliMC 的开关，然后重新启动助手。")
        }

        if #available(macOS 10.15, *), !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
            onStatus?("已请求“输入监控”权限。请在系统弹窗中允许 cliMC，然后重新启动助手。")
            return false
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: context
        )
        guard let eventTap else {
            onStatus?("无法建立全局快捷键：请确认已允许“输入监控”和“辅助功能”权限。")
            return false
        }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        onStatus?("全局热键已就绪：按住 \(state.shortcut.displayName) 说话。")
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            onStatus?("全局热键被 macOS 暂停，现已自动恢复。")
            return Unmanaged.passUnretained(event)
        }
        let marker = event.getIntegerValueField(.eventSourceUserData)
        if InputActivityClassifier.shouldNotify(type: type, marker: marker) {
            onUserActivity?()
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            return Unmanaged.passUnretained(event)
        }
        let action: HotkeyAction
        if type == .flagsChanged {
            action = state.modifiersChanged(event.flags)
        } else {
            action = state.transition(
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                isKeyDown: type == .keyDown,
                modifierFlags: event.flags
            )
        }
        switch action {
        case .consume:
            return nil
        case .press:
            onPress?()
            return nil
        case .release:
            onRelease?()
            return nil
        case .none:
            return Unmanaged.passUnretained(event)
        }
    }
}
