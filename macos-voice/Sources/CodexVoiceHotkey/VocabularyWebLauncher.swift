import AppKit
import Foundation

final class VocabularyWebLauncher {
    private var process: Process?
    private(set) var port: Int?
    private let pythonScriptPath: String

    init(pythonScriptPath: String) {
        self.pythonScriptPath = pythonScriptPath
    }

    private static func findPython3() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", "python3"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            log("which python3 失败: \(error.localizedDescription)")
        }
        return nil
    }

    @discardableResult
    func start() -> Int? {
        guard let python = Self.findPython3() else {
            log("找不到 Python 3，无法启动热词服务器。请安装 Python 3: brew install python")
            return nil
        }
        guard FileManager.default.fileExists(atPath: pythonScriptPath) else {
            log("热词服务器脚本不存在: \(pythonScriptPath)")
            return nil
        }

        let dataPath = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/codex-voice/vocabulary.json")
            .path

        let scriptURL = URL(fileURLWithPath: pythonScriptPath)
        let scriptDir = scriptURL.deletingLastPathComponent().path
        let iconPath = "\(scriptDir)/cliMC.png"

        var arguments = [
            pythonScriptPath,
            "--port", "0",
            "--data", dataPath,
        ]
        if FileManager.default.fileExists(atPath: iconPath) {
            arguments += ["--icon", iconPath]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        proc.environment = environment

        do {
            try proc.run()
        } catch {
            log("无法启动热词服务器: \(error.localizedDescription)")
            return nil
        }

        let fileHandle = stdoutPipe.fileHandleForReading
        let timeout: TimeInterval = 5.0
        let startTime = Date()
        var portString = ""
        while Date().timeIntervalSince(startTime) < timeout {
            if let line = try? fileHandle.readLine() {
                portString = line
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        guard !portString.isEmpty, let port = Int(portString) else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if stderrText.isEmpty {
                log("无法从热词服务器读取端口号（python=\(python), script=\(pythonScriptPath)）")
            } else {
                log("无法从热词服务器读取端口号：\(stderrText)")
            }
            proc.terminate()
            return nil
        }

        self.process = proc
        self.port = port
        log("热词服务器已启动: http://127.0.0.1:\(port)")
        return port
    }

    func openInBrowser() {
        guard let port else {
            log("热词服务器未启动，无法打开浏览器")
            return
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    func shutdown() {
        if let process {
            process.terminate()
            self.process = nil
        }
        port = nil
        log("热词服务器已停止")
    }

    deinit {
        shutdown()
    }
}

private extension FileHandle {
    func readLine() throws -> String? {
        var buffer = Data()
        while true {
            let byte = try read(upToCount: 1)
            guard let byte, !byte.isEmpty else {
                return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8)
            }
            if byte[0] == 0x0A {
                return String(data: buffer, encoding: .utf8)
            }
            buffer.append(byte)
        }
    }
}
