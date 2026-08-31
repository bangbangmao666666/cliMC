import AppKit
import Foundation

/// 管理 Python Web 服务器的生命周期。
///
/// 1. 找到 Python 3 可执行文件
/// 2. 以子进程方式启动 `stats-server.py`
/// 3. 读取子进程第一行输出获得端口号
/// 4. 提供 `openInBrowser()` 和 `shutdown()` 方法
final class UsageStatsWebLauncher {
    private var process: Process?
    private(set) var port: Int?
    private let pythonScriptPath: String

    /// - Parameter pythonScriptPath: `stats-server.py` 的绝对路径
    init(pythonScriptPath: String) {
        self.pythonScriptPath = pythonScriptPath
    }

    /// 查找系统 Python 3 可执行文件路径。
    /// 优先 Homebrew / 本地安装，避免 macOS 自带 3.9 因类型注解语法启动失败。
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
        // 最后尝试通过 which 查找
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

    /// 启动服务器。返回端口号，失败时返回 nil。
    @discardableResult
    func start() -> Int? {
        guard let python = Self.findPython3() else {
            log("找不到 Python 3，无法启动统计服务器。请安装 Python 3: brew install python")
            return nil
        }
        guard FileManager.default.fileExists(atPath: pythonScriptPath) else {
            log("统计服务器脚本不存在: \(pythonScriptPath)")
            return nil
        }

        let pythonScriptURL = URL(fileURLWithPath: pythonScriptPath)
        let scriptDir = pythonScriptURL.deletingLastPathComponent().path
        let dataPath = FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/cliMC/usage-events.jsonl")
            .path

        let iconPath = "\(scriptDir)/cliMC.png"

        var arguments: [String] = [
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
        proc.currentDirectoryURL = URL(fileURLWithPath: scriptDir)

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
            log("无法启动统计服务器: \(error.localizedDescription)")
            return nil
        }

        // 读取第一行输出获取端口号（最多等待 5 秒）
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
                log("无法从统计服务器读取端口号（python=\(python), script=\(pythonScriptPath)）")
            } else {
                log("无法从统计服务器读取端口号：\(stderrText)")
            }
            proc.terminate()
            return nil
        }

        self.process = proc
        self.port = port
        log("统计服务器已启动: http://127.0.0.1:\(port)")
        return port
    }

    /// 在默认浏览器中打开仪表盘
    func openInBrowser() {
        guard let port else {
            log("统计服务器未启动，无法打开浏览器")
            return
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    /// 停止服务器
    func shutdown() {
        if let process {
            process.terminate()
            self.process = nil
        }
        port = nil
        log("统计服务器已停止")
    }

    deinit {
        shutdown()
    }
}

// MARK: - 文件句柄扩展：读取一行

private extension FileHandle {
    /// 从文件句柄读取一行（UTF-8），返回时去除换行符。
    /// 阻塞直到读到换行符或文件结束。
    func readLine() throws -> String? {
        var buffer = Data()
        while true {
            let byte = try read(upToCount: 1)
            guard let byte, !byte.isEmpty else {
                // EOF
                return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8)
            }
            if byte[0] == 0x0A { // \n
                return String(data: buffer, encoding: .utf8)
            }
            buffer.append(byte)
        }
    }
}
