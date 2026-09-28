import Foundation

/// Names shared by the app, its MCP helper and the tests. Changing one here
/// moves every user's data, so it is a migration, not a rename.
public enum AppIdentity {
    public static let bundleID = "com.tunnelvision.timer"

    /// The enclosing app's `CFBundleShortVersionString` for a helper at
    /// `Tunnel Vision.app/Contents/Helpers/<tool>`; "dev" outside a bundle.
    public static func helperVersion(executable: URL? = Bundle.main.executableURL) -> String {
        guard let executable else { return "dev" }
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else { return "dev" }
        return version
    }

    /// `~/Library/Application Support/TunnelVision`: archive, victim store
    /// and control socket.
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TunnelVision", isDirectory: true)
    }
}
