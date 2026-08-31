import Foundation

struct UsageStatsSummary: Equatable {
    var voiceInputCount = 0
    var characterCount = 0
    var autoSubmitCount = 0

    static func + (lhs: UsageStatsSummary, rhs: UsageStatsSummary) -> UsageStatsSummary {
        UsageStatsSummary(
            voiceInputCount: lhs.voiceInputCount + rhs.voiceInputCount,
            characterCount: lhs.characterCount + rhs.characterCount,
            autoSubmitCount: lhs.autoSubmitCount + rhs.autoSubmitCount
        )
    }
}

// MARK: - UsageStatsEvent

enum UsageStatsEvent: Codable, Equatable {
    case voiceStarted(timestamp: Date)
    case transcriptionCommitted(timestamp: Date, characterCount: Int)
    case autoSubmitted(timestamp: Date)

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case type
        case characterCount
    }

    private enum EventType: String, Codable {
        case voiceStarted = "voice_started"
        case transcriptionCommitted = "transcription_committed"
        case autoSubmitted = "auto_submitted"
    }

    var timestamp: Date {
        switch self {
        case .voiceStarted(let timestamp),
             .transcriptionCommitted(let timestamp, _),
             .autoSubmitted(let timestamp):
            return timestamp
        }
    }

    var summary: UsageStatsSummary {
        switch self {
        case .voiceStarted:
            return UsageStatsSummary(voiceInputCount: 1)
        case .transcriptionCommitted(_, let characterCount):
            return UsageStatsSummary(characterCount: characterCount)
        case .autoSubmitted:
            return UsageStatsSummary(autoSubmitCount: 1)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timestamp = try container.decode(Date.self, forKey: .timestamp)
        let type = try container.decode(EventType.self, forKey: .type)
        switch type {
        case .voiceStarted:
            self = .voiceStarted(timestamp: timestamp)
        case .transcriptionCommitted:
            self = .transcriptionCommitted(
                timestamp: timestamp,
                characterCount: try container.decode(Int.self, forKey: .characterCount)
            )
        case .autoSubmitted:
            self = .autoSubmitted(timestamp: timestamp)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        switch self {
        case .voiceStarted:
            try container.encode(EventType.voiceStarted, forKey: .type)
        case .transcriptionCommitted(_, let characterCount):
            try container.encode(EventType.transcriptionCommitted, forKey: .type)
            try container.encode(characterCount, forKey: .characterCount)
        case .autoSubmitted:
            try container.encode(EventType.autoSubmitted, forKey: .type)
        }
    }
}

// MARK: - UsageStatsRecording

protocol UsageStatsRecording: AnyObject {
    func recordVoiceStarted(at date: Date) throws
    func recordTranscriptionCommitted(text: String, at date: Date) throws
    func recordAutoSubmitted(at date: Date) throws
}

// MARK: - UsageStatsStore

final class UsageStatsStore: UsageStatsRecording {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.init(fileURL: base.appendingPathComponent("cliMC/usage-events.jsonl"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func recordVoiceStarted(at date: Date = Date()) throws {
        try append(.voiceStarted(timestamp: date))
    }

    func recordTranscriptionCommitted(text: String, at date: Date = Date()) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try append(.transcriptionCommitted(
            timestamp: date,
            characterCount: text.count
        ))
    }

    func recordAutoSubmitted(at date: Date = Date()) throws {
        try append(.autoSubmitted(timestamp: date))
    }

    func summary(from start: Date, to end: Date) throws -> UsageStatsSummary {
        try events().reduce(into: UsageStatsSummary()) { partial, event in
            guard event.timestamp >= start, event.timestamp <= end else { return }
            partial = partial + event.summary
        }
    }

    private func append(_ event: UsageStatsEvent) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = try encoder.encode(event)
        data.append(0x0A)
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    private func events() throws -> [UsageStatsEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        return contents.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            do {
                return try decoder.decode(UsageStatsEvent.self, from: data)
            } catch {
                log("跳过损坏的使用统计记录：\(error.localizedDescription)")
                return nil
            }
        }
    }
}

// MARK: - DailyUsageSummary

struct DailyUsageSummary: Equatable {
    let date: Date
    let voiceInputCount: Int
    let characterCount: Int
    let autoSubmitCount: Int
}

extension UsageStatsStore {
    func dailySummaries(from start: Date, to end: Date) throws -> [DailyUsageSummary] {
        let calendar = Calendar.current
        var grouped: [Date: UsageStatsSummary] = [:]

        for event in try events() {
            guard event.timestamp >= start && event.timestamp <= end else { continue }
            let day = calendar.startOfDay(for: event.timestamp)
            let existing = grouped[day] ?? UsageStatsSummary()
            grouped[day] = existing + event.summary
        }

        return grouped.sorted(by: { $0.key < $1.key }).map { date, summary in
            DailyUsageSummary(
                date: date,
                voiceInputCount: summary.voiceInputCount,
                characterCount: summary.characterCount,
                autoSubmitCount: summary.autoSubmitCount
            )
        }
    }
}
