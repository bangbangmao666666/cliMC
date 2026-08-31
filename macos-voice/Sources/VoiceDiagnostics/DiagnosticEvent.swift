import CryptoKit
import Foundation

public enum DiagnosticProvider: String, Codable, CaseIterable, Sendable {
    case system
    case siliconFlow = "siliconflow"
    case volcengine
}

public enum DiagnosticEventName: String, Codable, CaseIterable, Sendable {
    case sessionStarted = "session_started"
    case captureFirstFrame = "capture_first_frame"
    case recordingStopped = "recording_stopped"
    case requestStarted = "request_started"
    case responseFirstSeen = "response_first_seen"
    case partialResult = "partial_result"
    case slow
    case criticalSlow = "critical_slow"
    case retryStarted = "retry_started"
    case finalResult = "final_result"
    case textInjected = "text_injected"
    case noAudio = "no_audio"
    case failed
    case cancelled
}

public enum DiagnosticAttributeValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.typeMismatch(
                DiagnosticAttributeValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Diagnostic attributes must be JSON scalars."
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        }
    }
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let timestamp: Date
    public let sessionID: UUID
    public let event: DiagnosticEventName
    public let provider: DiagnosticProvider
    public let elapsedMilliseconds: Int
    public let attributes: [String: DiagnosticAttributeValue]

    public init(
        schemaVersion: Int = 1,
        timestamp: Date,
        sessionID: UUID,
        event: DiagnosticEventName,
        provider: DiagnosticProvider,
        elapsedMilliseconds: Int,
        attributes: [String: DiagnosticAttributeValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.event = event
        self.provider = provider
        self.elapsedMilliseconds = max(0, elapsedMilliseconds)
        self.attributes = DiagnosticSanitizer.attributes(attributes)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case timestamp
        case sessionID = "session_id"
        case event
        case provider
        case elapsedMilliseconds = "elapsed_ms"
        case attributes
    }
}

public struct TranscriptMetadata: Codable, Equatable, Sendable {
    public let characterCount: Int
    public let digest: String
    public let preview: String?

    public static func make(text: String, includePreview: Bool = false) -> Self {
        let digest = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let cleaned = text.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
        return Self(
            characterCount: text.count,
            digest: digest,
            preview: includePreview ? String(cleaned.prefix(24)) : nil
        )
    }
}

public enum DiagnosticSanitizer {
    private static let deniedKeyFragments = [
        "api_key", "apikey", "authorization", "token", "secret", "body", "path",
    ]

    public static func attributes(
        _ attributes: [String: DiagnosticAttributeValue]
    ) -> [String: DiagnosticAttributeValue] {
        attributes.filter { key, _ in
            let normalized = key.lowercased()
            return !deniedKeyFragments.contains { normalized.contains($0) }
        }
    }
}

public extension JSONEncoder {
    static var diagnostic: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let style = Date.ISO8601FormatStyle(
                includingFractionalSeconds: true,
                timeZone: .gmt
            )
            try container.encode(date.formatted(style))
        }
        return encoder
    }
}

public extension JSONDecoder {
    static var diagnostic: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let style = Date.ISO8601FormatStyle(
                includingFractionalSeconds: true,
                timeZone: .gmt
            )
            guard let date = try? Date(value, strategy: style) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Invalid ISO 8601 diagnostic timestamp."
                )
            }
            return date
        }
        return decoder
    }
}
