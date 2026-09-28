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
/// it is allowed for the rest of the session. While armed, the app and
/// window layers hold off, so a hidden app can be brought up (Cmd-Tab, the
/// Dock) and its window clicked. The pick disarms on the click, on Esc, or
/// after a timeout. Frozen apps cannot be brought up while stopped.
@MainActor
final class WindowPickController {
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

    private func pick(at cocoaPoint: NSPoint) {
        guard isArmed else { return }
        guard let window = Self.window(at: cocoaPoint) else {
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

    /// The window under a point in AppKit screen coordinates, via
    /// Accessibility (the same source as window rules).
    static func window(at cocoaPoint: NSPoint) -> PickedWindow? {
        // AX uses top-left origin coordinates of the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: cocoaPoint.x, y: primaryHeight - cocoaPoint.y)
        var element: AXUIElement?
        // One click, but a busy app under it still gets only the short
        // timeout, not the default six seconds of a frozen menu bar.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, LiveAXWindowBackend.timeout)
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
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
            window = unsafeDowncast(value, to: AXUIElement.self)
        }
        guard PickFilter.accepts(
            bundleID: bundleID,
            isRegularApp: app.activationPolicy == .regular,
            hitIsInWindow: window != nil
        ), let window else { return nil }
        let title = (attribute(window, kAXTitleAttribute) as? String) ?? ""
        return PickedWindow(pid: pid, bundleID: bundleID, appName: app.localizedName ?? bundleID, title: title)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
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
