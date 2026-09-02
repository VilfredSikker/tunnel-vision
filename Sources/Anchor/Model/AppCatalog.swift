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

    /// Running applications with a bundle identifier, sorted by name.
    static var runningApps: [RunningApp] {
        NSWorkspace.shared.runningApplications
            .compactMap { app -> RunningApp? in
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
