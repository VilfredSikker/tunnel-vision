import AppKit
import os
import SwiftUI
import TunnelVisionControlKit

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

    let model: AppState
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
    private var phaseAlerts: PhaseAlertController?
    private var toast: ToastController?
    private var windowPick: WindowPickController?
    private let terminationSignals = TerminationSignals()
    private var observedUnmanagedBrowsers: [String] = []

    override init() {
        // One instance only: two enforcers would fight over the victim store.
        // Checked before the model exists, so a second copy never reads,
        // seeds or quarantines the shared archive.
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleID)
            .filter { !$0.isTerminated && $0.processIdentifier != selfPID }
        if !others.isEmpty {
            Self.log.info("another Tunnel Vision instance is running — quitting")
            exit(0)
        }
        model = AppState()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The .app bundle already sets LSUIElement; this also keeps `swift run`
        // development launches free of a Dock icon.
        NSApp.setActivationPolicy(.accessory)

        // TERM, HUP and INT release the lock before exiting, so frozen apps
        // are not left stopped until the next launch.
        terminationSignals.install { [weak self] number in
            Self.log.info("signal \(number) — releasing the lock and exiting")
            self?.releaseLocks()
            exit(0)
        }

        // The SwiftUI Settings scene restores its last frame via AppKit's
        // autosave; a frame left on an unplugged display is pulled back.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { notification in
            // Read the window before the isolation hop: the notification
            // itself is not Sendable. Delivered on the main queue, so no
            // Task hop is needed, which would show the stale frame first.
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window,
                      SettingsWindowPlacement.isSettingsWindow(window),
                      SettingsWindowPlacement.needsRecentering(
                          frame: window.frame,
                          visibleFrames: NSScreen.screens.map(\.visibleFrame)
                      ) else { return }
                window.center()
            }
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
        phaseAlerts = PhaseAlertController(model: model)
        let toast = ToastController(anchorWindow: { [weak status] in status?.statusButtonWindow })
        self.toast = toast

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

        // A layer that cannot enforce what the session asks says so in the
        // session header.
        windowEnforcer.onWarning = { [weak model] in model?.setLockWarning($0, layer: "window") }
        browserEnforcer.onWarning = { [weak model] in model?.setLockWarning($0, layer: "browser") }
        herdrGuard.onWarning = { [weak model] in model?.setLockWarning($0, layer: "herdr") }

        // The window pick holds every layer that would hide the window the
        // user is reaching for, and disarms when the lock lifts.
        let pick = WindowPickController()
        pick.onHold = { [weak enforcer, weak windowEnforcer, weak browserEnforcer] on in
            enforcer?.hold(on)
            windowEnforcer?.hold(on)
            browserEnforcer?.hold(on)
        }
        pick.onPicked = { [weak self] window in
            self?.allowPicked(window)
        }
        windowPick = pick

        let broadcaster = LockBroadcaster([enforcer, windowEnforcer, browserEnforcer, herdrGuard, pick])
        lockBroadcaster = broadcaster
        model.lockListener = broadcaster

        model.urlOpener = { urls in
            for url in urls {
                NSWorkspace.shared.open(url)
            }
        }
        model.onSessionStarted = { [weak self] task in
            self?.confirmLock(for: task)
        }
        model.onPauseLimitReached = { [weak self] in
            guard let self, let task = self.model.activeTask else { return }
            self.toast?.show(
                title: "Pause over: back to “\(task.title)”",
                detail: "This session’s \(TimeFormat.minutes(AppState.maxPauseSeconds)) of pause time is used up; the lock is on again.",
                symbol: "lock.fill"
            )
        }

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
        browserEnforcer.onPickUnmatched = { [weak self] appName, _ in
            self?.toast?.show(
                title: "Could not allow that \(appName) window",
                detail: "Its title changed before Tunnel Vision found it. Press the shortcut and click it again.",
                symbol: "exclamationmark.triangle.fill"
            )
        }

        // A session picked up from before a crash or restart locks again
        // now that every layer and its notices are wired (the app layer has
        // already thawed what the last run left frozen), and says so.
        model.notifyLockChange()
        if model.phase == .work, let task = model.activeTask {
            confirmLock(for: task)
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

        if !model.settings.onboardingDone {
            OnboardingWindowController.shared.show(model: model)
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
        case .pickWindow:
            guard model.activeLock != nil else {
                toast?.show(
                    title: "Nothing to pick for",
                    detail: "The window pick works while a locked session runs.",
                    symbol: "cursorarrow.click.2"
                )
                return
            }
            // The click is read through Accessibility; without it the pick
            // would sit armed and never see a window.
            guard AccessibilityPermission.isTrusted else {
                toast?.show(
                    title: "The window pick needs Accessibility",
                    detail: "Grant it in Settings → Permissions, then press the shortcut again.",
                    symbol: "exclamationmark.triangle.fill"
                )
                return
            }
            windowPick?.toggle()
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

    /// The pick goes to the layer that would otherwise hide the window again.
    private func allowPicked(_ window: PickedWindow) {
        let allowance = PickAllowance.resolve(
            window,
            windowLayerJudges: windowEnforcer?.disciplines(bundleID: window.bundleID) ?? false,
            browserLayerJudges: browserEnforcer?.governs(bundleID: window.bundleID) ?? false
        )
        let detail: String
        switch allowance {
        case .windowTitle(let title):
            windowEnforcer?.allowForSession(bundleID: window.bundleID, titlePattern: title)
            detail = "“\(title)” in \(window.appName)"
        case .windowID(let id):
            windowEnforcer?.allowWindowForSession(bundleID: window.bundleID, windowID: id)
            let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
            detail = title.isEmpty ? "This untitled \(window.appName) window" : "“\(title)” in \(window.appName)"
        case .browserTitle(let title):
            browserEnforcer?.allowWindowForSession(bundleID: window.bundleID, title: title)
            detail = "“\(title)” in \(window.appName), whatever site it shows"
        case .app:
            enforcer?.allowForSession(bundleID: window.bundleID)
            detail = "\(window.appName), all windows"
        case .unidentifiable:
            toast?.show(
                title: "Could not allow that window",
                detail: "It has no title Tunnel Vision can match. Try again once it has one.",
                symbol: "exclamationmark.triangle.fill"
            )
            return
        }
        toast?.show(title: "Allowed for this session", detail: detail, symbol: "checkmark.circle.fill")
    }

    /// "A short confirmation shows what is now locked" (DESIGN_BRIEF §5).
    private func confirmLock(for task: TaskItem) {
        guard let lock = model.activeLock else { return }
        // The lock's first sweep may already have shown a blocked notice in
        // the same spot; the summary covers what it said.
        noticeController?.dismiss()
        var summary = LockSummary.describe(rules: lock.rules, mode: lock.mode) { bundleID in
            AppCatalog.displayName(forBundleID: bundleID) ?? bundleID
        }
        // A layer that already knows it cannot enforce its part (window
        // rules without Accessibility) says so here, where the user looks,
        // rather than only in the panel.
        for warning in model.lockWarningMessages {
            summary += "\n⚠︎ " + warning
        }
        toast?.show(title: "Locked to “\(task.title)”", detail: summary, symbol: "lock.fill")
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

    // MARK: Quit

    /// Quitting mid-session is an early end, with the same friction as the
    /// Stop button's menu equivalent. Logout, restart and shutdown pass
    /// straight through; the lock is released in `applicationWillTerminate`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.phase == .work || model.phase == .paused, let task = model.activeTask else { return .terminateNow }
        if EarlyEndConfirmation.isSystemQuit { return .terminateNow }
        guard EarlyEndConfirmation.confirm(taskTitle: task.title, strict: model.settings.strictMode, action: "End and Quit") else {
            return .terminateCancel
        }
        model.stopNow()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseLocks()
    }

    /// Clean exit mid-session: unlock so frozen apps thaw, hidden apps come
    /// back and minimised windows return, matching the crash-safe pid store
    /// for the hard-kill case.
    private func releaseLocks() {
        enforcer?.unlock()
        windowEnforcer?.unlock()
        browserEnforcer?.unlock()
        // After the unlocks: disarming first would end the hold and run a
        // full enforcement pass that the unlocks then undo.
        windowPick?.disarm()
        controlServer?.stop()
        // Window restores go out in the background; the process is about
        // to exit, so wait for them.
        windowEnforcer?.drainWrites(timeout: 1.5)
    }
}
