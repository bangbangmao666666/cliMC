import XCTest
@testable import CodexVoiceHotkey

/// 庆祝包仅包含内置 Unicode emoji 或文本颜文字。
final class CelebrationPackModelTests: XCTestCase {

    func testLegacyImagePackIDsFallBackToDefault() {
        XCTAssertEqual(CelebrationPack.resolve("twemoji"), .default)
        XCTAssertEqual(CelebrationPack.resolve("memes"), .default)
    }

    func testTextPackRoundTripsThroughJSON() throws {
        let pack = CelebrationPack(id: "t", displayName: "文字", emojis: ["🐱"])
        let data = try JSONEncoder().encode(pack)
        let decoded = try JSONDecoder().decode(CelebrationPack.self, from: data)

        XCTAssertEqual(decoded, pack)
    }
}
