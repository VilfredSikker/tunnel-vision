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

/// Enumerates on-screen windows via CGWindowList (no permission needed for
/// owner names and counts). Grouped by owning app, resolved to bundle ids
/// through NSRunningApplication so picks can become rules.
@MainActor
enum WindowCatalogue {
    /// Owners that are not user apps.
    private static let ignoredOwners: Set<String> = ["Anchor", "Window Server", "Dock", "Control Center"]

    static func onScreenApps() -> [PickerAppInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }

        var windowsByPID: [pid_t: [PickerWindowInfo]] = [:]
        var ownerNames: [pid_t: String] = [:]

        for info in raw {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID > 0 else { continue }
            guard let ownerName = info[kCGWindowOwnerName as String] as? String,
                  !ignoredOwners.contains(ownerName) else { continue }
            guard let number = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            if let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
               let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
               bounds.width < 80 || bounds.height < 50 {
                continue // menu leftovers, tiny auxiliary windows
            }
            let title = (info[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            windowsByPID[ownerPID, default: []].append(
                PickerWindowInfo(id: number, appPID: ownerPID, title: title?.isEmpty == false ? title : nil)
            )
            ownerNames[ownerPID] = ownerName
        }

        var apps: [PickerAppInfo] = []
        for (pid, windows) in windowsByPID {
            let running = NSRunningApplication(processIdentifier: pid)
            guard let bundleID = running?.bundleIdentifier, !bundleID.isEmpty else { continue }
            let name = running?.localizedName ?? ownerNames[pid] ?? bundleID
            apps.append(PickerAppInfo(
                id: bundleID,
                pid: pid,
                name: name,
                bundleID: bundleID,
                icon: running?.icon,
                windows: windows.sorted { ($0.title ?? "zz") < ($1.title ?? "zz") }
            ))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
