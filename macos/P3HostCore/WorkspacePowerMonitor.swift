import AppKit
import Foundation

@MainActor
final class WorkspacePowerMonitor: @unchecked Sendable {
    private let onSleep: @Sendable () -> Void
    private let onWake: @Sendable () -> Void
    private var observers: [NSObjectProtocol] = []

    init(
        onSleep: @escaping @Sendable () -> Void,
        onWake: @escaping @Sendable () -> Void
    ) {
        self.onSleep = onSleep
        self.onWake = onWake
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [onSleep] _ in onSleep() }
        )
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [onWake] _ in onWake() }
        )
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll(keepingCapacity: false)
    }
}
