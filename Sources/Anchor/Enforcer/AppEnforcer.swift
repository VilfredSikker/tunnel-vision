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

// MARK: - Crash-safe victim store

/// Apps we stopped or hid are recorded here; if Anchor dies they would stay
/// frozen/hidden forever, so the next launch restores them.
@MainActor
final class FrozenPidStore {
    struct Victim: Codable, Equatable {
        var pid: Int
        var hidden: Bool
        var frozen: Bool
    }

    private let url: URL

    init(url: URL? = nil) {
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Anchor", isDirectory: true)
            .appendingPathComponent("frozen-pids.json")
        self.url = url ?? fallback
    }

    func record(victims: [Victim]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(victims)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Anchor: could not persist victims: \(error)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    func read() -> [Victim] {
        // Tolerate the v1 schema ([pid]) and the v2 schema ([victim]) both.
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let victims = try? JSONDecoder().decode([Victim].self, from: data) {
            return victims
        }
        if let legacy = try? JSONDecoder().decode([Int].self, from: data) {
            return legacy.map { Victim(pid: $0, hidden: true, frozen: true) }
        }
        return []
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
        persistVictims() // empty → store cleared
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
        persistVictims()
        if !thawable.isEmpty || !unhideable.isEmpty {
            Self.log.info("recovered \(thawable.count + unhideable.count) process(es) for \(bundleID, privacy: .public)")
        }
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
        persistVictims()
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
            persistVictims()
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
                persistVictims()
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
        guard let bundleID = app.bundleIdentifier else {
            // A bundle id can be missing for a heartbeat (e.g. the moment of
            // launch). Re-check shortly after; the process is unenforceable
            // without a bundle anyway.
            scheduleLaunchRecheck(pid: pid, name: app.localizedName ?? "process \(pid)")
            return
        }
        enforce(snapshot: ProcessSnapshot(
            pid: pid,
            name: app.localizedName ?? "process \(pid)",
            bundleID: bundleID,
            isSelf: false
        ))
    }

    /// The app may not have had its bundle id yet at launch time; re-check
    /// once after a short delay so freshly launched apps are still caught.
    private func scheduleLaunchRecheck(pid: pid_t, name: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, self.isLocking else { return }
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
            guard let bundleID = app.bundleIdentifier else { return }
            self.enforce(snapshot: ProcessSnapshot(
                pid: pid,
                name: name,
                bundleID: bundleID,
                isSelf: false
            ))
        }
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
    }

    private func resumeAndForget(pid: pid_t) {
        if process.isRunning(pid: pid) {
            process.resume(pid: pid)
        }
        frozenPIDs.remove(pid)
        persistVictims()
    }

    private func unhideHidden() {
        for pid in hiddenPIDs where process.isRunning(pid: pid) {
            process.unhide(pid: pid)
        }
        hiddenPIDs = []
    }

    /// What survives a crash: every app we hid or froze, with its fate.
    private func persistVictims() {
        var victims: [FrozenPidStore.Victim] = []
        for pid in hiddenPIDs {
            victims.append(FrozenPidStore.Victim(pid: Int(pid), hidden: true, frozen: frozenPIDs.contains(pid)))
        }
        if victims.isEmpty {
            frozenStore.clear()
        } else {
            frozenStore.record(victims: victims)
        }
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

    /// Anchor died while apps were frozen or hidden: restore everything that
    /// is still alive on the next launch.
    private func thawOnLaunch() {
        let victims = frozenStore.read()
        guard !victims.isEmpty else { return }
        let alive = victims.filter { process.isRunning(pid: pid_t($0.pid)) }
        guard !alive.isEmpty else {
            frozenStore.clear()
            return
        }
        Self.log.info("restoring \(alive.count) victim(s) from previous run")
        for victim in alive {
            let pid = pid_t(victim.pid)
            if victim.frozen {
                process.resume(pid: pid)
            }
            if victim.hidden {
                process.unhide(pid: pid)
            }
        }
        frozenStore.clear()
    }
}
