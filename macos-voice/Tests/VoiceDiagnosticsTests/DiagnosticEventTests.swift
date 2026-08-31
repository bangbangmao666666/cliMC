import Foundation
import XCTest
@testable import VoiceDiagnostics

final class DiagnosticEventTests: XCTestCase {
    func testEventEncodesStableSnakeCaseJSON() throws {
        let event = DiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 0),
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            event: .finalResult,
            provider: .siliconFlow,
            elapsedMilliseconds: 12_345,
            attributes: ["character_count": .integer(4)]
        )

        let data = try JSONEncoder.diagnostic.encode(event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["event"] as? String, "final_result")
        XCTAssertEqual(object["provider"] as? String, "siliconflow")
        XCTAssertEqual(object["elapsed_ms"] as? Int, 12_345)
    }

    func testTranscriptMetadataDoesNotContainFullTextByDefault() throws {
        let secret = "这是绝不能写进日志的完整转写"

        let metadata = TranscriptMetadata.make(text: secret)
        let encoded = String(data: try JSONEncoder().encode(metadata), encoding: .utf8)!

        XCTAssertEqual(metadata.characterCount, secret.count)
        XCTAssertEqual(metadata.digest.count, 64)
        XCTAssertNil(metadata.preview)
        XCTAssertFalse(encoded.contains(secret))
    }

    func testTranscriptPreviewIsSanitizedAndLimitedWhenExplicitlyEnabled() {
        let metadata = TranscriptMetadata.make(
            text: "第一行\n第二行\t以及一段明显超过二十四个字符的内容",
            includePreview: true
        )

        XCTAssertFalse(metadata.preview?.contains("\n") == true)
        XCTAssertFalse(metadata.preview?.contains("\t") == true)
        XCTAssertLessThanOrEqual(metadata.preview?.count ?? .max, 24)
    }

    func testSanitizerRejectsSecretsBodiesAndPaths() {
        let sanitized = DiagnosticSanitizer.attributes([
            "api_key": .string("secret"),
            "authorization": .string("Bearer secret"),
            "response_body": .string("private body"),
            "source_path": .string("/Users/person/private.wav"),
            "http_status": .integer(503),
        ])

        XCTAssertEqual(sanitized, ["http_status": .integer(503)])
    }

    func testAttributeValuesRoundTripAsJSONScalars() throws {
        let attributes: [String: DiagnosticAttributeValue] = [
            "text": .string("value"),
            "count": .integer(7),
            "duration": .double(1.5),
            "enabled": .boolean(true),
        ]

        let data = try JSONEncoder().encode(attributes)
        let decoded = try JSONDecoder().decode([String: DiagnosticAttributeValue].self, from: data)

        XCTAssertEqual(decoded, attributes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["text"] as? String, "value")
        XCTAssertEqual(object["count"] as? Int, 7)
        XCTAssertEqual(object["duration"] as? Double, 1.5)
        XCTAssertEqual(object["enabled"] as? Bool, true)
    }
}
