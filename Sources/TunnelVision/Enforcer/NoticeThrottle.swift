import Foundation

/// One blocked-notice per key every few seconds, so an app hammering the
/// same rule does not stack notices.
struct NoticeThrottle {
    static let interval: TimeInterval = 4

    private var lastAt: [String: Date] = [:]

    /// True, and the key is stamped, when a notice for it may show now.
    mutating func allow(_ key: String, now: Date = Date()) -> Bool {
        if let last = lastAt[key], now.timeIntervalSince(last) < Self.interval { return false }
        lastAt[key] = now
        return true
    }

    mutating func reset() {
        lastAt = [:]
    }
}
