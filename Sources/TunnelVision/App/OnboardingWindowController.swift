import AppKit
import SwiftUI

/// Shows the permissions walkthrough: by itself on a fresh install, and on
/// request from Settings.
@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private weak var model: AppState?

    /// Done and the close button both count as seen: a guide that comes
    /// back at every launch until one particular button is pressed is a
    /// nag. Settings reopens it.
    private func closed() {
        if let model, !model.settings.onboardingDone {
            var settings = model.settings
            settings.onboardingDone = true
            model.updateSettings(settings)
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
        window = nil
    }

    func show(model: AppState) {
        self.model = model
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = OnboardingView { [weak self] in
            self?.window?.close()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Tunnel Vision"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed() }
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
