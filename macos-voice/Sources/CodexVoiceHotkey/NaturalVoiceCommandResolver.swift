import Foundation

struct NaturalVoiceCommandResolver {
    private struct CommandGroup {
        let canonicalAlias: String
        let expectedCommand: String
        let expressions: Set<String>
    }

    private static let groups = [
        CommandGroup(
            canonicalAlias: "新对话",
            expectedCommand: "/new",
            expressions: [
                "新对话",
                "新建对话",
                "新建一个对话",
                "新开一个对话",
                "开始新对话",
                "重新开个对话",
                "帮我新建一个对话",
            ]
        ),
        CommandGroup(
            canonicalAlias: "压缩",
            expectedCommand: "/compact",
            expressions: [
                "压缩",
                "压缩一下",
                "压缩上下文",
                "压缩一下上下文",
                "帮我压缩上下文",
            ]
        ),
        CommandGroup(
            canonicalAlias: "目标",
            expectedCommand: "/goal",
            expressions: [
                "目标",
                "设置目标",
                "设定目标",
                "创建目标",
                "帮我设置目标",
            ]
        ),
        CommandGroup(
            canonicalAlias: "清屏",
            expectedCommand: "/clear",
            expressions: [
                "清屏",
                "清屏一下",
                "清除屏幕",
                "帮我清屏",
            ]
        ),
    ]

    private let aliases: [String: String]

    init(aliases: [String: String]) {
        self.aliases = aliases
    }

    func resolve(_ text: String) -> String? {
        let candidate = Self.normalize(text)
        guard !candidate.isEmpty else { return nil }
        if let exactCommand = aliases[candidate] {
            return exactCommand
        }

        for group in Self.groups
        where aliases[group.canonicalAlias] == group.expectedCommand
            && group.expressions.contains(candidate) {
            return group.expectedCommand
        }
        return nil
    }

    private static func normalize(_ text: String) -> String {
        let withoutWhitespace = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined()
        let trailingPunctuation = CharacterSet(charactersIn: "。！？!?，,、；;：:…")
        var normalized = withoutWhitespace
        while let lastScalar = normalized.unicodeScalars.last,
              trailingPunctuation.contains(lastScalar) {
            normalized.removeLast()
        }
        return normalized
    }
}
