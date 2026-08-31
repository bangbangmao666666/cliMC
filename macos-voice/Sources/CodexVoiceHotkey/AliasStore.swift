import Foundation

struct AliasStore {
    static let defaults = [
        "目标": "/goal",
        "新对话": "/new",
        "压缩": "/compact",
        "清屏": "/clear",
    ]

    let aliases: [String: String]

    init(aliases: [String: String] = AliasStore.defaults) {
        self.aliases = AliasStore.defaults.merging(aliases) { _, new in new }
    }

    func resolve(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return aliases[trimmed] ?? text
    }

    static func loadOrCreate() -> AliasStore {
        AliasStore(aliases: VoicePreferencesStore.load().aliases)
    }
}
