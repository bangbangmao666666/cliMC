import Foundation

public struct FailedAudioCleanupResult: Equatable, Sendable {
    public let deletedBasenames: [String]
    public let failures: [String]

    public init(deletedBasenames: [String] = [], failures: [String] = []) {
        self.deletedBasenames = deletedBasenames
        self.failures = failures
    }
}

public final class FailedAudioStore: @unchecked Sendable {
    public static let sevenDays: TimeInterval = 7 * 24 * 60 * 60

    private let stateRoot: URL
    private let retention: TimeInterval
    private let enabled: Bool
    private let fileManager: FileManager
    private let now: () -> Date
    private let lock = NSLock()

    public init(
        stateRoot: URL = DiagnosticStatePaths.defaultRoot(),
        retention: TimeInterval = FailedAudioStore.sevenDays,
        enabled: Bool = true,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.stateRoot = stateRoot
        self.retention = retention
        self.enabled = enabled
        self.fileManager = fileManager
        self.now = now
    }

    public func retain(source: URL, sessionID: UUID) -> String? {
        guard enabled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        do {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { return nil }

            let directory = failedAudioDirectory
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            let basename = sessionID.uuidString.lowercased() + ".wav"
            let destination = directory.appendingPathComponent(basename)
            guard !fileManager.fileExists(atPath: destination.path) else { return nil }
            try fileManager.copyItem(at: source, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return basename
        } catch {
            return nil
        }
    }

    public func cleanupExpired() -> FailedAudioCleanupResult {
        lock.lock()
        defer { lock.unlock() }
        let directory = failedAudioDirectory
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return FailedAudioCleanupResult()
        }

        let cutoff = now().addingTimeInterval(-retention)
        var deleted: [String] = []
        var failures: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard Self.isManagedArtifact(file.lastPathComponent) else { continue }
            do {
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt < cutoff else { continue }
                try fileManager.removeItem(at: file)
                deleted.append(file.lastPathComponent)
            } catch {
                failures.append(file.lastPathComponent)
            }
        }
        return FailedAudioCleanupResult(
            deletedBasenames: deleted,
            failures: failures
        )
    }

    private var failedAudioDirectory: URL {
        stateRoot.appendingPathComponent("failed-audio", isDirectory: true)
    }

    private static func isManagedArtifact(_ basename: String) -> Bool {
        guard basename.lowercased().hasSuffix(".wav") else { return false }
        let stem = String(basename.dropLast(4))
        return UUID(uuidString: stem) != nil
    }
}
