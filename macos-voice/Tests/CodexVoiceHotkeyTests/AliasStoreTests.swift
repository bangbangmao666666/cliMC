import XCTest
@testable import CodexVoiceHotkey

final class AliasStoreTests: XCTestCase {
    func testExpandsOnlyExactAlias() {
        let store = AliasStore(aliases: ["目标": "/goal", "新对话": "/new"])

        XCTAssertEqual(store.resolve("  目标  "), "/goal")
        XCTAssertEqual(store.resolve("目标是修复登录问题"), "目标是修复登录问题")
    }

    func testDefaultExamplesRemainAvailableWhenCustomAliasesAreEmpty() {
        let store = AliasStore(aliases: [:])

        XCTAssertEqual(store.resolve("目标"), "/goal")
        XCTAssertEqual(store.resolve("新对话"), "/new")
        XCTAssertEqual(store.resolve("压缩"), "/compact")
        XCTAssertEqual(store.resolve("清屏"), "/clear")
    }
}
