import Foundation

struct CustomVocabulary: Codable, Equatable {
    var hotwords: [String: Int]

    static var fileURL: URL {
        VoicePreferencesStore.baseDirectory.appendingPathComponent("vocabulary.json")
    }

    static func load() -> CustomVocabulary {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(CustomVocabulary.self, from: data)
        } catch {
            return CustomVocabulary(hotwords: [:])
        }
    }

    func save() throws {
        try FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(self).write(to: Self.fileURL, options: .atomic)
    }
}
