import Foundation

struct CustomVocabulary: Codable, Equatable {
    var hotwords: [String: Int]
    var corrections: [String: String]

    init(hotwords: [String: Int], corrections: [String: String] = [:]) {
        self.hotwords = hotwords
        self.corrections = corrections
    }

    private enum CodingKeys: String, CodingKey {
        case hotwords
        case corrections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotwords = try container.decodeIfPresent([String: Int].self, forKey: .hotwords) ?? [:]
        corrections = try container.decodeIfPresent([String: String].self, forKey: .corrections) ?? [:]
    }

    static var fileURL: URL {
        VoicePreferencesStore.baseDirectory.appendingPathComponent("vocabulary.json")
    }

    static func load() -> CustomVocabulary {
        var vocabulary: CustomVocabulary
        var canPersistMigration = !FileManager.default.fileExists(atPath: fileURL.path)
        do {
            let data = try Data(contentsOf: fileURL)
            vocabulary = try JSONDecoder().decode(CustomVocabulary.self, from: data)
            canPersistMigration = true
        } catch {
            vocabulary = CustomVocabulary(hotwords: [:])
        }

        let legacyURL = VoicePreferencesStore.baseDirectory.appendingPathComponent("transcription-corrections.json")
        if let data = try? Data(contentsOf: legacyURL),
           let legacy = try? JSONDecoder().decode(LegacyCorrections.self, from: data) {
            let merged = legacy.corrections.filter { vocabulary.corrections[$0.key] == nil }
            if !merged.isEmpty {
                vocabulary.corrections.merge(merged) { current, _ in current }
                if canPersistMigration { try? vocabulary.save() }
            }
        }
        return vocabulary
    }

    func save() throws {
        try FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(self).write(to: Self.fileURL, options: .atomic)
    }
}

private struct LegacyCorrections: Decodable {
    let corrections: [String: String]
}

enum TranscriptionTextCorrector {
    /// Apply all corrections against the original text so one replacement can
    /// never become the input to another correction in the same pass.
    static func apply(_ text: String, corrections: [String: String]) -> String {
        applyWithCount(text, corrections: corrections).text
    }

    static func applyWithCount(_ text: String, corrections: [String: String]) -> (text: String, count: Int) {
        let rules = corrections
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
            .sorted { lhs, rhs in
                if lhs.key.count != rhs.key.count { return lhs.key.count > rhs.key.count }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
        guard !rules.isEmpty else { return (text, 0) }

        let pattern = rules.map { rule in
            let escaped = NSRegularExpression.escapedPattern(for: rule.key)
            if rule.key.rangeOfCharacter(from: .alphanumerics) != nil,
               rule.key.unicodeScalars.contains(where: { CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz").contains($0) }) {
                return "(?<![A-Za-z0-9_])(?:\(escaped))(?![A-Za-z0-9_])"
            }
            return "(?:\(escaped))"
        }.joined(separator: "|")

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return (text, 0) }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return (text, 0) }

        let replacements = Dictionary(rules.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        let output = NSMutableString(string: text)
        var appliedCount = 0
        for match in matches.reversed() {
            let matched = source.substring(with: match.range).lowercased()
            if let replacement = replacements[matched], source.substring(with: match.range) != replacement {
                output.replaceCharacters(in: match.range, with: replacement)
                appliedCount += 1
            }
        }
        return (output as String, appliedCount)
    }
}
