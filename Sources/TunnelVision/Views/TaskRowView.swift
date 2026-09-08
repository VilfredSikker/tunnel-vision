import AppKit
import SwiftUI

/// A short accent bar drawn at a row's edge to show where a dragged task
/// will land. Shared by rows and the list's end drop zone.
struct InsertionMarker: View {
    var body: some View {
        Capsule()
            .fill(Theme.allowed)
            .frame(height: 2)
            .shadow(color: Theme.allowed.opacity(0.45), radius: 1)
    }
}

/// One row in the day's list: check off, title, preset + duration, icon strip
/// of allowed apps, hover actions, drag to reorder. `day` is the day the
/// panel shows; starting and reordering only happen on today.
///
/// Dragging stays smooth: rows hold their place while a drag hovers and the
/// panel just records which row would be dropped on; the move happens once,
/// in `performDrop`. The insertion line marks the landing edge.
struct TaskRowView: View {
    let model: AppState
    let task: TaskItem
    var day: String
    var allowsReorder: Bool = true
    let onEdit: () -> Void
    @Binding var dragID: TaskItem.ID?
    @Binding var dropTargetID: TaskItem.ID?
    let onReorder: (TaskItem.ID, TaskItem.ID?) -> Void

    @State private var hovering = false

    init(model: AppState, task: TaskItem, day: String? = nil, allowsReorder: Bool = true,
         onEdit: @escaping () -> Void,
         dragID: Binding<TaskItem.ID?>, dropTargetID: Binding<TaskItem.ID?>,
         onReorder: @escaping (TaskItem.ID, TaskItem.ID?) -> Void) {
        self.model = model
        self.task = task
        self.day = day ?? model.todayKey
        self.allowsReorder = allowsReorder
        self.onEdit = onEdit
        _dragID = dragID
        _dropTargetID = dropTargetID
        self.onReorder = onReorder
    }

    private var isToday: Bool { day == model.todayKey }
    private var isActive: Bool { task.id == model.activeTaskID }
    private var isDone: Bool { task.isDone(on: day) }
    /// Open tasks move freely, session or not; the running one and done
    /// ones stay where they are. Reordering is also disabled when the list
    /// is sorted by something other than manual.
    private var reorderable: Bool { isToday && !isActive && !isDone && allowsReorder }
    private var canStart: Bool { isToday && (model.phase == .idle || model.phase == .breakTime) }

