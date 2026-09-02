import AppKit
import SwiftUI

/// One row in today's list: check off, title, preset + duration, icon strip of
/// allowed apps, hover actions, double-click to start, drag to reorder.
struct TaskRowView: View {
    let model: AppState
    let task: TaskItem
    let onEdit: () -> Void
    @Binding var dragID: TaskItem.ID?

    @State private var hovering = false

    private var isActive: Bool { task.id == model.activeTaskID }
    private var isDone: Bool { task.isDone(on: model.todayKey) }
    private var reorderable: Bool { model.phase != .work && model.phase != .paused && !isActive }
    private var canStart: Bool { model.phase == .idle || model.phase == .breakTime }

    var body: some View {
        HStack(spacing: 8) {
            checkButton
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
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { contextMenu }
        .onDrag {
            guard reorderable else { return NSItemProvider() }
            dragID = task.id
            return NSItemProvider(object: task.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: RowDropDelegate(model: model, dragID: $dragID, targetID: task.id))
    }

    private var subtitle: String {
        var parts: [String] = []
        if let presetID = task.presetID, let preset = model.presets.first(where: { $0.id == presetID }) {
            parts.append(preset.name)
        } else if task.overrides.isEmpty {
            parts.append("No lock")
        } else {
            parts.append("Custom")
        }
        parts.append(TimeFormat.minutes(task.durationSeconds))
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
            Image(systemName: "lock.open")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
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
            model.setTaskDone(id: task.id, done: !isDone)
        } label: {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isDone ? Theme.allowed : Color.secondary.opacity(0.6))
        }
        .buttonStyle(.borderless)
        .help(isDone ? "Uncheck for today" : "Mark done for today")
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
        } else if canStart && !isDone {
            // Always-visible start affordance — starting a task must not
            // depend on hover discovery or double-click.
            Button {
                start()
            } label: {
                Image(systemName: hovering ? "play.circle.fill" : "play.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(hovering ? Theme.allowed : Color.secondary.opacity(0.75))
            }
            .buttonStyle(.borderless)
            .help("Start “\(task.title)”")
        }
    }

    private func start() {
        guard !isActive, !isDone else { return }
        // A session in progress must be paused or ended first.
        guard model.phase != .work, model.phase != .paused else { return }
        model.startTask(id: task.id)
    }

    private var contextMenu: some View {
        Group {
            if isActive {
                Button(model.phase == .paused ? "Resume" : "Pause") { model.togglePause() }
            } else if !isDone {
                Button("Start") { start() }
            }
            if isActive {
                Button("Mark done & break") { model.finishTaskDone() }
            }
            Button(isDone ? "Uncheck" : "Check off") { model.setTaskDone(id: task.id, done: !isDone) }
            Divider()
            Button("Edit…") { onEdit() }
            Button("Delete", role: .destructive) { model.deleteTask(id: task.id) }
                .disabled(isActive)
        }
    }
}

/// Drops a dragged row directly before the row under the cursor.
private struct RowDropDelegate: DropDelegate {
    let model: AppState
    @Binding var dragID: TaskItem.ID?
    let targetID: TaskItem.ID

    func dropEntered(info: DropInfo) {
        guard let id = dragID, id != targetID else { return }
        model.moveTask(id: id, before: targetID)
        dragID = targetID
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragID = nil
        return true
    }
}
