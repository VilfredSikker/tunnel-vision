import AppKit
import Foundation
import os

// MARK: - Enforcement model

/// What a non-allowed app gets, derived from the task's preset mode.
enum Enforcement: Equatable, Sendable {
    case none
    case dark
    case closed
    case frozen

    static func decide(mode: Mode, bundleID: String?, allowed: Set<String>, exempt: Set<String>) -> Enforcement {
        guard let bundleID, !bundleID.isEmpty else {
            // No bundle id: cannot be matched by a rule, cannot be usefully
            // exempted (helper daemons, unbundled tools).
            return .none
        }
        if allowed.contains(bundleID) || exempt.contains(bundleID) { return .none }
        switch mode {
        case .dark: return .dark
        case .closed: return .closed
        case .frozen: return .frozen
        }
    }
}

/// Pure allowlist policy. A bundle is allowed when any rule (any scope)
/// targets it; window/URL-level discipline inside an allowed app arrives
/// with the Accessibility and browser layers.
enum LockPolicy {
    static func allowedBundleIDs(rules: [Rule]) -> Set<String> {
        var allowed = Set<String>()
        for rule in rules where rule.effect == .allow {
            let bundle = rule.bundleID.trimmingCharacters(in: .whitespaces)
            if !bundle.isEmpty {
                allowed.insert(bundle)
            }
        }
        return allowed
    }

    /// System processes that must never be hidden, quit or frozen, or the
    /// session becomes unusable.
    static let exemptSystemBundles: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.WindowManager",
        "com.apple.notificationcenterui",
        "com.apple.loginwindow",
        "com.apple.Spotlight",
        "com.apple.screensharing.agent",
        "com.apple.ScreenTimeAgent",
        "com.apple.telephonyutilities.callservicesd",
    ]
}

// MARK: - Process facade

/// One running application as the enforcer sees it.
struct ProcessSnapshot: Equatable, Sendable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let isSelf: Bool
}

/// Hides the AppKit/process details so enforcement decisions are testable.
@MainActor
protocol ProcessManaging: AnyObject {
    func runningApplications() -> [ProcessSnapshot]
    func bundleID(of pid: pid_t) -> String?
    func hide(pid: pid_t)
    func unhide(pid: pid_t)
    func terminate(pid: pid_t)
    func suspend(pid: pid_t) -> Bool
    func resume(pid: pid_t) -> Bool
    func isRunning(pid: pid_t) -> Bool
}

@MainActor
final class WorkspaceProcessManager: ProcessManaging {
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    func runningApplications() -> [ProcessSnapshot] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            let pid = app.processIdentifier
            guard pid > 0 else { return nil }
            return ProcessSnapshot(
                pid: pid,
                name: app.localizedName ?? app.bundleIdentifier ?? "process \(pid)",
                bundleID: app.bundleIdentifier,
                isSelf: pid == selfPID
            )
        }
    }

    private func runningApp(_ pid: pid_t) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
    }

    func bundleID(of pid: pid_t) -> String? {
        runningApp(pid)?.bundleIdentifier
    }

    func hide(pid: pid_t) {
        guard let app = runningApp(pid), !app.isTerminated else { return }
        app.hide()
    }

    func unhide(pid: pid_t) {
        guard let app = runningApp(pid), !app.isTerminated else { return }
        app.unhide()
    }

    func terminate(pid: pid_t) {
        guard let app = runningApp(pid), !app.isTerminated else { return }
        app.terminate()
    }

    func suspend(pid: pid_t) -> Bool {
        kill(pid, SIGSTOP) == 0
    }

    func resume(pid: pid_t) -> Bool {
        kill(pid, SIGCONT) == 0
    }

    func isRunning(pid: pid_t) -> Bool {
        guard let app = runningApp(pid) else { return false }
        return !app.isTerminated
    }
}

// MARK: - Crash-safe frozen-app store

/// Frozen apps are SIGSTOPped; if Anchor dies they would stay frozen. Every
/// stop is recorded here and thawed on the next launch.
@MainActor
final class FrozenPidStore {
    private let url: URL

