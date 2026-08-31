/// 提交瞬间随机弹出的 Unicode emoji / 颜文字选择器。
final class SubmissionCelebration {
    /// 当前选用的表情包。改为另一个包即可立即生效，无需重建实例。
    var pack: CelebrationPack

    private let indexSelector: (Range<Int>) -> Int

    init(
        pack: CelebrationPack = .default,
        indexSelector: @escaping (Range<Int>) -> Int = { Int.random(in: $0) }
    ) {
        self.pack = pack
        self.indexSelector = indexSelector
    }

    /// 兼容旧测试入口：仅用默认包 + 注入选择器。
    convenience init(indexSelector: @escaping (Range<Int>) -> Int) {
        self.init(pack: .default, indexSelector: indexSelector)
    }

    /// 返回两个文字表情；空包时稳定回退到 sparkle。
    func next() -> [String] {
        (0..<2).map { _ in nextEmoji() }
    }

    func nextEmoji() -> String {
        let emojis = pack.emojis
        guard !emojis.isEmpty else { return "✨" }
        return emojis[indexSelector(emojis.indices)]
    }
}
