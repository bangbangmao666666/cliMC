import AppKit

protocol VoiceControlling: AnyObject {
    func start()
    func showSettings()
}

enum AppLifecycle {
    static func handleReopen(activate: () -> Void) -> Bool {
        activate()
        return true
    }

    static func handleOpen(activate: () -> Void) -> Bool {
        activate()
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller: VoiceControlling

    init(controller: VoiceControlling = VoiceController()) {
        self.controller = controller
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        controller.start()
        controller.showSettings()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.showSettings()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppLifecycle.handleReopen {
            controller.showSettings()
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        AppLifecycle.handleOpen {
            controller.showSettings()
        }
    }
}
