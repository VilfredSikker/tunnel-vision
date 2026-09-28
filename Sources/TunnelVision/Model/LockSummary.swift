import Foundation

/// The one-line "what is now locked" confirmation shown when a session
/// starts (DESIGN_BRIEF §5).
enum LockSummary {
    /// - Parameter appName: display name for a bundle id.
    static func describe(rules: [Rule], mode: Mode, appName: (String) -> String) -> String {
        var parts: [String] = []
        var seen = Set<String>()
        func add(_ part: String) {
            if seen.insert(part).inserted { parts.append(part) }
        }
        for rule in rules where rule.effect == .allow && rule.isComplete {
            let pattern = rule.pattern.trimmingCharacters(in: .whitespaces)
            switch rule.scope {
            case .app:
                add(appName(rule.bundleID))
            case .window:
                add("“\(pattern)” in \(appName(rule.bundleID))")
            case .url:
                add("\(pattern) in \(appName(rule.bundleID))")
            case .herdr:
                add("herdr: \(pattern)")
            }
        }
        guard !parts.isEmpty else { return "Nothing is allowed; everything else \(verb(mode))." }
        let shown = parts.prefix(4).joined(separator: ", ")
        let more = parts.count > 4 ? " and \(parts.count - 4) more" : ""
        return "Allowed: \(shown)\(more). Everything else \(verb(mode))."
    }

    private static func verb(_ mode: Mode) -> String {
        switch mode {
        case .dark: "is hidden"
        case .closed: "is quit"
        case .frozen: "is frozen"
        }
    }
}
