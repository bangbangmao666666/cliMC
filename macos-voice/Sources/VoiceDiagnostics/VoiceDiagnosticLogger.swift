import Foundation

public protocol DiagnosticEventSink: AnyObject {
    func write(_ event: DiagnosticEvent)
}

public enum DiagnosticStatePaths {
    public static func defaultRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/climc", isDirectory: true)
    }
}

public final class VoiceDiagnosticLogger: DiagnosticEventSink, @unchecked Sendable {
    private let stateRoot: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let warning: (String) -> Void
    private let queue = DispatchQueue(label: "local.climc.diagnostic-log")
    private var didWarnForCurrentFailure = false

    public init(
        stateRoot: URL = DiagnosticStatePaths.defaultRoot(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        warning: @escaping (String) -> Void = { message in fputs("\(message)\n", stderr) }
    ) {
        self.stateRoot = stateRoot
        self.fileManager = fileManager
        self.now = now
        self.warning = warning
    }

    public func write(_ event: DiagnosticEvent) {
        queue.sync {
            do {
                let logsDirectory = stateRoot.appendingPathComponent("logs", isDirectory: true)
                try fileManager.createDirectory(
                    at: logsDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logsDirectory.path)

                let file = logsDirectory.appendingPathComponent("\(Self.utcDay(now())).jsonl")
                if !fileManager.fileExists(atPath: file.path) {
                    guard fileManager.createFile(
                        atPath: file.path,
                        contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    ) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

                var data = try JSONEncoder.diagnostic.encode(event)
                data.append(0x0A)
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: data)
                didWarnForCurrentFailure = false
            } catch {
                if !didWarnForCurrentFailure {
                    didWarnForCurrentFailure = true
                    warning("cliMC 诊断日志写入失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