    init(url: URL? = nil) {
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Anchor", isDirectory: true)
            .appendingPathComponent("frozen-pids.json")
        self.url = url ?? fallback
    }

    func record(pids: Set<pid_t>) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(pids))
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Anchor: could not persist frozen pids: \(error)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    func read() -> [pid_t] {
        guard let data = try? Data(contentsOf: url),
              let pids = try? JSONDecoder().decode([pid_t].self, from: data) else { return [] }
        return pids
    }
}

// MARK: - Enforcer

/// Layer 1 enforcer (FEASIBILITY.md step 2): while a session runs, any app
/// not on the task's allowlist is hidden (dark), quit (closed) or frozen
/// (frozen) the moment it runs or comes to the front. Frozen apps are thawed
/// on unlock and — if Anchor dies first — on the next launch via the pid
/// store.
@MainActor
final class AppEnforcer: LockListener {
    private static let log = Logger(subsystem: "com.anchor.timer", category: "enforcer")

    private let process: ProcessManaging
    private let frozenStore: FrozenPidStore
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    private var mode: Mode = .dark
    private var allowed: Set<String> = []
    private var sessionOverrideBundles: Set<String> = []
    private var hiddenPIDs: Set<pid_t> = []
    private var frozenPIDs: Set<pid_t> = []
    private var observers: [NSObjectProtocol] = []
    private var lastNoticeAt: [String: Date] = [:]

    private(set) var isLocking = false

    /// Called when an app is blocked, with (app name, bundle id). The UI
    /// shows the non-blocking notice.
    var onBlockedApp: ((_ name: String, _ bundleID: String) -> Void)?

    init(
        process: ProcessManaging = WorkspaceProcessManager(),
        frozenStore: FrozenPidStore = FrozenPidStore()
    ) {
        self.process = process
        self.frozenStore = frozenStore
        thawOnLaunch()
    }

    // MARK: LockListener

    func lockStateChanged(active: Bool, rules: [Rule], mode: Mode) {
        if active {
            lock(mode: mode, rules: rules)
        } else {
            unlock()
        }
    }

    // MARK: Session lock

    func lock(mode: Mode, rules: [Rule]) {
        Self.log.info("lock: mode=\(mode.displayName, privacy: .public) rules=\(rules.count) overrides=\(self.sessionOverrideBundles.count)")
        self.mode = mode
        allowed = LockPolicy.allowedBundleIDs(rules: rules).union(sessionOverrideBundles)
        isLocking = true
        reconcileNewlyAllowed()
        enforceRunningApplications()
        startWatching()
    }

    func unlock() {
        guard isLocking else {
            // Idle while frozen leftovers exist can only happen after a crash.
            return
        }
        Self.log.info("unlock")
        isLocking = false
        allowed = []
        sessionOverrideBundles = []
        lastNoticeAt = [:]
        stopWatching()
        thawFrozen()
        unhideHidden()
    }

    /// "Allow for this session": re-admits an app that was blocked, thawing
    /// or unhiding it if the enforcer still has a handle on it.
    func allowForSession(bundleID: String) {
        sessionOverrideBundles.insert(bundleID)
        allowed.insert(bundleID)
        Self.log.info("allow-for-session: \(bundleID, privacy: .public)")
        // Un-freeze/un-hide any victim with this bundle that we still track.
        let thawable = frozenPIDs.filter { pid in
            self.process.bundleID(of: pid) == bundleID
        }
        for pid in thawable {
            resumeAndForget(pid: pid)
        }
        let unhideable = hiddenPIDs.filter { pid in
            self.process.bundleID(of: pid) == bundleID
        }
        for pid in unhideable {
            process.unhide(pid: pid)
            hiddenPIDs.remove(pid)
        }
        if !thawable.isEmpty || !unhideable.isEmpty {
            Self.log.info("recovered \(thawable.count + unhideable.count) process(es) for \(bundleID, privacy: .public)")
        }
    }

    func resetSessionOverrides() {
        sessionOverrideBundles = []
    }

    private func enforceRunningApplications() {
        for snapshot in process.runningApplications() {
            enforce(snapshot: snapshot)
        }
    }

