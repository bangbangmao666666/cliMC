import Foundation
import XCTest
@testable import VoiceDiagnostics

final class VoiceDiagnosticLoggerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceDiagnosticLoggerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func testLoggerAppendsOneDecodableJSONObjectPerLine() throws {
        let date = Date(timeIntervalSince1970: 1_753_228_800)
        let logger = VoiceDiagnosticLogger(stateRoot: temporaryRoot, now: { date })

        logger.write(makeEvent(at: date, name: .sessionStarted))
        logger.write(makeEvent(at: date, name: .recordingStopped))

        let lines = try String(contentsOf: logURL(for: "2025-07-23"), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertNoThrow(try lines.forEach {
            _ = try JSONDecoder.diagnostic.decode(DiagnosticEvent.self, from: Data($0.utf8))
        })
    }

    func testLoggerChangesFilesAtUTCMidnight() throws {
        var date = Date(timeIntervalSince1970: 1_753_228_799)
        let logger = VoiceDiagnosticLogger(stateRoot: temporaryRoot, now: { date })

        logger.write(makeEvent(at: date, name: .sessionStarted))
        date = date.addingTimeInterval(2)
        logger.write(makeEvent(at: date, name: .cancelled))

        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL(for: "2025-07-22").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL(for: "2025-07-23").path))
    }

    func testConcurrentWritesRemainIndependentJSONLines() throws {
        let date = Date(timeIntervalSince1970: 1_753_228_800)
        let logger = VoiceDiagnosticLogger(stateRoot: temporaryRoot, now: { date })
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            logger.write(makeEvent(at: date, name: .partialResult, elapsed: index))
        }

        let lines = try String(contentsOf: logURL(for: "2025-07-23"), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 100)
        XCTAssertNoThrow(try lines.forEach {
            _ = try JSONDecoder.diagnostic.decode(DiagnosticEvent.self, from: Data($0.utf8))
        })
    }

    func testLoggerCreatesOwnerOnlyDirectoryAndFile() throws {
        let date = Date(timeIntervalSince1970: 1_753_228_800)
        let logger = VoiceDiagnosticLogger(stateRoot: temporaryRoot, now: { date })

        logger.write(makeEvent(at: date, name: .sessionStarted))

        let directoryMode = try posixMode(at: temporaryRoot.appendingPathComponent("logs"))
        let fileMode = try posixMode(at: logURL(for: "2025-07-23"))
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)
    }

    func testWriteFailureDoesNotThrowAndWarnsOnlyOnceUntilRecovery() throws {
        try Data("not a directory".utf8).write(to: temporaryRoot)
        let warnings = LockedStrings()
        let logger = VoiceDiagnosticLogger(
            stateRoot: temporaryRoot,
            warning: { warnings.append($0) }
        )

        logger.write(makeEvent(name: .sessionStarted))
        logger.write(makeEvent(name: .cancelled))

        XCTAssertEqual(warnings.values.count, 1)
    }

    private func logURL(for day: String) -> URL {
        temporaryRoot.appendingPathComponent("logs/\(day).jsonl")
    }

    private func makeEvent(
        at date: Date = Date(timeIntervalSince1970: 0),
        name: DiagnosticEventName,
        elapsed: Int = 0
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            timestamp: date,
            sessionID: UUID(),
            event: name,
            provider: .system,
            elapsedMilliseconds: elapsed
        )
    }

    private func posixMode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
