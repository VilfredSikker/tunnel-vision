import Foundation

/// Finds web links in task text (checklist items, descriptions) and gives
/// each a short label, so a long URL reads as `owner/repo#12` or
/// `host/…/slug` instead of filling the row. Only http and https links count,
/// as for the URLs a task opens.
enum LinkText {
    struct Segment: Equatable {
        var text: String
        /// Set for a link; `text` is then its short label.
        var url: URL?
    }

    /// Longest label before it is cut with an ellipsis.
    static let maxLabelLength = 36

    /// NSDataDetector, like NSRegularExpression, is immutable and safe to
    /// share across threads.
    nonisolated(unsafe) private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func segments(_ text: String) -> [Segment] {
        guard let detector else { return [Segment(text: text)] }
        var segments: [Segment] = []
        var cursor = text.startIndex
        let whole = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: whole) {
            // The detector reads an email address as a mailto link; only
            // what it sees as a web link counts.
            guard let scheme = match.url?.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let range = Range(match.range, in: text),
                  let url = AppState.openableURL(String(text[range])) else { continue }
            if cursor < range.lowerBound {
                segments.append(Segment(text: String(text[cursor..<range.lowerBound])))
            }
            segments.append(Segment(text: shortLabel(for: url), url: url))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            segments.append(Segment(text: String(text[cursor...])))
        }
        return segments
    }

    /// The text with each link swapped for its short label.
    static func readable(_ text: String) -> String {
        segments(text).map(\.text).joined()
    }

    /// The text with links as tappable, short-labelled runs.
    static func attributed(_ text: String) -> AttributedString {
        segments(text).reduce(into: AttributedString()) { result, segment in
            var run = AttributedString(segment.text)
            run.link = segment.url
            result += run
        }
    }

    static func shortLabel(for url: URL) -> String {
        var host = (url.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let parts = url.pathComponents.filter { $0 != "/" }

        // GitHub: owner/repo, and #n for a pull request or issue.
        if host == "github.com", parts.count >= 2 {
            let repo = "\(parts[0])/\(parts[1])"
            if parts.count >= 4, ["pull", "issues"].contains(parts[2]) {
                return "\(repo)#\(parts[3])"
            }
            return cut(repo)
        }
        // Linear: the issue key, e.g. ENG-123.
        if host == "linear.app", let index = parts.firstIndex(of: "issue"), index + 1 < parts.count {
            return parts[index + 1]
        }
        // Whole when it fits; otherwise the middle of the path goes.
        let full = ([host] + parts).joined(separator: "/")
        guard full.count > maxLabelLength, parts.count > 1 else { return cut(full) }
        return cut("\(host)/…/\(parts[parts.count - 1])")
    }

    private static func cut(_ label: String) -> String {
        label.count > maxLabelLength ? String(label.prefix(maxLabelLength - 1)) + "…" : label
    }
}
