import Foundation

/// Fans one lock-state change out to every enforcement layer.
@MainActor
final class LockBroadcaster: LockListener {
    private let listeners: [LockListener]

    init(_ listeners: [LockListener]) {
        self.listeners = listeners
    }

    func lockStateChanged(active: Bool, rules: [Rule], mode: Mode) {
        for listener in listeners {
            listener.lockStateChanged(active: active, rules: rules, mode: mode)
        }
    }
}
