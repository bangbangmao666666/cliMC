import XCTest
@testable import CodexVoiceHotkey

final class NaturalVoiceCommandResolverTests: XCTestCase {
    private let aliases = [
        "新对话": "/new",
        "压缩": "/compact",
        "目标": "/goal",
        "清屏": "/clear",
    ]

    func testResolvesConfiguredNaturalExpressions() {
        let cases: [(String, String)] = [
            ("新对话", "/new"),
            ("新建对话", "/new"),
            ("新建一个对话", "/new"),
            ("新开一个对话", "/new"),
            ("开始新对话", "/new"),
            ("重新开个对话", "/new"),
            ("帮我新建一个对话", "/new"),
            ("压缩", "/compact"),
            ("压缩一下", "/compact"),
            ("压缩上下文", "/compact"),
            ("压缩一下上下文", "/compact"),
            ("帮我压缩上下文", "/compact"),
            ("目标", "/goal"),
            ("设置目标", "/goal"),
            ("设定目标", "/goal"),
            ("创建目标", "/goal"),
            ("帮我设置目标", "/goal"),
            ("清屏", "/clear"),
            ("清屏一下", "/clear"),
            ("清除屏幕", "/clear"),
            ("帮我清屏", "/clear"),
        ]
        let resolver = NaturalVoiceCommandResolver(aliases: aliases)

        for (spoken, expected) in cases {
            XCTAssertEqual(resolver.resolve(spoken), expected, spoken)
        }
    }

    func testNormalizesWhitespaceAndTrailingPunctuationForComparison() {
        let resolver = NaturalVoiceCommandResolver(aliases: aliases)

        XCTAssertEqual(resolver.resolve("  帮我新建一个对话？！  "), "/new")
        XCTAssertEqual(resolver.resolve("压缩 一下 上下文。"), "/compact")
    }

    func testDoesNotStripLeadingPunctuation() {
        let resolver = NaturalVoiceCommandResolver(aliases: aliases)

        XCTAssertNil(resolver.resolve("。新对话"))
    }

    func testDoesNotConvertOrdinarySentences() {
        let resolver = NaturalVoiceCommandResolver(aliases: aliases)

        [
            "目标是修复登录问题",
            "解释一下新对话的匹配逻辑",
            "帮我压缩这段文字",
            "清屏功能是怎么实现的",
        ].forEach { XCTAssertNil(resolver.resolve($0), $0) }
    }

    func testRequiresCanonicalAliasToRemainMappedToExpectedCommand() {
        let resolver = NaturalVoiceCommandResolver(aliases: ["新对话": "/other"])

        XCTAssertNil(resolver.resolve("帮我新建一个对话"))
    }

    func testPreservesExactMatchingForCustomAliases() {
        let resolver = NaturalVoiceCommandResolver(aliases: ["发布": "/publish"])

        XCTAssertEqual(resolver.resolve("发布"), "/publish")
        XCTAssertNil(resolver.resolve("帮我发布"))
    }
}
