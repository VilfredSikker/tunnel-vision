import AppKit
import ApplicationServices
import os
import SwiftUI

/// What the user clicked while the pick was armed.
struct PickedWindow: Equatable, Sendable {
    let pid: pid_t
    let bundleID: String
    let appName: String
    let title: String
    /// Nil when the window server id could not be read.
    let windowID: CGWindowID?
}

/// Which layer a pick goes to: the one that would otherwise hide the
/// window again.
enum PickAllowance: Equatable {
    /// Inside an app judged by window title: allow that one window.
    case windowID(CGWindowID)
    /// Same, when the window id could not be read: allow by title.
    case windowTitle(String)
    /// Inside a browser under site rules: allow the window by title.
    case browserTitle(String)
    /// Otherwise the whole app.
    case app
    /// Nothing identifies the window; allowing the app would not help.
    case unidentifiable

    static func resolve(_ window: PickedWindow, windowLayerJudges: Bool, browserLayerJudges: Bool) -> PickAllowance {
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if browserLayerJudges {
            return title.isEmpty ? .unidentifiable : .browserTitle(title)
        }
        if windowLayerJudges {
            // By id first: a title allowance matches by substring, so
            // picking "Inbox" would let every window with "Inbox" in its
            // title through. The id keeps it to the window clicked.
            if let id = window.windowID { return .windowID(id) }
            return title.isEmpty ? .unidentifiable : .windowTitle(title)
        }
        return .app
    }
}

/// Which clicks count as picking a window. The Dock, the menu bar and
/// system UI get clicked on the way to a hidden app; those clicks are
/// ignored and the pick stays armed.
enum PickFilter {
    static func accepts(bundleID: String, isRegularApp: Bool, hitIsInWindow: Bool) -> Bool {
        isRegularApp && hitIsInWindow && !LockPolicy.exemptSystemBundles.contains(bundleID)
    }
}

/// Hotkey pick (DESIGN_BRIEF §5): press the shortcut, click any window, and
/// it is allowed for the rest of the session. While armed, the app, window
/// and browser layers hold off and frozen apps run again, so a hidden app
/// can be brought up (Cmd-Tab, the Dock) and its window clicked. The pick
/// disarms on the click, on Esc, after a timeout, or when the lock lifts.
@MainActor
final class WindowPickController: LockListener {
    private static let log = Logger(subsystem: "com.tunnelvision.timer", category: "pick")
    static let timeout: Duration = .seconds(15)

    /// Holds or releases enforcement around the pick.
    var onHold: ((Bool) -> Void)?
    /// A window was picked.
    var onPicked: ((PickedWindow) -> Void)?

    private(set) var isArmed = false
    private var monitors: [Any] = []
    private var timeoutTask: Task<Void, Never>?
    private var banner: NSPanel?

    func toggle() {
        isArmed ? disarm() : arm()
    }

    /// The pick belongs to one locked session: when the lock lifts (pause,
    /// break, stop) it disarms, so it cannot outlive the session and release
    /// a hold the next session never set.
    func lockStateChanged(active: Bool, rules: [Rule], mode: Mode) {
        if !active {
            disarm()
        }
    }

    func arm() {
        guard !isArmed else { return }
        isArmed = true
        onHold?(true)
        Self.log.info("pick armed")
        showBanner()
        // Global monitors see clicks in other apps; they never consume the
        // event, so the click also lands in the window as usual.
        if let click = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pick(at: NSEvent.mouseLocation) }
        }) {
            monitors.append(click)
        }
        if let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.disarm() }
            return nil
        }) {
            monitors.append(key)
        }
        if let key = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.disarm() }
        }) {
            monitors.append(key)
        }
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.timeout)
            guard !Task.isCancelled else { return }
            self?.disarm()
        }
    }

    func disarm() {
        guard isArmed else { return }
        isArmed = false
        resolving = false
        arming += 1
        timeoutTask?.cancel()
        timeoutTask = nil
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        banner?.orderOut(nil)
        banner = nil
        onHold?(false)
        Self.log.info("pick disarmed")
    }

    /// A click is being looked up; further clicks wait for it.
    private var resolving = false
    /// Counts armings, so a lookup that outlives its arming (disarm, then
    /// re-arm within the lookup) cannot complete a pick for the next one.
    private var arming = 0

    private func pick(at cocoaPoint: NSPoint) {
        guard isArmed, !resolving else { return }
        let armedAs = arming
        // AX uses top-left origin coordinates of the primary display; the
        // screens are read here, the rest runs off the main thread.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: cocoaPoint.x, y: primaryHeight - cocoaPoint.y)
        resolving = true
        Task { @MainActor [weak self] in
            let window = await Task.detached(priority: .userInitiated) {
                Self.window(atAXPoint: point)
            }.value
            guard let self, self.arming == armedAs else { return }
            self.resolving = false
            self.picked(window)
        }
    }

    private func picked(_ window: PickedWindow?) {
        guard isArmed else { return }
        guard let window else {
            // The Dock, the menu bar or empty desktop: still armed.
            Self.log.info("pick: no app window under the click")
            return
        }
        guard window.pid != ProcessInfo.processInfo.processIdentifier else { return }
        Self.log.info("picked \(window.bundleID, privacy: .public) “\(window.title, privacy: .public)”")
        // Allow first, then release the hold, so the release sweep already
        // sees the window as allowed.
        onPicked?(window)
        disarm()
    }

    /// The window under a point in Accessibility coordinates (the same
    /// source as window rules). Every call can wait on the app under the
    /// click, so this runs off the main thread.
    nonisolated static func window(atAXPoint point: CGPoint) -> PickedWindow? {
        var element: AXUIElement?
        // One click, but a busy app under it still gets only the short
        // timeout, not the default six seconds of a frozen menu bar. A
        // timeout on the system-wide element is the process-wide default,
        // so it is put back (0) straight after the hit test.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, LiveAXWindowBackend.timeout)
        let hit = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
        AXUIElementSetMessagingTimeout(systemWide, 0)
        guard hit == .success, let element else { return nil }
        AXUIElementSetMessagingTimeout(element, LiveAXWindowBackend.timeout)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier else { return nil }
        // The hit is usually a control inside the window; its window
        // attribute leads to the window itself. No window (a Dock item, a
        // menu bar extra) is not a pick.
        var window: AXUIElement?
        if (attribute(element, kAXRoleAttribute) as? String) == kAXWindowRole {
            window = element
        } else if let value = attribute(element, kAXWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
            let parent = unsafeDowncast(value, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(parent, LiveAXWindowBackend.timeout)
            window = parent
        }
        guard PickFilter.accepts(
            bundleID: bundleID,
            isRegularApp: app.activationPolicy == .regular,
            hitIsInWindow: window != nil
        ), let window else { return nil }
        let title = (attribute(window, kAXTitleAttribute) as? String) ?? ""
        var windowID: CGWindowID = 0
        let hasID = _AXUIElementGetWindow(window, &windowID) == .success && windowID != 0
        return PickedWindow(
            pid: pid,
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            title: title,
            windowID: hasID ? windowID : nil
        )
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    // MARK: Banner

    private func showBanner() {
        let hosting = NSHostingView(rootView: PickBanner())
        let size = hosting.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
        banner = panel
    }
}

private struct PickBanner: View {
    var body: some View {
        Label("Click a window to allow it for this session · Esc cancels", systemImage: "cursorarrow.click.2")
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(Capsule())
    }
}