    var body: some View {
        content
            .overlay(alignment: .top) { dropLine }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .contextMenu { contextMenu }
            .onDrag {
                guard reorderable else { return NSItemProvider() }
                // A new drag supersedes any unfinished one.
                dragID = task.id
                dropTargetID = nil
                return NSItemProvider(object: task.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: RowDropDelegate(
                dragID: $dragID,
                dropTargetID: $dropTargetID,
                targetID: task.id,
                enabled: reorderable,
                onReorder: onReorder
            ))
    }

    /// The landing marker sits on the target row's top edge: the drop inserts
    /// directly before that row.
    private var dropLine: some View {
        Group {
            if dropTargetID == task.id {
                InsertionMarker()
                    .padding(.horizontal, 14)
                    .offset(y: -1)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }

    private var priorityColor: Color {
        switch task.priority {
        case 1: return Color(red: 0.91, green: 0.30, blue: 0.24) // red
        case 3: return Color(red: 0.30, green: 0.69, blue: 0.31) // green
        default: return Color(red: 0.95, green: 0.77, blue: 0.06) // yellow
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            checkButton
            if !isDone {
                Circle()
                    .fill(priorityColor)
                    .frame(width: 6, height: 6)
                    .help(task.priority == 1 ? "High priority" : task.priority == 3 ? "Low priority" : "Medium priority")
            }
            if task.repeatDaily {
                Image(systemName: "repeat")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .help("Repeats daily — shows up again tomorrow")
            }
            iconStrip
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title.isEmpty ? "Untitled task" : task.title)
                    .font(.body)
                    .lineLimit(1)
                    .strikethrough(isDone, color: .secondary)
                    .foregroundStyle(isDone ? .secondary : .primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            trailingAction
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Theme.allowed.opacity(0.09) : .clear)
        )
    }

    private var subtitle: String {
        var parts: [String] = []
        if let presetID = task.presetID, let preset = model.presets.first(where: { $0.id == presetID }) {
            parts.append(preset.name)
        } else if task.overrides.isEmpty {
            parts.append("No preset — allows everything")
        } else {
            parts.append("Custom")
        }
        if task.repeatDaily {
            parts.append("Repeats daily")
        }
        parts.append(TimeFormat.minutes(task.durationSeconds))
        if isDone, let time = task.doneTime(on: day) {
            parts.append("done " + time.formatted(date: .omitted, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    /// Distinct bundle ids across the effective rule set, capped for display.
    private var ruleBundleIDs: [String] {
        var seen: [String] = []
        for rule in model.effectiveRules(for: task) where rule.scope == .app {
            let bundle = rule.bundleID.trimmingCharacters(in: .whitespaces)
            if !bundle.isEmpty && !seen.contains(bundle) {
                seen.append(bundle)
            }
        }
        return seen
    }

    @ViewBuilder
    private var iconStrip: some View {
        let ids = ruleBundleIDs
        if ids.isEmpty {
            if task.presetID == nil && task.overrides.isEmpty {
                Image(systemName: "lock.open")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .frame(width: 14)
                    .help("No preset — every app is allowed")
            } else {
                Image(systemName: "lock")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .frame(width: 14)
                    .help("Empty allowlist — other apps get locked")
            }
        } else {
            HStack(spacing: -2) {
                ForEach(ids.prefix(3), id: \.self) { bundleID in
                    icon(bundleID)
                }
                if ids.count > 3 {
                    Text("+\(ids.count - 3)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, alignment: .leading)
        }
    }

    private func icon(_ bundleID: String) -> some View {
        Group {
            if let image = AppCatalog.icon(forBundleID: bundleID) {
                Image(nsImage: image)
                    .resizable()
            } else {
                Image(systemName: "app")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 13, height: 13)
    }

    @ViewBuilder
    private var checkButton: some View {
        Button {
            model.setTaskDone(id: task.id, done: !isDone, on: day)
        } label: {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isDone ? Theme.allowed : Color.secondary.opacity(0.6))
        }
        .buttonStyle(.borderless)
        .help(isDone ? "Uncheck for \(dayName)" : "Mark done for \(dayName)")
    }

    private var dayName: String {
        DayKey.label(for: day, today: model.todayKey).lowercased()
    }

    @ViewBuilder
    private var trailingAction: some View {
        if isActive && model.phase == .work {
            Image(systemName: "timer")
                .foregroundStyle(Theme.allowed)
                .help("Running")
        } else if isActive && model.phase == .paused {
            Button {
                model.togglePause()
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.allowed)
            }
            .buttonStyle(.borderless)
            .help("Resume")
        } else if canStart {
            // Always-visible start affordance — starting a task must not
            // depend on hover discovery or double-click. A done task offers
            // a repeat instead.
            Button {
                start()
            } label: {
                Image(systemName: startSymbol)
                    .font(.system(size: 17))
                    .foregroundStyle(hovering ? Theme.allowed : Color.secondary.opacity(isDone ? 0.55 : 0.75))
            }
            .buttonStyle(.borderless)
            .help(isDone ? "Run “\(task.title)” again as a new task" : "Start “\(task.title)”")
        }
    }

    private var startSymbol: String {
        if isDone {
            return hovering ? "arrow.counterclockwise.circle.fill" : "arrow.counterclockwise.circle"
        }
        return hovering ? "play.circle.fill" : "play.circle"
    }

    /// A done task re-runs as a fresh copy of itself, so the finished one
    /// keeps its check mark and the new run gets its own. A repeating task's
    /// copy keeps repeating, so it stays on tomorrow's list as well.
    private func start() {
        guard !isActive else { return }
        // A session in progress must be paused or ended first.
        guard model.phase != .work, model.phase != .paused else { return }
        if isDone {
            model.repeatTask(id: task.id)
        } else {
            model.startTask(id: task.id)
        }
    }

    private var contextMenu: some View {
        Group {
            if isActive {
                Button(model.phase == .paused ? "Resume" : "Pause") { model.togglePause() }
            } else {
                Button(isDone ? "Run again as new task" : "Start") { start() }
                    .disabled(!canStart)
            }
            if isActive {
                Button("Mark done & break") { model.finishTaskDone() }
            }
            Button(isDone ? "Uncheck" : "Check off") { model.setTaskDone(id: task.id, done: !isDone, on: day) }
            Divider()
            Button("Edit…") { onEdit() }
            Button("Delete", role: .destructive) { model.deleteTask(id: task.id) }
                .disabled(isActive)
        }
    }
}

/// Rows stay put while a drag hovers; the delegate only records the target
/// row, whose top edge shows the insertion line. The move runs once on drop.
/// Disabled rows (done, running) neither move nor take a drop.
private struct RowDropDelegate: DropDelegate {
    @Binding var dragID: TaskItem.ID?
    @Binding var dropTargetID: TaskItem.ID?
    let targetID: TaskItem.ID
    let enabled: Bool
    let onReorder: (TaskItem.ID, TaskItem.ID?) -> Void

    func dropEntered(info: DropInfo) {
        guard enabled, let id = dragID, id != targetID else { return }
        dropTargetID = targetID
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard enabled, let id = dragID, id != targetID else { return nil }
        dropTargetID = targetID
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dragID = nil
            dropTargetID = nil
        }
        guard enabled, let id = dragID, id != targetID else { return false }
        onReorder(id, targetID)
        return true
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetID {
            dropTargetID = nil
        }
    }
}
