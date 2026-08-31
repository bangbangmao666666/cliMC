import XCTest
@testable import CodexVoiceHotkey

final class SubmissionCelebrationTests: XCTestCase {
    func testBuiltinPacksIncludeClassicAnimeAndKaomoji() {
        let ids = CelebrationPack.builtins.map(\.id)
        XCTAssertEqual(ids, ["classic", "anime", "kaomoji"])
    }

    func testEveryBuiltinPackHasNonEmptyEmojis() {
        for pack in CelebrationPack.builtins {
            XCTAssertFalse(pack.emojis.isEmpty, "\(pack.id) 不应为空")
        }
    }

    func testClassicPackKeepsOriginalFestiveEmojis() {
        XCTAssertEqual(
            CelebrationPack.classic.emojis,
            ["🥳", "🎉", "🎊", "😄", "🤩"]
        )
    }

    func testAnimePackKeepsTheSixteenTrendyEmojis() {
        XCTAssertEqual(
            CelebrationPack.anime.emojis,
            [
                "✨", "🌸", "🎀", "💖",
                "🌟", "🧸", "🎁", "🍭",
                "🦄", "🐰", "💫", "🌈",
                "🍡", "💕", "🐾", "🎵"
            ]
        )
    }

    func testKaomojiPackUsesTextFaces() {
        XCTAssertTrue(CelebrationPack.kaomoji.emojis.contains("(≧▽≦)"))
        XCTAssertTrue(CelebrationPack.kaomoji.emojis.contains("(´･ω･`)"))
    }

    func testDefaultPackIsAnime() {
        XCTAssertEqual(CelebrationPack.default.id, "anime")
    }

    func testResolveFallsBackToDefaultForUnknownID() {
        XCTAssertEqual(CelebrationPack.resolve("nonsense").id, "anime")
    }

    func testResolveUnknownLegacyCustomPackFallsBackToDefault() {
        XCTAssertEqual(CelebrationPack.resolve("downloaded-cats"), .default)
    }

    func testCelebrationDefaultsToAnimePack() {
        let celebration = SubmissionCelebration(indexSelector: { _ in 1 })

        XCTAssertEqual(celebration.nextEmoji(), "🌸")
    }

    func testCelebrationCanUseClassicPack() {
        let celebration = SubmissionCelebration(
            pack: .classic,
            indexSelector: { _ in 0 }
        )

        XCTAssertEqual(celebration.nextEmoji(), "🥳")
    }

    func testCelebrationCanUseKaomojiPack() {
        let celebration = SubmissionCelebration(
            pack: .kaomoji,
            indexSelector: { _ in 2 }
        )

        XCTAssertEqual(celebration.nextEmoji(), CelebrationPack.kaomoji.emojis[2])
    }

    func testCelebrationReflectsLivePackSwap() {
        let celebration = SubmissionCelebration(indexSelector: { _ in 0 })
        XCTAssertEqual(celebration.nextEmoji(), "✨")

        celebration.pack = .classic
        XCTAssertEqual(celebration.nextEmoji(), "🥳")
    }

    func testTextPackNextReturnsTwoEntriesInSelectorOrder() {
        var nextIndex = 0
        let celebration = SubmissionCelebration(
            pack: .anime,
            indexSelector: { _ in
                defer { nextIndex += 1 }
                return nextIndex % 2
            }
        )

        XCTAssertEqual(
            celebration.next(),
            ["✨", "🌸"]
        )
    }
}
