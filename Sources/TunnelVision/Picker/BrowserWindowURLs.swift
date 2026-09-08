import AppKit
import Foundation
import os

/// Names browser windows by the URL of their active tab, asked over each
/// browser's AppleScript dictionary (Automation permission, one prompt per
/// browser). Chromium forks share Chrome's dictionary; Safari has its own.
/// Firefox exposes no tabs to scripting and is skipped.
enum BrowserWindowURLs {
    private static let log = Logger(subsystem: "com.tunnelvision.timer", category: "browser-urls")

    static func supports(_ bundleID: String) -> Bool {
        Browsers.supports(bundleID)
    }

    /// One scripted window: geometry (top-left origin, like CGWindowList),
    /// title and active tab URL.
    struct ScriptedWindow: Equatable, Sendable {
        let bounds: CGRect
        let name: String
        let url: String
    }

    /// URL by window id for every browser window it could identify.
    @MainActor
    static func fetch(for apps: [PickerAppInfo]) async -> [CGWindowID: String] {
        var result: [CGWindowID: String] = [:]
        for app in apps where supports(app.bundleID) && !app.windows.isEmpty {
            guard let output = await OSAScript.run(script(forBundle: app.bundleID)) else {
                log.info("no URL answer from \(app.bundleID, privacy: .public) (not granted, or the browser is busy)")
                continue
            }
            let matched = match(windows: app.windows, records: parse(output))
            result.merge(matched) { _, new in new }
        }
        return result
    }

    // MARK: Script

    /// Lists every window as `x1 TAB y1 TAB x2 TAB y2 TAB name TAB url`.
    static func script(forBundle bundleID: String) -> String {
        let tabURL = Browsers.isSafari(bundleID) ? "URL of current tab of w" : "URL of active tab of w"
        return """
        with timeout of 3 seconds
            tell application id "\(bundleID)"
                set out to ""
                repeat with w in windows
                    set b to bounds of w
                    set u to ""
                    try
                        set u to \(tabURL)
                    end try
                    set out to out & (item 1 of b) & tab & (item 2 of b) & tab & (item 3 of b) & tab & (item 4 of b) & tab & (name of w) & tab & u & linefeed
                end repeat
                return out
            end tell
        end timeout
        """
    }

    static func parse(_ output: String) -> [ScriptedWindow] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 6,
                  let x1 = Double(parts[0]), let y1 = Double(parts[1]),
                  let x2 = Double(parts[2]), let y2 = Double(parts[3]) else { return nil }
            let url = parts[5...].joined(separator: "\t").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return nil }
            return ScriptedWindow(
                bounds: CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1),
                name: parts[4],
                url: url
            )
        }
    }

    /// Titles first (exact), then geometry, each scripted window used once.
    static func match(
        windows: [PickerWindowInfo],
        records: [ScriptedWindow],
        tolerance: CGFloat = 8
    ) -> [CGWindowID: String] {
        var result: [CGWindowID: String] = [:]
        var remaining = records
        for window in windows {
            guard let title = window.title,
                  let index = remaining.firstIndex(where: { $0.name == title }) else { continue }
            result[window.id] = remaining.remove(at: index).url
        }
        for window in windows where result[window.id] == nil {
            guard let bounds = window.bounds,
                  let index = remaining.firstIndex(where: { close($0.bounds, bounds, tolerance: tolerance) }) else { continue }
            result[window.id] = remaining.remove(at: index).url
        }
        return result
    }

    private static func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }
}
