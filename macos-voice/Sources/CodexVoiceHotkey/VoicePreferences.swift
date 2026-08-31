import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct VoiceShortcut: Codable, Equatable {
    let keyCode: Int64
    let modifierRawValue: UInt64
    let keyName: String

    static let commandR = VoiceShortcut(keyCode: Int64(kVK_ANSI_R), modifiers: [.maskCommand], keyName: "R")
    static let commandShiftR = VoiceShortcut(keyCode: Int64(kVK_ANSI_R), modifiers: [.maskCommand, .maskShift], keyName: "R")
    static let controlOptionR = VoiceShortcut(keyCode: Int64(kVK_ANSI_R), modifiers: [.maskControl, .maskAlternate], keyName: "R")
    static let optionR = VoiceShortcut(keyCode: Int64(kVK_ANSI_R), modifiers: [.maskAlternate], keyName: "R")
    static let optionE = VoiceShortcut(keyCode: Int64(kVK_ANSI_E), modifiers: [.maskAlternate], keyName: "E")
    static let commandPeriod = VoiceShortcut(keyCode: Int64(kVK_ANSI_Period), modifiers: [.maskCommand], keyName: ".")

    init(keyCode: Int64, modifiers: CGEventFlags, keyName: String) {
        self.keyCode = keyCode
        self.modifierRawValue = modifiers.rawValue
        self.keyName = keyName
    }

    private init(keyCode: Int64, modifierRawValue: UInt64, keyName: String) {
        self.keyCode = keyCode
        self.modifierRawValue = modifierRawValue
        self.keyName = keyName
    }

    var modifiers: CGEventFlags { CGEventFlags(rawValue: modifierRawValue) }

    var displayName: String {
        let symbols: [(CGEventFlags, String)] = [(.maskAlternate, "⌥"), (.maskCommand, "⌘"), (.maskControl, "⌃"), (.maskShift, "⇧")]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + keyName
    }

    func matches(_ flags: CGEventFlags) -> Bool {
        let relevant = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        return relevant == modifiers
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            switch value {
            case "commandR": self = .commandR
            case "commandShiftR": self = .commandShiftR
            case "controlOptionR": self = .controlOptionR
            case "optionR": self = .optionR
            case "optionE": self = .optionE
            case "commandPeriod": self = .commandPeriod
            default: throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "未知快捷键")
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            keyCode: try container.decode(Int64.self, forKey: .keyCode),
            modifierRawValue: try container.decode(UInt64.self, forKey: .modifierRawValue),
            keyName: try container.decode(String.self, forKey: .keyName)
        )
    }

    private enum CodingKeys: String, CodingKey { case keyCode, modifierRawValue, keyName }
}

enum VoiceTranscriptionProvider: String, Codable, Equatable, CaseIterable {
    case siliconFlow
    case volcengine
    case system

    var displayName: String {
        switch self {
        case .siliconFlow: "硅基流动（非实时）"
        case .volcengine: "火山引擎 ASR（实时）"
        case .system: "系统语音识别"
        }
    }

    var featureDescription: String {
        switch self {
        case .system: "实时显示识别结果；使用 macOS 本机能力，无需 API Key，但准确率相对较低。"
        case .siliconFlow: "松开快捷键后上传整段录音；识别准确率较好，但不实时，会有短暂等待。"
        case .volcengine: "新版火山引擎 ASR 2.0；只需配置新版 API Key（X-Api-Key），无需 AppKey/AccessKey。"
        }
    }
}

struct SiliconFlowSettings: Codable, Equatable {
    var apiKey: String
    init(apiKey: String) { self.apiKey = apiKey }
    static let baseURL = "https://api.siliconflow.cn/v1"
    static let model = "FunAudioLLM/SenseVoiceSmall"
    static let `default` = SiliconFlowSettings(apiKey: "")
}

struct VoicePreferences: Codable, Equatable {
    var shortcut: VoiceShortcut
    var aliases: [String: String]
    var transcriptionProvider: VoiceTranscriptionProvider
    var siliconFlow: SiliconFlowSettings
    var volcengineAppKey: String
    var volcengineAccessKey: String
    var volcengineAPIKey: String
    var autoSubmitEnabled: Bool
    var autoSubmitDelaySeconds: Int
    var releaseHoldSeconds: Double
    var celebrationPackID: String

    private enum CodingKeys: String, CodingKey {
        case shortcut
        case aliases
        case transcriptionProvider
        case siliconFlow
        case volcengineAppKey
        case volcengineAccessKey
        case volcengineAPIKey
        case autoSubmitEnabled
        case autoSubmitDelaySeconds
        case releaseHoldSeconds
        case celebrationPackID
        case remoteSTT
    }

    static let `default` = VoicePreferences(
        shortcut: .optionE,
        aliases: AliasStore.defaults,
        transcriptionProvider: .siliconFlow,
        siliconFlow: .default,
        volcengineAppKey: "",
        volcengineAccessKey: "",
        volcengineAPIKey: "",
        autoSubmitEnabled: false,
        autoSubmitDelaySeconds: 5,
        releaseHoldSeconds: 2.5,
        celebrationPackID: "anime"
    )

