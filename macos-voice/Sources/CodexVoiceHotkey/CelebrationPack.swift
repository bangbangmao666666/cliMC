import Foundation

/// 一组提交庆祝表情，仅包含内置 Unicode emoji 或文本颜文字。
struct CelebrationPack: Codable, Equatable {
    let id: String
    let displayName: String
    let emojis: [String]

    static let classic = CelebrationPack(
        id: "classic",
        displayName: "经典派对",
        emojis: ["🥳", "🎉", "🎊", "😄", "🤩"]
    )

    static let anime = CelebrationPack(
        id: "anime",
        displayName: "二次元甜系",
        emojis: [
            "✨", "🌸", "🎀", "💖",
            "🌟", "🧸", "🎁", "🍭",
            "🦄", "🐰", "💫", "🌈",
            "🍡", "💕", "🐾", "🎵"
        ]
    )

    static let kaomoji = CelebrationPack(
        id: "kaomoji",
        displayName: "颜文字",
        emojis: [
            "(≧▽≦)", "(´･ω･`)", "(*^▽^*)", "(｡◕‿‿◕｡)",
            "ヽ(✿ﾟ▽ﾟ)ノ", "(◕ᴗ◕✿)", "(＊◕ᴗ◕＊)", "(〃▽〃)",
            "(✿◡‿◡)", "(⌒‿⌒)", "٩(◕‿◕)۶", "(｡♥‿♥｡)"
        ]
    )

    /// 内置包，按「经典 → 二次元 → 颜文字」固定顺序，保证设置下拉里稳定。
    static let builtins: [CelebrationPack] = [.classic, .anime, .kaomoji]

    /// 默认包：二次元甜系。
    static let `default`: CelebrationPack = .anime

    /// 按 ID 解析内置文字包；历史图片包和未知 ID 都安全回退到默认包。
    static func resolve(_ id: String) -> CelebrationPack {
        for pack in builtins where pack.id == id {
            return pack
        }
        return .default
    }
}

/// 下拉框里展示的内置表情包选项。
/// 第一个永远是 classic，顺序稳定，便于测试与用户认知。
struct CelebrationPackOption: Equatable {
    let pack: CelebrationPack
    let isBuiltIn: Bool

    static func all() -> [CelebrationPackOption] {
        CelebrationPack.builtins.map { CelebrationPackOption(pack: $0, isBuiltIn: true) }
    }
}
