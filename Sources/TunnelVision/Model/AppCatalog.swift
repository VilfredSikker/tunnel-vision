import AppKit
import Foundation

/// Lookup of installed apps by bundle identifier: display name and icon.
/// Used for rule rows and the icon strip on task rows.
@MainActor
enum AppCatalog {
    private static var iconCache: [String: NSImage] = [:]
    private static var nameCache: [String: String] = [:]

    struct RunningApp: Identifiable {
        let name: String
        let bundleID: String
        let icon: NSImage?
        var id: String { bundleID }
    }

    /// Running regular (Cmd-Tab) apps with a bundle identifier, sorted by
    /// name. Background agents and menu-bar helpers are not offered: they
    /// are never enforced, so a rule for them would be inert.
    static var runningApps: [RunningApp] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .compactMap { app -> RunningApp? in
                guard app.activationPolicy == .regular, app.processIdentifier != selfPID else { return nil }
                guard let bundleID = app.bundleIdentifier else { return nil }
                return RunningApp(
                    name: app.localizedName ?? bundleID,
                    bundleID: bundleID,
                    icon: app.icon
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func displayName(forBundleID bundleID: String) -> String? {
        if let cached = nameCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let name = url.deletingPathExtension().lastPathComponent
        nameCache[bundleID] = name
        return name
    }

    static func icon(forBundleID bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = icon
        return icon
    }
}
