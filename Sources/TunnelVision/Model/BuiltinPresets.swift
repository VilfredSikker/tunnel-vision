import Foundation

/// The four presets that ship with Tunnel Vision.
enum BuiltinPresets {
    static let names = ["Coding", "Writing", "Comms", "Reading"]

    static func all() -> [Preset] {
        [
            Preset(
                name: "Coding",
                isBuiltIn: true,
                mode: .dark,
                rules: [
                    Rule(bundleID: "com.apple.dt.Xcode"),
                    Rule(bundleID: "com.apple.Terminal"),
                    Rule(bundleID: "net.imput.helium", scope: .url, pattern: "docs.google.com"),
                    Rule(bundleID: "net.imput.helium", scope: .url, pattern: "github.com"),
                ],
                urlsToOpen: []
            ),
            Preset(
                name: "Writing",
                isBuiltIn: true,
                mode: .dark,
                rules: [
                    Rule(bundleID: "md.obsidian.Obsidian")
                ],
                urlsToOpen: []
            ),
            Preset(
                name: "Comms",
                isBuiltIn: true,
                mode: .dark,
                rules: [
                    Rule(bundleID: "com.tinyspeck.slackmacgap"),
                    Rule(bundleID: "com.apple.mail")
                ],
                urlsToOpen: []
            ),
            Preset(
                name: "Reading",
                isBuiltIn: true,
                mode: .dark,
                rules: [
                    Rule(bundleID: "net.imput.helium", scope: .url, pattern: "wikipedia.org")
                ],
                urlsToOpen: []
            ),
        ]
    }
}
