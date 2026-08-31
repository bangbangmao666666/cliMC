import Foundation
import XCTest
@testable import VoiceDiagnostics

final class FailedAudioStoreTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_753_228_800)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FailedAudioStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testEnabledStoreCopiesToUUIDBasenameWithOwnerOnlyPermissions() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let source = root.appendingPathComponent("source.wav")
        try Data("audio".utf8).write(to: source)
        let store = makeStore()

        let basename = store.retain(source: source, sessionID: sessionID)

        XCTAssertEqual(basename, "00000000-0000-0000-0000-000000000001.wav")
        let destination = root.appendingPathComponent("failed-audio/" + basename!)
        XCTAssertEqual(try Data(contentsOf: destination), Data("audio".utf8))
        XCTAssertEqual(try posixMode(at: destination), 0o600)
        XCTAssertEqual(try posixMode(at: destination.deletingLastPathComponent()), 0o700)
    }

    func testDisabledStoreDoesNotCopyFailedAudio() throws {
        let source = root.appendingPathComponent("source.wav")
        try Data("audio".utf8).write(to: source)
        let store = makeStore(enabled: false)

        XCTAssertNil(store.retain(source: source, sessionID: UUID()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("failed-audio").path))
    }

    func testMissingSourceReturnsNilWithoutThrowing() {
        let source = root.appendingPathComponent("missing.wav")

        XCTAssertNil(makeStore().retain(source: source, sessionID: UUID()))
    }

    func testCleanupDeletesOnlyValidFailedAudioOlderThanSevenDays() throws {
        let directory = root.appendingPathComponent("failed-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expired = try fixture(
            in: directory,
            name: "00000000-0000-0000-0000-000000000001.wav",
            modifiedAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) - 0.001)
        )
        let boundary = try fixture(
            in: directory,
            name: "00000000-0000-0000-0000-000000000002.wav",
            modifiedAt: now.addingTimeInterval(-(7 * 24 * 60 * 60))
        )
        let unrelated = try fixture(
            in: directory,
            name: "notes.txt",
            modifiedAt: now.addingTimeInterval(-(30 * 24 * 60 * 60))
        )

        let result = makeStore().cleanupExpired()

        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: boundary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(result.deletedBasenames, [expired.lastPathComponent])
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testRetainRefusesToOverwriteExistingArtifact() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let source = root.appendingPathComponent("source.wav")
        try Data("first".utf8).write(to: source)
        let store = makeStore()
        let basename = try XCTUnwrap(store.retain(source: source, sessionID: sessionID))
        try Data("second".utf8).write(to: source)

        XCTAssertNil(store.retain(source: source, sessionID: sessionID))
        let destination = root.appendingPathComponent("failed-audio/" + basename)
        XCTAssertEqual(try Data(contentsOf: destination), Data("first".utf8))
    }

    private func makeStore(enabled: Bool = true) -> FailedAudioStore {
        FailedAudioStore(
            stateRoot: root,
            enabled: enabled,
            now: { [now] in now }
        )
    }

    private func fixture(in directory: URL, name: String, modifiedAt: Date) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
        return file
    }

    private func posixMode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
