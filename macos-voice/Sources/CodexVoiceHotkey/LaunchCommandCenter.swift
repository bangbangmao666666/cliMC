import Foundation

enum LaunchCommandCenter {
    static let showSettingsNotification = Notification.Name("com.codex.voice-hotkey.show-settings")

    static func requestShowSettings() {
        DistributedNotificationCenter.default().post(name: showSettingsNotification, object: nil)
    }

    static func observeShowSettings(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: showSettingsNotification,
            object: nil,
            queue: .main
        ) { _ in
            handler()
        }
    }
}
