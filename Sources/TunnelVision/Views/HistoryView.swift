import AppKit
import Charts
import SwiftUI

/// Past sessions: the last two weeks as bars, days in a row, totals, the
/// latest runs, and a CSV export of the whole log.
struct HistoryView: View {
    let model: AppState

    private static let chartDays = 14
    private static let recentShown = 20

    var body: some View {
        let today = model.todayKey
        let days = HistoryStats.days(model.history, count: Self.chartDays, today: today)
        let week = days.suffix(7)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                tile("Days in a row", "\(HistoryStats.dayStreak(model.history, today: today))")
                tile("Sessions, 7 days", "\(week.reduce(0) { $0 + $1.sessions })")
                tile("Focus, 7 days", hours(week.reduce(0) { $0 + $1.focusSeconds }))
                tile("Sessions, all time", "\(model.history.filter { $0.outcome == .completed }.count)")
            }

            Chart(days, id: \.day) { day in
                BarMark(
                    x: .value("Day", DayKey.date(from: day.day) ?? .now, unit: .day),
                    y: .value("Sessions", day.sessions)
                )
                .foregroundStyle(Theme.allowed)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) {
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
            }
            .frame(height: 140)
            .accessibilityLabel("Completed sessions per day, last \(Self.chartDays) days")

            Text("Latest runs")
                .font(.headline)
            if model.history.isEmpty {
                Text("Nothing yet. Every session you finish, skip or stop shows up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                List(Array(model.history.suffix(Self.recentShown).reversed().enumerated()), id: \.offset) { _, record in
                    runRow(record, today: today)
                }
                .listStyle(.inset)
                .frame(minHeight: 180)
            }

            HStack {
                Spacer()
                Button("Export CSV…", action: exportCSV)
                    .disabled(model.history.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runRow(_ record: SessionRecord, today: String) -> some View {
        HStack {
            Image(systemName: symbol(record.outcome))
                .foregroundStyle(record.outcome == .completed ? Theme.allowed : .secondary)
                .help(outcomeLabel(record.outcome))
            Text(record.title)
                .lineLimit(1)
            Spacer()
            Text(TimeFormat.minutes(record.focusSeconds))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(DayKey.label(for: record.day, today: today))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ outcome: SessionRecord.Outcome) -> String {
        switch outcome {
        case .completed: "checkmark.circle.fill"
        case .skippedToBreak: "forward.end.circle"
        case .stopped: "stop.circle"
        }
    }

    private func outcomeLabel(_ outcome: SessionRecord.Outcome) -> String {
        switch outcome {
        case .completed: "Completed"
        case .skippedToBreak: "Skipped to break"
        case .stopped: "Stopped early"
        }
    }

    private func hours(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "tunnel-vision-history.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HistoryStats.csv(model.history).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// The history window, opened from the panel footer.
@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()

    private var window: NSWindow?

    func show(model: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: HistoryView(model: model)))
        window.title = "History"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
