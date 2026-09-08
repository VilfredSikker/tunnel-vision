import Foundation
import ServiceManagement

/// Launch at login through SMAppService: the system owns the state, Tunnel Vision
/// only asks for it. Only a real .app bundle can register; a `swift run`
/// binary reports unavailable.
enum LaunchAtLogin {
    enum State: Equatable {
        case enabled
        case disabled
        /// Registered, but the user still has to approve it in System
        /// Settings > General > Login Items.
        case requiresApproval
        /// Not running from an app bundle.
        case unavailable
    }

    static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var state: State {
        guard isBundled else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
