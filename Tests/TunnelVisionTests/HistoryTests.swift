import Foundation
import XCTest

@testable import TunnelVision

final class HistoryTests: XCTestCase {
    private let today = "2026-10-05"

    private func record(_ day: String, _ outcome: SessionRecord.Outcome = .completed, minutes: Double = 25, title: String = "Task") -> SessionRecord {
        // Noon on the day, so the day key holds in any time zone offset.
        let end = DayKey.date(from: day)!.addingTimeInterval(12 * 3600)
        return SessionRecord(
            taskID: nil,
            title: title,
            startedAt: end.addingTimeInterval(-minutes * 60),
            endedAt: end,
            focusSeconds: minutes * 60,
            outcome: outcome
        )
    }

    func testDaysAreFilledInOldestFirst() {
        let records = [record("2026-10-03"), record("2026-10-05"), record("2026-10-05", .stopped, minutes: 10)]
        let days = HistoryStats.days(records, count: 3, today: today)
        XCTAssertEqual(days.map(\.day), ["2026-10-03", "2026-10-04", "2026-10-05"])
        XCTAssertEqual(days.map(\.sessions), [1, 0, 1], "only completed runs are sessions")
        XCTAssertEqual(days.map(\.focusSeconds), [1500, 0, 2100], "every run counts toward focus time")
    }

    func testStreakEndsTodayOrYesterday() {
        let run = [record("2026-10-02"), record("2026-10-03"), record("2026-10-04")]
        XCTAssertEqual(HistoryStats.dayStreak(run, today: today), 3, "nothing yet today keeps the run")
        XCTAssertEqual(HistoryStats.dayStreak(run + [record(today)], today: today), 4)
        XCTAssertEqual(HistoryStats.dayStreak([record("2026-10-03")], today: today), 0, "a missed day breaks it")
        XCTAssertEqual(HistoryStats.dayStreak([record("2026-10-04", .stopped)], today: today), 0, "a stopped run is not a session")
    }

    func testCSVQuotesAwkwardTitles() {
        let csv = HistoryStats.csv([record(today, title: "Plan, \"draft\"\nv2")])
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "day,task,started,ended,focus_minutes,outcome")
        XCTAssertTrue(lines[1].hasPrefix("2026-10-05,\"Plan, \"\"draft\"\"\nv2\","), lines[1])
        XCTAssertTrue(lines[1].hasSuffix(",25.0,completed"), lines[1])
    }

    func testLogSkipsADamagedLine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = HistoryLog(fileURL: dir.appendingPathComponent("history.jsonl"))
        log.append(record("2026-10-04"))
        let handle = try FileHandle(forWritingTo: log.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        log.append(record(today))
        XCTAssertEqual(log.load().map(\.day), ["2026-10-04", today])
    }
}
