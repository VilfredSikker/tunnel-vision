import AppKit
import os
import SwiftUI

@main
struct TunnelVisionApp: App {
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
    private static let log = Logger(subsystem: "com.tunnelvision.timer", category: "app")

    let model = AppState()
    private var statusItemController: StatusItemController?
    private var enforcer: AppEnforcer?
    private var windowEnforcer: WindowEnforcer?
    private var browserEnforcer: BrowserEnforcer?
    private var noticeController: BlockedNoticeController?
    private var hotKeys: HotKeyCenter?
    private var countdownWindow: CountdownWindowController?
    private var herdrGuard: HerdrWorkspaceGuard?
    private var lockBroadcaster: LockBroadcaster?
    private var controlAPI: ControlAPI?
    private var controlServer: ControlServer?
    private var observedUnmanagedBrowsers: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The .app bundle already sets LSUIElement; this also keeps `swift run`
        // development launches free of a Dock icon.
        NSApp.setActivationPolicy(.accessory)

        // The SwiftUI Settings scene remembers its last position via AppKit's
        // frame autosave. If that position was on a now-disconnected display,
        // the window opens off-screen. Center it whenever it becomes main.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            Task { @MainActor in
                guard let window, let self, self.isSettingsWindow(window) else { return }
                window.center()
            }
        }

        // One instance only: two enforcers would fight over the victim store.
        let otherInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.tunnelvision.timer")
            .filter { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !otherInstances.isEmpty {
            Self.log.info("another Tunnel Vision instance is running — quitting")
            NSApp.terminate(nil)
            return
        }

        let status = StatusItemController(model: model)
        status.onOpenPicker = { [weak self] in self?.openPickerForTaskAtHand() }
        status.install()
        statusItemController = status

        // Global shortcuts act like the panel's own controls; the floating
        // countdown shows itself while a session or break runs.
        let hotKeys = HotKeyCenter()
        hotKeys.onFire = { [weak self] slot in self?.handleHotKey(slot) }
        self.hotKeys = hotKeys
        observedUnmanagedBrowsers = model.settings.unmanagedBrowsers
        applySettings()
        countdownWindow = CountdownWindowController(model: model)

        // Enforcement follows the session: locked while a task runs (work or
        // paused), unlocked on break/idle. Layer 1 polices whole apps (frozen
        // victims are thawed on the next launch if Tunnel Vision dies mid-session),
        // layer 2 minimises windows inside apps allowed by window title,
        // layer 3 steers browser windows back to allowed sites.
        let enforcer = AppEnforcer()
        self.enforcer = enforcer
        let windowEnforcer = WindowEnforcer()
        self.windowEnforcer = windowEnforcer
        let browserEnforcer = BrowserEnforcer(unmanagedBrowsers: { [weak model] in
            Set(model?.settings.unmanagedBrowsers ?? [])
        })
        self.browserEnforcer = browserEnforcer

        // Inside the terminal, herdr workspaces are locked over herdr's
        // socket API: a switch to a non-allowed workspace bounces back.
        let herdrGuard = HerdrWorkspaceGuard(
            client: HerdrSocketClient(),
            taskTitle: { [weak model] in model?.activeTask?.title ?? "this task" }
        )
        self.herdrGuard = herdrGuard
        let broadcaster = LockBroadcaster([enforcer, windowEnforcer, browserEnforcer, herdrGuard])
        lockBroadcaster = broadcaster
        model.lockListener = broadcaster

        let notice = BlockedNoticeController(
            anchorWindow: { [weak status] in status?.statusButtonWindow },
            taskTitleProvider: { [weak model] in model?.activeTask?.title ?? "this task" },
            modeProvider: { [weak model] in
                model?.activePreset?.mode ?? model?.settings.defaultMode ?? .dark
            },
            onAllowForSession: { [weak self] event in
                self?.allowForSession(event)
            },
            onAddToPreset: { [weak model] event in
                model?.allowInActiveTask(rule: event.rule)
            }
        )
        self.noticeController = notice
        enforcer.onBlockedApp = { [weak notice] name, bundleID in
            notice?.show(.app(name: name, bundleID: bundleID))
        }
        windowEnforcer.onBlockedWindow = { [weak notice] appName, bundleID, title in
            notice?.show(.window(appName: appName, bundleID: bundleID, title: title))
        }
        browserEnforcer.onBlockedSite = { [weak notice] appName, bundleID, host in
            notice?.show(.site(appName: appName, bundleID: bundleID, host: host))
        }

        // The control socket lets tunnelvision-mcp (and anything else local) read
        // and shape tasks, presets and the session.
        let api = ControlAPI(model: model)
        controlAPI = api
        let server = ControlServer { method, params in
            try api.handle(method: method, params: params)
        }
        do {
            try server.start()
            controlServer = server
        } catch {
            Self.log.error("control socket not started: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Shortcuts

    private func handleHotKey(_ slot: HotKeyCenter.Slot) {
        switch slot {
        case .togglePanel:
            statusItemController?.togglePanel()
        case .newTask:
            statusItemController?.openNewTask()
        case .startPause:
            model.startOrPause()
        case .openPicker:
            openPickerForTaskAtHand()
        }
    }

    /// The picker for the running task, or the next one up when nothing
    /// runs; with no task at all, the new-task sheet. Pressing again while
    /// the picker is up closes it.
    private func openPickerForTaskAtHand() {
        let presenter = PickerOverlayPresenter.shared
        if presenter.isPresented {
            presenter.cancel()
            return
        }
        guard let task = model.taskAtHand else {
            statusItemController?.openNewTask()
            return
        }
        let preset = task.presetID.flatMap { id in model.presets.first { $0.id == id } }
        presenter.present(
            model: model,
            initialRules: model.effectiveRules(for: task),
            mode: preset?.mode ?? model.settings.defaultMode,
            allowPresetSave: true
        ) { [weak model] result in
            guard let result, let model else { return }
            model.applyPickedAllowlist(taskID: task.id, rules: result.rules, savedPresetID: result.savedPresetID)
        }
    }

    /// "Allow for this session" goes to the layer that blocked it.
    private func allowForSession(_ event: BlockEvent) {
        switch event {
        case .app(_, let bundleID):
            enforcer?.allowForSession(bundleID: bundleID)
        case .window(_, let bundleID, let title):
            windowEnforcer?.allowForSession(bundleID: bundleID, titlePattern: title)
        case .site(_, let bundleID, let host):
            browserEnforcer?.allowForSession(bundleID: bundleID, site: host)
        }
    }

    /// Re-registers the shortcuts whenever settings change, and relocks when
    /// the managed browsers changed so the browser layer follows.
    private func applySettings() {
        // Only the settings are read inside the tracking closure, so task and
        // preset edits do not re-run this.
        let settings = withObservationTracking {
            model.settings
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applySettings()
            }
        }
        hotKeys?.apply(settings.hotKeys)
        if settings.unmanagedBrowsers != observedUnmanagedBrowsers {
            observedUnmanagedBrowsers = settings.unmanagedBrowsers
            model.notifyLockChange()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean quit mid-session: unlock so frozen apps thaw, hidden apps
        // come back and minimised windows return, matching the crash-safe
        // pid store for the hard-kill case.
        enforcer?.unlock()
        windowEnforcer?.unlock()
        browserEnforcer?.unlock()
        controlServer?.stop()
    }

    // MARK: - Settings window visibility

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        let mask = window.styleMask
        // The only titled, closable, non-resizable window in the app. The
        // countdown is borderless; the notice is a non-activating panel.
        return mask.contains(.titled)
            && mask.contains(.closable)
            && !mask.contains(.resizable)
    }
}
