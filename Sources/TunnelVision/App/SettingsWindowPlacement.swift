import AppKit

/// The SwiftUI Settings window restores its last frame through AppKit's
/// autosave. After a display is unplugged that frame can sit off every
/// screen; only then is it pulled back to the center. A window the user
/// placed on a live display stays where they put it.
enum SettingsWindowPlacement {
    /// The autosave name SwiftUI gives its Settings scene window.
    static let autosaveName = "com_apple_SwiftUI_Settings_window"

    @MainActor
    static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.frameAutosaveName == autosaveName || window.identifier?.rawValue == autosaveName
    }

    /// True when no part of the frame is on any screen's visible area.
    static func needsRecentering(frame: CGRect, visibleFrames: [CGRect]) -> Bool {
        !visibleFrames.contains { $0.intersects(frame) }
    }
}