    /// The allowlist grew (allow-for-session, add-to-preset, preset switch):
    /// victims that are now allowed come back immediately.
    private func reconcileNewlyAllowed() {
        for pid in frozenPIDs {
            guard let bundle = process.bundleID(of: pid), allowed.contains(bundle) else { continue }
            resumeAndForget(pid: pid)
        }
        for pid in hiddenPIDs {
            guard let bundle = process.bundleID(of: pid), allowed.contains(bundle) else { continue }
            if process.isRunning(pid: pid) {
                process.unhide(pid: pid)
            }
            hiddenPIDs.remove(pid)
        }
    }

    /// Enforce one snapshot (internal so tests can drive app events).
    func enforce(snapshot: ProcessSnapshot) {
        guard isLocking else { return }
        if snapshot.isSelf { return }
        let decision = Enforcement.decide(
            mode: mode,
            bundleID: snapshot.bundleID,
            allowed: allowed,
            exempt: LockPolicy.exemptSystemBundles
        )
        switch decision {
        case .none:
            return
        case .dark:
            process.hide(pid: snapshot.pid)
            hiddenPIDs.insert(snapshot.pid)
            Self.log.info("dark: hid \(snapshot.name, privacy: .public)")
            notifyBlocked(snapshot)
        case .closed:
            process.terminate(pid: snapshot.pid)
            Self.log.info("closed: quit \(snapshot.name, privacy: .public)")
            notifyBlocked(snapshot)
        case .frozen:
            // Freeze = hide + SIGSTOP (FEASIBILITY.md); SIGCONT on unlock.
            process.hide(pid: snapshot.pid)
            hiddenPIDs.insert(snapshot.pid)
            if process.suspend(pid: snapshot.pid) {
                frozenPIDs.insert(snapshot.pid)
                frozenStore.record(pids: frozenPIDs)
                Self.log.info("frozen: SIGSTOP \(snapshot.name, privacy: .public) pid=\(snapshot.pid)")
                notifyBlocked(snapshot)
            }
        }
    }

    /// Reacts to an app launch or activation while locking (internal so
    /// tests can drive it).
    func handleAppEvent(_ app: NSRunningApplication) {
        guard isLocking, !app.isTerminated else { return }
        let pid = app.processIdentifier
        guard pid > 0, pid != selfPID else { return }
        enforce(snapshot: ProcessSnapshot(
            pid: pid,
            name: app.localizedName ?? "process \(pid)",
            bundleID: app.bundleIdentifier,
            isSelf: false
        ))
    }

    private func notifyBlocked(_ snapshot: ProcessSnapshot) {
        guard let bundle = snapshot.bundleID else { return }
        let now = Date()
        if let last = lastNoticeAt[bundle], now.timeIntervalSince(last) < 4 { return }
        lastNoticeAt[bundle] = now
        onBlockedApp?(snapshot.name, bundle)
    }

    // MARK: Unlock helpers

    private func thawFrozen() {
        for pid in frozenPIDs {
            resumeAndForget(pid: pid)
        }
        frozenStore.clear()
    }

    private func resumeAndForget(pid: pid_t) {
        if process.isRunning(pid: pid) {
            process.resume(pid: pid)
        }
        frozenPIDs.remove(pid)
        frozenStore.record(pids: frozenPIDs)
    }

    private func unhideHidden() {
        for pid in hiddenPIDs where process.isRunning(pid: pid) {
            process.unhide(pid: pid)
        }
        hiddenPIDs = []
    }

    // MARK: Watchdogs

    private func startWatching() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                self?.handleAppEvent(app)
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                self?.handleAppEvent(app)
            }
        })
    }

    private func stopWatching() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
    }

    // MARK: Crash safety

    /// Anchor died while apps were frozen: thaw everything still alive.
    private func thawOnLaunch() {
        let pids = frozenStore.read()
        guard !pids.isEmpty else { return }
        Self.log.info("thawing \(pids.count) frozen process(es) from previous run")
        for pid in pids {
            if process.isRunning(pid: pid) {
                process.resume(pid: pid)
            }
        }
        frozenStore.clear()
    }
}
