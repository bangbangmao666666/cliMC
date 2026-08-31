import AppKit
import Foundation

enum StartupGate {
    struct ActivationTarget: Equatable {
        let processIdentifier: Int32
    }

    static func acquire(
        bundleIdentifier: String,
        lockURL: URL,
        lockProvider: (URL) throws -> SingleInstanceLock?,
        activator: (String) -> Void,
        requestShowSettings: () -> Void
    ) -> SingleInstanceLock? {
        do {
            guard let lock = try lockProvider(lockURL) else {
                activator(bundleIdentifier)
                requestShowSettings()
                return nil
            }
            return lock
        } catch {
            log("无法获取单实例锁：\(error.localizedDescription)")
            exit(EXIT_FAILURE)
        }
    }

    static func selectActivationTarget(
        from targets: [ActivationTarget],
        excluding currentProcessIdentifier: Int32
    ) -> ActivationTarget? {
        targets.first { $0.processIdentifier != currentProcessIdentifier }
    }

    static func activateRunningInstance(bundleIdentifier: String) {
        let currentPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        let target = selectActivationTarget(
            from: applications.map { ActivationTarget(processIdentifier: $0.processIdentifier) },
            excluding: currentPID
        )
        guard let target else { return }
        if let application = applications.first(where: { $0.processIdentifier == target.processIdentifier }) {
            application.activate(options: [.activateAllWindows])
        }
    }
}
