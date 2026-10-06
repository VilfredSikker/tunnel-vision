import AppKit
import SwiftUI

/// Past sessions: a year of days as a GitHub-style activity grid, days in
/// a row, totals, the latest runs (or one day's, picked on the grid), and a
/// CSV export of the whole log.
struct HistoryView: View {
    let model: AppState

    private static let gridWeeks = 53
    private static let recentShown = 20

    /// The day clicked on the grid; nil shows the latest runs.
    @State private var selectedDay: String?

    var body: some View {
        let today = model.todayKey
        let week = HistoryStats.days(model.history, count: 7, today: today)
        let grid = HistoryStats.grid(
            model.history,
            weeks: Self.gridWeeks,
            today: today,
            firstWeekday: Calendar.current.firstWeekday
        )
        let yearSessions = grid.joined().compactMap { $0?.sessions }.reduce(0, +)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                tile("Days in a row", "\(HistoryStats.dayStreak(model.history, today: today))")
                tile("Sessions, 7 days", "\(week.reduce(0) { $0 + $1.sessions })")
                tile("Focus, 7 days", hours(week.reduce(0) { $0 + $1.focusSeconds }))
                tile("Sessions, all time", "\(model.history.filter { $0.outcome == .completed }.count)")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("\(yearSessions) session\(yearSessions == 1 ? "" : "s") in the last year")
                    .font(.callout.weight(.medium))
                ActivityGrid(columns: grid, today: today, selectedDay: $selectedDay)
            }

            runsHeader(today: today)
            runsList(today: today)

            HStack {
                Spacer()
                Button("Export CSV…", action: exportCSV)
                    .disabled(model.history.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 760)
    }

    @ViewBuilder
    private func runsHeader(today: String) -> some View {
        HStack {
            Text(selectedDay.map { "Runs on \(DayKey.label(for: $0, today: today))" } ?? "Latest runs")
                .font(.headline)
            Spacer()
            if selectedDay != nil {
                Button("Show latest") { selectedDay = nil }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func runsList(today: String) -> some View {
        let runs: [SessionRecord] = if let selectedDay {
            model.history.filter { $0.day == selectedDay }.reversed()
        } else {
            model.history.suffix(Self.recentShown).reversed()
        }
        if model.history.isEmpty {
            Text("Nothing yet. Every session you finish, skip or stop shows up here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if runs.isEmpty {
            Text("No runs that day.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minHeight: 180, alignment: .top)
        } else {
            List(Array(runs.enumerated()), id: \.offset) { _, record in
                runRow(record, today: today)
            }
            .listStyle(.inset)
            .frame(minHeight: 180)
        }
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

/// GitHub's activity grid: a column per week, a square per day, shaded by
/// completed sessions. Clicking a day picks it; clicking it again clears.
private struct ActivityGrid: View {
    let columns: [[HistoryStats.Day?]]
    let today: String
    @Binding var selectedDay: String?

    private static let cell: CGFloat = 10
    private static let gap: CGFloat = 3
    private static let labelWidth: CGFloat = 28

    var body: some View {
        let busiest = columns.joined().compactMap { $0?.sessions }.max() ?? 0
        VStack(alignment: .leading, spacing: 4) {
            monthRow
            HStack(alignment: .top, spacing: Self.gap) {
                weekdayColumn
                ForEach(columns.indices, id: \.self) { index in
                    VStack(spacing: Self.gap) {
                        ForEach(0..<7, id: \.self) { row in
                            square(columns[index][row], busiest: busiest)
                        }
                    }
                }
            }
            legend
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Completed sessions per day, last \(columns.count) weeks")
    }

    /// Month names sit over the column where each month starts.
    private var monthRow: some View {
        let step = Self.cell + Self.gap
        return ZStack(alignment: .topLeading) {
            ForEach(HistoryStats.monthLabels(columns), id: \.column) { label in
                Text(label.month)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .offset(x: Self.labelWidth + Self.gap + CGFloat(label.column) * step)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 12, alignment: .topLeading)
    }

    /// Every other weekday is named, as on GitHub.
    private var weekdayColumn: some View {
        let symbols = Calendar.current.shortWeekdaySymbols
        let first = Calendar.current.firstWeekday - 1
        return VStack(alignment: .leading, spacing: Self.gap) {
            ForEach(0..<7, id: \.self) { row in
                Text(row % 2 == 1 ? symbols[(first + row) % 7] : "")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, height: Self.cell, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func square(_ day: HistoryStats.Day?, busiest: Int) -> some View {
        if let day {
            let selected = selectedDay == day.day
            RoundedRectangle(cornerRadius: 2)
                .fill(Self.shade(HistoryStats.level(sessions: day.sessions, busiest: busiest)))
                .frame(width: Self.cell, height: Self.cell)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(selected ? Color.primary : (day.day == today ? Color.secondary : .clear), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture { selectedDay = selected ? nil : day.day }
                .help(tooltip(day))
        } else {
            Color.clear.frame(width: Self.cell, height: Self.cell)
        }
    }

    private var legend: some View {
        HStack(spacing: Self.gap) {
            Spacer()
            Text("Less")
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.shade(level))
                    .frame(width: Self.cell, height: Self.cell)
            }
            Text("More")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private static func shade(_ level: Int) -> Color {
        level == 0 ? Color.secondary.opacity(0.15) : Theme.allowed.opacity(0.25 + 0.25 * Double(level - 1))
    }

    private func tooltip(_ day: HistoryStats.Day) -> String {
        let label = DayKey.label(for: day.day, today: today)
        let count = day.sessions == 0 ? "No sessions" : "\(day.sessions) session\(day.sessions == 1 ? "" : "s")"
        let focus = day.focusSeconds > 0 ? " · \(TimeFormat.minutes(day.focusSeconds)) focus" : ""
        return "\(count) on \(label)\(focus)"
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
