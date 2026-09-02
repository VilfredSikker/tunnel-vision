import AppKit
import os
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
    private static let log = Logger(subsystem: "com.anchor.timer", category: "app")

    let model = AppState()
    private var statusItemController: StatusItemController?
    private var enforcer: AppEnforcer?
    private var noticeController: BlockedNoticeController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The .app bundle already sets LSUIElement; this also keeps `swift run`
        // development launches free of a Dock icon.
        NSApp.setActivationPolicy(.accessory)

        // One instance only: two enforcers would fight over the victim store.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.anchor.timer").count > 1 {
            Self.log.info("another Anchor instance is running — quitting")
            NSApp.terminate(nil)
            return
        }

        let status = StatusItemController(model: model)
        status.install()
        statusItemController = status

        // Layer 1 enforcement follows the session: locked while a task runs
        // (work or paused), unlocked on break/idle. Frozen victims are thawed
        // on the next launch if Anchor dies mid-session.
        let enforcer = AppEnforcer()
        self.enforcer = enforcer
        model.lockListener = enforcer

        let notice = BlockedNoticeController(
            anchorWindow: { [weak status] in status?.statusButtonWindow },
            taskTitleProvider: { [weak model] in model?.activeTask?.title ?? "this task" },
            modeProvider: { [weak model] in
                model?.activePreset?.mode ?? model?.settings.defaultMode ?? .dark
            },
            onAllowForSession: { [weak enforcer] bundleID in
                enforcer?.allowForSession(bundleID: bundleID)
            },
            onAddToPreset: { [weak model] bundleID in
                model?.allowInActiveTask(bundleID: bundleID)
            }
        )
        self.noticeController = notice
        enforcer.onBlockedApp = { [weak notice] name, bundleID in
            notice?.show(appName: name, bundleID: bundleID)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean quit mid-session: unlock so frozen apps thaw and hidden apps
        // come back, matching the crash-safe pid store for the hard-kill case.
        enforcer?.unlock()
    }
}
