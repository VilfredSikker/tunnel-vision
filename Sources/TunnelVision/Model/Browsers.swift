import AppKit
import Foundation

/// The browsers Tunnel Vision can talk to over their AppleScript dictionaries:
/// Chromium forks share Chrome's, Safari has its own. Firefox exposes no
/// tabs to scripting and is left out.
enum Browsers {
    static let chromiumBundles: Set<String> = [
        "net.imput.helium",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",
    ]
    static let safariBundles: Set<String> = ["com.apple.Safari"]

    static var supported: Set<String> { chromiumBundles.union(safariBundles) }

    static func supports(_ bundleID: String) -> Bool {
        supported.contains(bundleID)
    }

    static func isSafari(_ bundleID: String) -> Bool {
        safariBundles.contains(bundleID)
    }

    /// A supported browser on this Mac, for the settings list.
    struct Installed: Identifiable, Equatable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// Supported browsers that are installed, by name.
    @MainActor
    static func installed() -> [Installed] {
        supported.compactMap { bundleID -> Installed? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return Installed(bundleID: bundleID, name: url.deletingPathExtension().lastPathComponent)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The browsers whose windows Tunnel Vision steers during a session: every
    /// supported one except those switched off in Settings.
    static func managed(unmanaged: Set<String>) -> Set<String> {
        supported.subtracting(unmanaged)
    }
}
