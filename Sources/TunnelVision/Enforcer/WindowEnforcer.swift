import AppKit
import ApplicationServices
import Foundation
import os

// MARK: - Policy

/// Layer 2 (FEASIBILITY.md): inside an app allowed only through window
/// rules, windows whose title matches no rule are minimised. A bundle with an
/// app rule is allowed whole; a bundle with URL rules belongs to the browser
/// layer, which sees URLs this layer cannot.
enum WindowLockPolicy {
    /// Lowercased title patterns per bundle for the apps this layer disciplines.
    static func titlePatterns(rules: [Rule]) -> [String: [String]] {
        var wholeApp = Set<String>()
        var byURL = Set<String>()
        for rule in rules where rule.effect == .allow {
            let bundle = rule.bundleID.trimmingCharacters(in: .whitespaces)
            guard !bundle.isEmpty else { continue }
            switch rule.scope {
            case .app: wholeApp.insert(bundle)
            case .url: byURL.insert(bundle)
            case .window, .herdr: break
            }
        }
        var patterns: [String: [String]] = [:]
        for rule in rules where rule.effect == .allow && rule.scope == .window {
            let bundle = rule.bundleID.trimmingCharacters(in: .whitespaces)
            let pattern = rule.pattern.trimmingCharacters(in: .whitespaces).lowercased()
            guard !bundle.isEmpty, !pattern.isEmpty, !wholeApp.contains(bundle), !byURL.contains(bundle) else { continue }
            patterns[bundle, default: []].append(pattern)
        }
        return patterns
    }

    /// Case-insensitive substring match, the same test the picker seeds with.
    static func matches(title: String, patterns: [String]) -> Bool {
        let lowered = title.lowercased()
        return patterns.contains { !$0.isEmpty && lowered.contains($0) }
    }
}

// MARK: - Accessibility facade

/// One window of another app as the Accessibility API reports it.
struct AXWindowSnapshot: Equatable, Sendable {
    let id: CGWindowID
    let title: String
    let isMinimized: Bool
    /// A standard document or app window. Dialogs, sheets and palettes are
    /// left alone: they cannot be minimised and are never distractions on
    /// their own.
    let isStandard: Bool
}

/// Hides the Accessibility calls so window discipline is testable.
@MainActor
protocol WindowManaging: AnyObject {
    /// Accessibility permission granted to Tunnel Vision.
    var isTrusted: Bool { get }
    func runningApplications() -> [ProcessSnapshot]
    func windows(forPID pid: pid_t) -> [AXWindowSnapshot]
    @discardableResult
    func setMinimized(_ minimized: Bool, windowID: CGWindowID, pid: pid_t) -> Bool
    /// Calls back when the app's windows change (created, focused, shown
    /// again, retitled). Idempotent per pid.
    func observe(pid: pid_t, onChange: @escaping @MainActor () -> Void)
    func stopObserving(pid: pid_t)
}

