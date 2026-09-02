import Foundation

enum TimeFormat {
    /// 24:59, or 1:02:03 past an hour. Truncates to the displayed second.
    static func clock(_ totalSeconds: Int) -> String {
        let clamped = max(0, totalSeconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let seconds = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let rounded = Int(seconds.rounded() / 60)
        return "\(max(0, rounded)) min"
    }
}
