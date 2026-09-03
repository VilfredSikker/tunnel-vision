import AppKit
import CoreGraphics
import Foundation

// MARK: - Screen Recording permission

/// Titles (and later thumbnails) of other apps' windows need Screen Recording.
/// Without it the overlay still works at app granularity with icon + name.
enum ScreenCapturePermission {
    static var isAllowed: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// One-shot system prompt (System Settings > Privacy & Security).
    static func request() {
        CGRequestScreenCaptureAccess()
    }

    static var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    }
}

// MARK: - Accessibility (window titles without Screen Recording)

/// Window titles come from the Accessibility API when Screen Recording is
/// not granted. Layer 2 (window-level locking) needs Accessibility anyway,
/// and unlike Screen Recording it has no periodic re-approval nag.
enum AccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// System prompt with a deep link to Privacy & Security > Accessibility.
    static func request() {
        // kAXTrustedCheckOptionPrompt by value: the imported global is a
        // `var`, which Swift 6 refuses to read across isolation.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

/// Private but long-stable (yabai, AltTab and Rectangle rely on it): the
/// CGWindowID behind an accessibility window element, which is what matches
/// AX titles to CGWindowList entries.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

enum AccessibilityTitles {
    /// Titles of the given apps' windows keyed by CGWindowID; empty without
    /// the permission. A busy or frozen app is skipped after a short timeout
    /// instead of stalling the picker.
    static func titles(forPIDs pids: [pid_t]) -> [CGWindowID: String] {
        guard AXIsProcessTrusted() else { return [:] }
        var titles: [CGWindowID: String] = [:]
        for pid in pids {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.25)
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                  let windows = windowsValue as? [AXUIElement] else { continue }
            for window in windows {
                var windowID: CGWindowID = 0
                guard _AXUIElementGetWindow(window, &windowID) == .success, windowID != 0 else { continue }
                var titleValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                      let title = (titleValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else { continue }
                titles[windowID] = title
            }
        }
        return titles
    }
}

// MARK: - Catalogue

/// One on-screen window of another app.
struct PickerWindowInfo: Identifiable, Hashable, Sendable {
    let id: CGWindowID
    let appPID: pid_t
    /// Nil when Screen Recording is not granted (or the window is untitled).
    let title: String?
}

/// One app with its on-screen windows.
struct PickerAppInfo: Identifiable, Hashable, Sendable {
    let id: String // bundle id
    let pid: pid_t
    let name: String
    let bundleID: String
    let icon: NSImage?
    var windows: [PickerWindowInfo]
}

/// A running application as the catalogue sees it: the raw input that
/// `WindowCatalogue.assemble` filters, so the listing policy is testable
/// without a live workspace.
struct RunningAppRecord: Sendable {
    let pid: pid_t
    let bundleID: String?
    let name: String?
    let activationPolicy: NSApplication.ActivationPolicy
    let icon: NSImage?
}

/// One window straight from CGWindowList, before grouping.
struct WindowRecord: Sendable {
    let id: CGWindowID
    let ownerPID: pid_t
    let layer: Int
    /// Nil when the window server did not report bounds.
    let bounds: CGRect?
    let title: String?
}

/// Lists the apps Cmd-Tab and Mission Control would show — regular
/// (Dock-visible) apps — each with its on-screen windows. Window info comes
/// from CGWindowList (no permission needed for owners and counts); apps are
/// resolved through NSWorkspace so picks can become rules.
@MainActor
enum WindowCatalogue {
    /// Anything smaller is a menu leftover, tooltip or palette scrap.
    private nonisolated static let minimumWindowSize = CGSize(width: 80, height: 50)

    static func onScreenApps() -> [PickerAppInfo] {
        let apps = NSWorkspace.shared.runningApplications.map { app in
            RunningAppRecord(
                pid: app.processIdentifier,
                bundleID: app.bundleIdentifier,
                name: app.localizedName,
                activationPolicy: app.activationPolicy,
                icon: app.icon
            )
        }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        // CGWindowList carries titles only with Screen Recording; otherwise
        // the Accessibility API supplies them per window id.
        var extraTitles: [CGWindowID: String] = [:]
        if !ScreenCapturePermission.isAllowed {
            let pids = apps.filter { $0.activationPolicy == .regular && $0.pid != selfPID }.map(\.pid)
            extraTitles = AccessibilityTitles.titles(forPIDs: pids)
        }
        return assemble(apps: apps, windows: onScreenWindows(), extraTitles: extraTitles, selfPID: selfPID)
    }

    /// Pure grouping and filtering. Only regular apps other than ourselves
    /// are listed — background agents, menu-bar helpers and system UI never
    /// appear in Cmd-Tab and cannot be picked here either. A regular app with
    /// no window on this Space (hidden, minimised, elsewhere) is still listed
    /// so it can be allowed as a whole app. `extraTitles` fills in titles the
    /// window list did not carry (Accessibility, keyed by window id).
    nonisolated static func assemble(
        apps: [RunningAppRecord],
        windows: [WindowRecord],
        extraTitles: [CGWindowID: String] = [:],
        selfPID: pid_t
    ) -> [PickerAppInfo] {
        var windowsByPID: [pid_t: [PickerWindowInfo]] = [:]
        for window in windows {
            guard window.layer == 0, window.ownerPID > 0 else { continue }
            if let bounds = window.bounds,
               bounds.width < minimumWindowSize.width || bounds.height < minimumWindowSize.height {
                continue
            }
            let listed = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = listed?.isEmpty == false ? listed : extraTitles[window.id]
            windowsByPID[window.ownerPID, default: []].append(
                PickerWindowInfo(id: window.id, appPID: window.ownerPID, title: title)
            )
        }

        var byBundle: [String: PickerAppInfo] = [:]
        for app in apps {
            guard app.activationPolicy == .regular, app.pid > 0, app.pid != selfPID else { continue }
            guard let bundleID = app.bundleID, !bundleID.isEmpty else { continue }
            let windows = windowsByPID[app.pid] ?? []
            if var existing = byBundle[bundleID] {
                // Two instances of one app share the entry: rules are per bundle.
                existing.windows += windows
                byBundle[bundleID] = existing
            } else {
                byBundle[bundleID] = PickerAppInfo(
                    id: bundleID,
                    pid: app.pid,
                    name: app.name ?? bundleID,
                    bundleID: bundleID,
                    icon: app.icon,
                    windows: windows
                )
            }
        }

        return byBundle.values
            .map { app in
                var sorted = app
                sorted.windows.sort { ($0.title ?? "zz") < ($1.title ?? "zz") }
                return sorted
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func onScreenWindows() -> [WindowRecord] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return raw.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            let bounds = (info[kCGWindowBounds as String] as? [String: Any])
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            return WindowRecord(
                id: number,
                ownerPID: ownerPID,
                layer: info[kCGWindowLayer as String] as? Int ?? -1,
                bounds: bounds,
                title: info[kCGWindowName as String] as? String
            )
        }
    }
}

// MARK: - Selection → rules

/// A single window picked by title.
struct PickedWindowRef: Hashable, Sendable {
    let bundleID: String
    let windowID: CGWindowID
    let title: String?
}

/// Pure mapping from picks to allowlist rules (testable).
enum SelectionBuilder {
    /// Whole-app picks become app-scope rules; window picks become window
    /// rules carrying the bundle id, so later layers can enforce per-window.
    static func rules(wholeAppBundles: Set<String>, windows: [PickedWindowRef]) -> [Rule] {
        var rules: [Rule] = wholeAppBundles.sorted().map { Rule(bundleID: $0, scope: .app) }
        for window in windows {
            guard let title = window.title?.trimmingCharacters(in: .whitespaces),
                  !title.isEmpty else { continue }
            // A window pick implies its app at layer 1 (only whole-app
            // enforcement exists yet); the pattern targets the window later.
            if !wholeAppBundles.contains(window.bundleID) {
                rules.append(Rule(bundleID: window.bundleID, scope: .window, pattern: title))
            }
        }
        return rules
    }

    /// Seed state from existing rules: app-scope rules mark their bundle;
    /// window-scope rules mark matching windows when present.
    static func seed(
        apps: [PickerAppInfo],
        rules: [Rule]
    ) -> (wholeAppBundles: Set<String>, windowIDs: Set<CGWindowID>) {
        var whole = Set<String>()
        var windows = Set<CGWindowID>()
        for rule in rules where rule.effect == .allow {
            switch rule.scope {
            case .app:
                whole.insert(rule.bundleID)
            case .window:
                let pattern = rule.pattern.lowercased()
                guard !pattern.isEmpty else { continue }
                for app in apps where app.bundleID == rule.bundleID {
                    for window in app.windows where (window.title?.lowercased() ?? "").contains(pattern) {
                        windows.insert(window.id)
                    }
                }
            case .url:
                whole.insert(rule.bundleID) // layer 3 discipline inside an allowed app
            }
        }
        return (whole, windows)
    }
}
