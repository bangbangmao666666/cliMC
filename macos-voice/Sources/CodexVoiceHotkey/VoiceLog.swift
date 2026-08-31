import Foundation

enum VoiceLogFormatter {
    private static let formatStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: .gmt
    )

    static func line(message: String, date: Date = Date()) -> String {
        "[\(date.formatted(formatStyle))] [cliMC] \(message)\n"
    }
}

func log(_ message: String) {
    let line = VoiceLogFormatter.line(message: message)
    fputs(line, stderr)
    let file = URL(fileURLWithPath: "/private/tmp/codex-voice-hotkey.log")
    let data = Data(line.utf8)
    if FileManager.default.fileExists(atPath: file.path),
       let handle = try? FileHandle(forWritingTo: file) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: file, options: .atomic)
    }
}
