import AppKit
import SwiftUI

@main
struct AnchorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // SwiftUI.Settings qualified: this module's Settings model type shadows it.
        SwiftUI.Settings {
            SettingsView(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppState()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The .app bundle already sets LSUIElement; this also keeps `swift run`
        // development launches free of a Dock icon.
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController(model: model)
        statusItemController?.install()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Nothing to flush: every mutation persists synchronously.
    }
}