@MainActor
final class AccessibilityWindowManager: WindowManaging {
    private static let log = Logger(subsystem: "com.tunnelvision.timer", category: "ax")
    private static let notifications: [String] = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXTitleChangedNotification,
    ]

    private let processes = WorkspaceProcessManager()
    private var observers: [pid_t: AXObserver] = [:]
    private var callbacks: [pid_t: @MainActor () -> Void] = [:]

    var isTrusted: Bool { AXIsProcessTrusted() }

    func runningApplications() -> [ProcessSnapshot] {
        processes.runningApplications()
    }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] {
        elements(forPID: pid).compactMap { element in
            var windowID: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &windowID) == .success, windowID != 0 else { return nil }
            let subrole = attribute(element, kAXSubroleAttribute) as? String
            return AXWindowSnapshot(
                id: windowID,
                title: (attribute(element, kAXTitleAttribute) as? String) ?? "",
                isMinimized: (attribute(element, kAXMinimizedAttribute) as? Bool) ?? false,
                isStandard: subrole == kAXStandardWindowSubrole
            )
        }
    }

    func setMinimized(_ minimized: Bool, windowID: CGWindowID, pid: pid_t) -> Bool {
        for element in elements(forPID: pid) {
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &id) == .success, id == windowID else { continue }
            let value: CFBoolean = minimized ? kCFBooleanTrue : kCFBooleanFalse
            return AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, value) == .success
        }
        return false
    }

    func observe(pid: pid_t, onChange: @escaping @MainActor () -> Void) {
        callbacks[pid] = onChange
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        let status = AXObserverCreate(pid, { _, element, _, refcon in
            guard let refcon else { return }
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { return }
            // The observer's run loop source lives on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<AccessibilityWindowManager>.fromOpaque(refcon).takeUnretainedValue().fire(pid: pid)
            }
        }, &observer)
        guard status == .success, let observer else {
            Self.log.info("AX observer for pid \(pid) not created: \(status.rawValue)")
            return
        }
        let application = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(observer, application, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    func stopObserving(pid: pid_t) {
        callbacks[pid] = nil
        guard let observer = observers.removeValue(forKey: pid) else { return }
        let application = AXUIElementCreateApplication(pid)
        for name in Self.notifications {
            AXObserverRemoveNotification(observer, application, name as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func fire(pid: pid_t) {
        callbacks[pid]?()
    }

    /// The app's window elements; empty for a busy app after a short timeout.
    private func elements(forPID pid: pid_t) -> [AXUIElement] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return windows
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

// MARK: - Enforcer

/// While a session runs, apps allowed only through window rules keep just the
/// windows whose title matched: everything else in them is minimised, and
/// comes back when the session ends. A window that matched once stays
/// allowed for the session even when its title changes (an editor switching
/// files), while new windows are judged by title as they appear.
@MainActor
final class WindowEnforcer: LockListener {
    private static let log = Logger(subsystem: "com.tunnelvision.timer", category: "window-enforcer")

    /// An untitled window may be mid-creation; it is minimised only after
    /// staying untitled this long.
    static let untitledGrace: TimeInterval = 1.5
    static let sweepInterval: Duration = .seconds(1)

    private let windows: WindowManaging
    private let clock: () -> Date
    private let autoSweep: Bool

    private(set) var patterns: [String: [String]] = [:]
    private var sessionPatterns: [String: [String]] = [:]
    /// Windows admitted this session, per bundle.
    private var allowedWindowIDs: [String: Set<CGWindowID>] = [:]
    /// Windows this layer minimised, per pid, to restore on unlock.
    private(set) var minimizedByUs: [pid_t: Set<CGWindowID>] = [:]
    private var untitledSince: [CGWindowID: Date] = [:]
    private var observedPIDs: Set<pid_t> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var sweepTask: Task<Void, Never>?
    private var lastNoticeAt: [String: Date] = [:]
    private var warnedUntrusted = false

    private(set) var isActive = false

    /// A window was minimised: (app name, bundle id, window title).
    var onBlockedWindow: ((_ appName: String, _ bundleID: String, _ title: String) -> Void)?

    init(
        windows: WindowManaging = AccessibilityWindowManager(),
        clock: @escaping () -> Date = { Date() },
        autoSweep: Bool = true
    ) {
        self.windows = windows
        self.clock = clock
        self.autoSweep = autoSweep
    }

    // MARK: LockListener

    func lockStateChanged(active: Bool, rules: [Rule], mode: Mode) {
        if active {
            lock(rules: rules)
        } else {
            unlock()
        }
    }

    // MARK: Session lock

    func lock(rules: [Rule]) {
        let next = WindowLockPolicy.titlePatterns(rules: rules)
        guard !next.isEmpty else {
            unlock()
            return
        }
        guard windows.isTrusted else {
            if !warnedUntrusted {
                Self.log.info("window rules present but Accessibility is not granted — window discipline inactive")
                warnedUntrusted = true
            }
            unlock()
            return
        }
        // Bundles that left the disciplined set (allowed whole now) get their
        // windows back at once.
        for bundle in patterns.keys where next[bundle] == nil {
            allowedWindowIDs[bundle] = nil
            sessionPatterns[bundle] = nil
            for app in windows.runningApplications() where app.bundleID == bundle {
                restore(pid: app.pid)
            }
        }
        patterns = next
        isActive = true
        Self.log.info("window lock: \(next.count) app(s) by window title")
        sweepAll()
        startWatching()
        if autoSweep {
            startSweepLoop()
        }
    }

    func unlock() {
        guard isActive else { return }
        Self.log.info("window unlock")
        isActive = false
        sweepTask?.cancel()
        sweepTask = nil
        stopWatching()
        for pid in minimizedByUs.keys {
            restore(pid: pid)
        }
        patterns = [:]
        sessionPatterns = [:]
        allowedWindowIDs = [:]
        untitledSince = [:]
        lastNoticeAt = [:]
    }

    /// "Allow for this session" from the notice: the title becomes a pattern
    /// for the rest of the session and matching windows come back.
    func allowForSession(bundleID: String, titlePattern: String) {
        let pattern = titlePattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard isActive, !pattern.isEmpty else { return }
        sessionPatterns[bundleID, default: []].append(pattern)
        Self.log.info("allow-for-session: \(bundleID, privacy: .public) window “\(pattern, privacy: .public)”")
        for app in windows.runningApplications() where app.bundleID == bundleID {
            let ours = minimizedByUs[app.pid] ?? []
            guard !ours.isEmpty else { continue }
            for window in windows.windows(forPID: app.pid) where ours.contains(window.id) {
                guard WindowLockPolicy.matches(title: window.title, patterns: [pattern]) else { continue }
                windows.setMinimized(false, windowID: window.id, pid: app.pid)
                minimizedByUs[app.pid]?.remove(window.id)
                allowedWindowIDs[bundleID, default: []].insert(window.id)
            }
        }
    }

    // MARK: Sweeps

    /// Judges every window of every disciplined app that is running.
    func sweepAll() {
        guard isActive else { return }
        for app in windows.runningApplications() where app.isRegularApp && !app.isSelf {
            sweep(app)
        }
    }

    /// One app: windows that matched (now or earlier this session) stay,
    /// the rest are minimised.
    func sweep(_ app: ProcessSnapshot) {
        guard isActive, let bundle = app.bundleID, let active = activePatterns(for: bundle) else { return }
        var allowed = allowedWindowIDs[bundle] ?? []
        for window in windows.windows(forPID: app.pid) where window.isStandard {
            if allowed.contains(window.id) {
                untitledSince[window.id] = nil
                restoreIfMinimizedByUs(window, app: app)
                continue
            }
            let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, WindowLockPolicy.matches(title: title, patterns: active) {
                allowed.insert(window.id)
                untitledSince[window.id] = nil
                restoreIfMinimizedByUs(window, app: app)
                continue
            }
            if window.isMinimized { continue }
            if title.isEmpty {
                let since = untitledSince[window.id] ?? clock()
                untitledSince[window.id] = since
                if clock().timeIntervalSince(since) < Self.untitledGrace { continue }
            }
            if windows.setMinimized(true, windowID: window.id, pid: app.pid) {
                minimizedByUs[app.pid, default: []].insert(window.id)
                Self.log.info("minimised \(app.name, privacy: .public) window “\(title, privacy: .public)”")
                notifyBlocked(app, title: title)
            }
        }
        allowedWindowIDs[bundle] = allowed
    }

    /// A window this layer minimised earlier (it was untitled past its grace)
    /// that now matches a rule comes back on screen.
    private func restoreIfMinimizedByUs(_ window: AXWindowSnapshot, app: ProcessSnapshot) {
        guard minimizedByUs[app.pid]?.contains(window.id) == true else { return }
        if windows.setMinimized(false, windowID: window.id, pid: app.pid) {
            minimizedByUs[app.pid]?.remove(window.id)
            Self.log.info("restored \(app.name, privacy: .public) window “\(window.title, privacy: .public)”")
        }
    }

    private func activePatterns(for bundle: String) -> [String]? {
        guard let base = patterns[bundle] else { return nil }
        return base + (sessionPatterns[bundle] ?? [])
    }

    /// Windows this layer minimised in the app come back.
    private func restore(pid: pid_t) {
        guard let ours = minimizedByUs.removeValue(forKey: pid), !ours.isEmpty else { return }
        let current = windows.windows(forPID: pid)
        for window in current where ours.contains(window.id) && window.isMinimized {
            windows.setMinimized(false, windowID: window.id, pid: pid)
        }
    }

    private func notifyBlocked(_ app: ProcessSnapshot, title: String) {
        guard let bundle = app.bundleID else { return }
        let now = clock()
        if let last = lastNoticeAt[bundle], now.timeIntervalSince(last) < 4 { return }
        lastNoticeAt[bundle] = now
        onBlockedWindow?(app.name, bundle, title)
    }

    // MARK: Watchdogs

    private func startSweepLoop() {
        guard sweepTask == nil else { return }
        sweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sweepInterval)
                guard !Task.isCancelled, let self, self.isActive else { return }
                self.sweepAll()
            }
        }
    }

    private func startWatching() {
        for app in windows.runningApplications() where app.bundleID.map({ patterns[$0] != nil }) == true {
            observe(app)
        }
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.handleAppEvent(app) }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.handleAppEvent(app) }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.forget(pid: app.processIdentifier) }
        })
    }

    private func stopWatching() {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
        for pid in observedPIDs {
            windows.stopObserving(pid: pid)
        }
        observedPIDs = []
    }

    private func handleAppEvent(_ app: NSRunningApplication) {
        guard isActive, !app.isTerminated, let bundle = app.bundleIdentifier, patterns[bundle] != nil else { return }
        let snapshot = ProcessSnapshot(
            pid: app.processIdentifier,
            name: app.localizedName ?? bundle,
            bundleID: bundle,
            isSelf: false,
            isRegularApp: app.activationPolicy == .regular
        )
        observe(snapshot)
        sweep(snapshot)
    }

    private func observe(_ app: ProcessSnapshot) {
        guard !observedPIDs.contains(app.pid) else { return }
        observedPIDs.insert(app.pid)
        windows.observe(pid: app.pid) { [weak self] in
            self?.sweep(app)
        }
    }

    private func forget(pid: pid_t) {
        if observedPIDs.remove(pid) != nil {
            windows.stopObserving(pid: pid)
        }
        minimizedByUs[pid] = nil
    }
}
