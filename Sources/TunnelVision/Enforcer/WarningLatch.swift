/// The last warning an enforcement layer reported, so it reports changes
/// only: a sweep every second must not re-send the same message.
struct WarningLatch {
    private(set) var current: String?

    /// True, and the message is kept, when it differs from the last one.
    mutating func update(_ message: String?) -> Bool {
        guard message != current else { return false }
        current = message
        return true
    }
}