    init(
        shortcut: VoiceShortcut,
        aliases: [String: String],
        transcriptionProvider: VoiceTranscriptionProvider = .siliconFlow,
        siliconFlow: SiliconFlowSettings = .default,
        volcengineAppKey: String = "",
        volcengineAccessKey: String = "",
        volcengineAPIKey: String = "",
        autoSubmitEnabled: Bool = false,
        autoSubmitDelaySeconds: Int = 5,
        releaseHoldSeconds: Double = 2.5,
        celebrationPackID: String = "anime"
    ) {
        self.shortcut = shortcut
        self.aliases = aliases
        self.transcriptionProvider = transcriptionProvider
        self.siliconFlow = siliconFlow
        self.volcengineAppKey = volcengineAppKey
        self.volcengineAccessKey = volcengineAccessKey
        self.volcengineAPIKey = volcengineAPIKey
        self.autoSubmitEnabled = autoSubmitEnabled
        self.autoSubmitDelaySeconds = Self.normalizedAutoSubmitDelay(autoSubmitDelaySeconds)
        self.releaseHoldSeconds = Self.normalizedReleaseHoldSeconds(releaseHoldSeconds)
        self.celebrationPackID = celebrationPackID
    }

    static func normalizedAutoSubmitDelay(_ seconds: Int) -> Int {
        min(max(seconds, 1), 60)
    }

    static func normalizedReleaseHoldSeconds(_ seconds: Double) -> Double {
        min(max(seconds, 0), 10)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcut = try container.decodeIfPresent(VoiceShortcut.self, forKey: .shortcut) ?? .optionE
        let decodedAliases = try container.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        aliases = AliasStore.defaults.merging(decodedAliases) { _, new in new }
        if let rawProvider = try container.decodeIfPresent(String.self, forKey: .transcriptionProvider) {
            transcriptionProvider = rawProvider == "remote"
                ? .siliconFlow
                : (VoiceTranscriptionProvider(rawValue: rawProvider) ?? .siliconFlow)
        } else {
            transcriptionProvider = .siliconFlow
        }
        if let settings = try container.decodeIfPresent(SiliconFlowSettings.self, forKey: .siliconFlow) {
            siliconFlow = settings
        } else if let legacy = try container.decodeIfPresent(LegacyRemoteSTTSettings.self, forKey: .remoteSTT) {
            siliconFlow = SiliconFlowSettings(apiKey: legacy.apiKey)
        } else {
            siliconFlow = .default
        }
        volcengineAppKey = try container.decodeIfPresent(String.self, forKey: .volcengineAppKey) ?? ""
        volcengineAccessKey = try container.decodeIfPresent(String.self, forKey: .volcengineAccessKey)
            ?? ""
        volcengineAPIKey = try container.decodeIfPresent(String.self, forKey: .volcengineAPIKey) ?? ""
        autoSubmitEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoSubmitEnabled) ?? false
        autoSubmitDelaySeconds = Self.normalizedAutoSubmitDelay(
            try container.decodeIfPresent(Int.self, forKey: .autoSubmitDelaySeconds) ?? 5
        )
        releaseHoldSeconds = Self.normalizedReleaseHoldSeconds(
            try container.decodeIfPresent(Double.self, forKey: .releaseHoldSeconds) ?? 2.5
        )
        celebrationPackID = try container.decodeIfPresent(String.self, forKey: .celebrationPackID) ?? "anime"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shortcut, forKey: .shortcut)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(transcriptionProvider, forKey: .transcriptionProvider)
        try container.encode(siliconFlow, forKey: .siliconFlow)
        try container.encode(volcengineAppKey, forKey: .volcengineAppKey)
        try container.encode(volcengineAccessKey, forKey: .volcengineAccessKey)
        try container.encode(volcengineAPIKey, forKey: .volcengineAPIKey)
        try container.encode(autoSubmitEnabled, forKey: .autoSubmitEnabled)
        try container.encode(autoSubmitDelaySeconds, forKey: .autoSubmitDelaySeconds)
        try container.encode(releaseHoldSeconds, forKey: .releaseHoldSeconds)
        try container.encode(celebrationPackID, forKey: .celebrationPackID)
    }
}

private struct LegacyRemoteSTTSettings: Codable {
    var apiKey: String
}

enum VoicePreferencesStore {
    static var baseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/codex-voice", isDirectory: true)
    }

    private static var directory: URL { baseDirectory }

    private static var settingsFile: URL {
        directory.appendingPathComponent("settings.json")
    }

    private static var legacyAliasesFile: URL {
        directory.appendingPathComponent("aliases.json")
    }

    static func load() -> VoicePreferences {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: settingsFile.path) {
                return try JSONDecoder().decode(VoicePreferences.self, from: Data(contentsOf: settingsFile))
            }
            var preferences = VoicePreferences.default
            if FileManager.default.fileExists(atPath: legacyAliasesFile.path) {
                preferences.aliases = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: legacyAliasesFile))
            }
            try save(preferences)
            return preferences
        } catch {
            fputs("无法读取语音设置：\(error)。将使用默认值。\n", stderr)
            return .default
        }
    }

    static func save(_ preferences: VoicePreferences) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(preferences)
        try data.write(to: settingsFile, options: .atomic)
    }
}
