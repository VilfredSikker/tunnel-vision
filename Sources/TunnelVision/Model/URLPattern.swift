import Foundation

/// Site rules are `host[/path]` patterns, the form the picker derives from a
/// browser window's URL ("github.com/org/repo"). A pattern matches a page
/// when the page's host is the pattern's host or a subdomain of it, and the
/// page's path starts with the pattern's path at a segment boundary.
enum URLPattern {
    struct Parts: Equatable {
        let host: String
        /// Lowercased, no trailing slash, empty for the site root.
        let path: String
    }

    /// Splits a pattern; a scheme is tolerated and dropped. Nil when there is
    /// no host to match.
    static func parse(_ pattern: String) -> Parts? {
        var text = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: "://") {
            text = String(text[range.upperBound...])
        }
        guard !text.isEmpty else { return nil }
        let slash = text.firstIndex(of: "/") ?? text.endIndex
        let host = String(text[..<slash])
        guard !host.isEmpty else { return nil }
        return Parts(host: host, path: trimSlashes(String(text[slash...])))
    }

    /// Host and path of a web URL; nil for anything that is not http(s).
    static func parse(url raw: String) -> Parts? {
        guard isWeb(raw),
              let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        return Parts(host: host, path: trimSlashes(components.path.lowercased()))
    }

    /// http and https only. `chrome://newtab`, `about:blank` and the like
    /// are not pages and never count as violations.
    static func isWeb(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func matches(_ pattern: String, url: String) -> Bool {
        guard let wanted = parse(pattern), let page = parse(url: url) else { return false }
        return matches(wanted, page)
    }

    static func matches(_ wanted: Parts, _ page: Parts) -> Bool {
        guard page.host == wanted.host || page.host.hasSuffix("." + wanted.host) else { return false }
        if wanted.path.isEmpty { return true }
        return page.path == wanted.path || page.path.hasPrefix(wanted.path + "/")
    }

    static func matchesAny(_ patterns: [String], url: String) -> Bool {
        guard let page = parse(url: url) else { return false }
        return patterns.contains { pattern in
            guard let wanted = parse(pattern) else { return false }
            return matches(wanted, page)
        }
    }

    /// "https://www.reddit.com/r/x" → "reddit.com": the whole-site pattern
    /// for a page. Nil for non-web URLs.
    static func site(fromURL raw: String) -> String? {
        guard let page = parse(url: raw) else { return nil }
        return page.host.hasPrefix("www.") ? String(page.host.dropFirst(4)) : page.host
    }

    /// A URL a browser can be sent to for a pattern: the pattern with https.
    static func url(forPattern pattern: String) -> String? {
        guard let parts = parse(pattern) else { return nil }
        return "https://" + parts.host + parts.path
    }

    private static func trimSlashes(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}
