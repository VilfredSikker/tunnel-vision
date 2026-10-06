import Foundation

/// One ended work run, kept for good. The title is copied in because tasks
/// get deleted.
struct SessionRecord: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        /// Done, or the timer ran out: the run counts as a session.
        case completed
        /// "Skip to break": work ended without counting.
        case skippedToBreak
        /// Stopped early: no credit, no break.
        case stopped
    }

    var taskID: UUID?
    var title: String
    var startedAt: Date
    var endedAt: Date
    /// Work time only; pauses are left out.
    var focusSeconds: TimeInterval
    var outcome: Outcome

    /// The day the run counts on: the day it ended, as the today count does.
    var day: String { DayKey.key(for: endedAt) }
}

/// Every ended run, one JSON object per line in its own file next to
/// data.json. Appending keeps writes small, and a damaged line costs only
/// that line, never the tasks and presets.
struct HistoryLog {
    let fileURL: URL

    func load() -> [SessionRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = Self.decoder
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(SessionRecord.self, from: Data(line))
        }
    }

    func append(_ record: SessionRecord) {
        do {
            var line = try Self.encoder.encode(record)
            line.append(UInt8(ascii: "\n"))
            let manager = FileManager.default
            if !manager.fileExists(atPath: fileURL.path) {
                try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try line.write(to: fileURL, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            NSLog("Tunnel Vision: failed to record history: \(error)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// What the history window shows, worked out from the log.
enum HistoryStats {
    struct Day: Equatable {
        var day: String
        var sessions: Int
        var focusSeconds: TimeInterval
    }

    /// The `count` days up to and including `today`, oldest first, empty
    /// days included. Focus time counts every run; sessions only completed ones.
    static func days(_ records: [SessionRecord], count: Int, today: String) -> [Day] {
        let byDay = Dictionary(grouping: records, by: \.day)
        return (0..<count).reversed().compactMap { offset in
            guard let key = DayKey.key(byAdding: -offset, to: today) else { return nil }
            let runs = byDay[key] ?? []
            return Day(
                day: key,
                sessions: runs.filter { $0.outcome == .completed }.count,
                focusSeconds: runs.reduce(0) { $0 + $1.focusSeconds }
            )
        }
    }

    /// Days in a row with at least one completed session, ending today. A
    /// today with nothing done yet does not break the run: it ends yesterday.
    static func dayStreak(_ records: [SessionRecord], today: String) -> Int {
        let active = Set(records.filter { $0.outcome == .completed }.map(\.day))
        var day = active.contains(today) ? today : DayKey.key(byAdding: -1, to: today)
        var streak = 0
        while let key = day, active.contains(key) {
            streak += 1
            day = DayKey.key(byAdding: -1, to: key)
        }
        return streak
    }

    /// The whole log as CSV, oldest first, quoted per RFC 4180.
    static func csv(_ records: [SessionRecord]) -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["day,task,started,ended,focus_minutes,outcome"]
        for record in records.sorted(by: { $0.startedAt < $1.startedAt }) {
            let fields = [
                record.day,
                record.title,
                iso.string(from: record.startedAt),
                iso.string(from: record.endedAt),
                String(format: "%.1f", record.focusSeconds / 60),
                record.outcome.rawValue,
            ]
            lines.append(fields.map(quoted).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func quoted(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
