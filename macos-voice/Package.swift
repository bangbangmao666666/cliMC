// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexVoiceHotkey",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "codex-voice-hotkey", targets: ["CodexVoiceHotkey"])],
    targets: [
        .target(name: "VoiceDiagnostics"),
        .executableTarget(
            name: "CodexVoiceHotkey",
            dependencies: ["VoiceDiagnostics"]
        ),
        .testTarget(name: "CodexVoiceHotkeyTests", dependencies: ["CodexVoiceHotkey"]),
        .testTarget(name: "VoiceDiagnosticsTests", dependencies: ["VoiceDiagnostics"]),
    ],
    swiftLanguageModes: [.v5]
)
