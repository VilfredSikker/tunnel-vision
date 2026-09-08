import AppKit
import SwiftUI

/// The main popover panel: current session header (when one runs), the day's
/// task list with done tasks folded away, and the footer.
struct MainPanel: View {
    let model: AppState

    /// Set when the menu-bar or session affordances want to edit the running
    /// task; the sheet follows the task even as the list rerenders.
    @State private var editorMode: EditorMode?
    @State private var pendingEditActiveTask = false
    @State private var showPresets = false
    @State private var showStrictStop = false
    @State private var strictStopTitle = ""
    @State private var dragID: TaskItem.ID?
    /// Row whose top edge shows the insertion line while a reorder drag hovers.
    @State private var dropTargetID: TaskItem.ID?
    /// The day the list shows; nil is today (which follows the clock).
    @State private var viewedDay: String?
    @State private var showDayPicker = false
    @State private var doneExpanded = false

    enum EditorMode: Identifiable {
        case add
        case edit(TaskItem)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let task): return "edit-\(task.id)"
            }
        }

        var task: TaskItem? {
            switch self {
            case .add: return nil
            case .edit(let task): return task
            }
        }
    }

    private var day: String { viewedDay ?? model.todayKey }
    private var isToday: Bool { viewedDay == nil || viewedDay == model.todayKey }

    /// Writes the chosen sort back through settings so it persists.
    private var sortBinding: Binding<TaskSort> {
        Binding(
            get: { model.settings.taskSort },
            set: { newValue in
                var updated = model.settings
                updated.taskSort = newValue
                model.updateSettings(updated)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.phase == .work || model.phase == .paused {
                SessionHeader(model: model, onStrictStop: {
                    // Capture the title now: the session may end while the
                    // sheet is open and model.activeTask would go nil.
                    strictStopTitle = model.activeTask?.title ?? ""
                    showStrictStop = !strictStopTitle.isEmpty
                }, onEditTask: { pendingEditActiveTask = true })
            } else if model.phase == .breakTime {
                BreakHeader(model: model)
            }

            if model.phase == .work || model.phase == .paused || model.phase == .breakTime {
                Divider()
            }

            daySection

            Divider()
            footer
        }
        .frame(width: 340)
        .background(.regularMaterial)
        .sheet(item: $editorMode) { mode in
            TaskEditorView(model: model, task: mode.task)
        }
        .sheet(isPresented: $showPresets) {
            PresetsManagerView(model: model)
        }
        .sheet(isPresented: $showStrictStop) {
            if !strictStopTitle.isEmpty {
                StrictStopView(taskTitle: strictStopTitle) {
                    model.stopNow()
                    showStrictStop = false
                }
            }
        }
        .onChange(of: model.phase) { _, phase in
            // The session ended while the typed-title sheet was open: the
            // stop is moot, close the sheet.
            if showStrictStop, phase != .work, phase != .paused {
                showStrictStop = false
            }
        }
        .onChange(of: pendingEditActiveTask) { _, pending in
            if pending, let task = model.activeTask {
                pendingEditActiveTask = false
                editorMode = .edit(task)
            }
        }
        // The menu bar's "New task…" arrives either while the panel is open
        // (onChange) or just as the quick action opens it (onAppear).
        .onAppear(perform: openRequestedNewTask)
        .onChange(of: model.pendingNewTask) { _, pending in
            if pending {
                openRequestedNewTask()
            }
        }
    }

    private func openRequestedNewTask() {
        guard model.pendingNewTask else { return }
        model.clearNewTaskRequest()
        guard editorMode == nil, !showPresets else { return }
        editorMode = .add
    }

    // MARK: The day's task list

    /// Applies the user's chosen sort to the open tasks. Done tasks always
    /// stay most-recent-first regardless of sort preference.
    private func sortedOpen(_ tasks: [TaskItem]) -> [TaskItem] {
        switch model.settings.taskSort {
        case .manual:
            return tasks
        case .created:
            return tasks.sorted { $0.createdDate < $1.createdDate }
        case .priority:
            return tasks.sorted { $0.priority < $1.priority }
        }
    }

    private var daySection: some View {
        let open = sortedOpen(model.openTasks(on: day))
        let done = model.doneTasks(on: day)
        return VStack(spacing: 6) {
            HStack {
                dayButton
                Spacer()
                if isToday {
                    if !model.todayGarden.isEmpty {
                        // The day's sessions as the plants they grew into; the
                        // count lives in the tooltip.
                        GardenRowView(records: model.todayGarden, count: model.todayCount)
                    } else if model.todayCount > 0 {
                        Text("\(model.todayCount) session\(model.todayCount == 1 ? "" : "s") done")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !done.isEmpty {
                    Text("\(done.count) done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            if isToday && !model.tasks.isEmpty {
                HStack {
                    Picker("Sort", selection: sortBinding) {
                        ForEach(TaskSort.allCases) { sort in
                            Text(sort.displayName).tag(sort)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.horizontal, 14)
            }

            if model.tasks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("Add a task, then start it to focus.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if isToday {
                            rows(open)
                            if !done.isEmpty {
                                if !open.isEmpty {
                                    Divider().padding(.horizontal, 14).padding(.vertical, 4)
                                }
                                doneGroup(done)
                            }
                            // The tail of the open list takes a drop to move a
                            // task to the very end. Only offered when the list
                            // is on screen, never for done tasks.
                            if !open.isEmpty {
                                endDropZone()
                            }
                        } else {
                            // Another day: what got done then, and the rest.
                            if done.isEmpty {
                                Text("Nothing was checked off on this day.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.vertical, 10)
                            } else {
                                rows(done)
                            }
                            if !open.isEmpty {
                                Divider().padding(.horizontal, 14).padding(.vertical, 4)
                                collapsibleGroup(title: "Not done", tasks: open, expanded: $doneExpanded)
                            }
                        }
                    }
                }
                .frame(maxHeight: 250)
            }

            Button {
                editorMode = .add
            } label: {
                Label("New task", systemImage: "plus.circle")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// "Today" (or the viewed day) opens a calendar to look at another day.
    private var dayButton: some View {
        Button {
            showDayPicker.toggle()
        } label: {
            HStack(spacing: 3) {
                Text(DayKey.label(for: day, today: model.todayKey))
                    .font(.caption)
                    .fontWeight(.semibold)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Show another day")
        .popover(isPresented: $showDayPicker, arrowEdge: .bottom) {
            DayPickerView(day: day, today: model.todayKey) { picked in
                viewedDay = picked == model.todayKey ? nil : picked
                doneExpanded = false
            }
        }
    }

    @ViewBuilder
    private func rows(_ tasks: [TaskItem]) -> some View {
        ForEach(tasks) { task in
            TaskRowView(
                model: model,
                task: task,
                day: day,
                allowsReorder: isToday && model.settings.taskSort == .manual,
                onEdit: { editorMode = .edit(task) },
                dragID: $dragID,
                dropTargetID: $dropTargetID,
                onReorder: reorder
            )
            if task.id != tasks.last?.id {
                Divider().padding(.leading, 42)
            }
        }
    }

    /// Moves `id` to sit before `targetID`; a nil target means the end of the
    /// open list. The model itself refuses moves involving the running task.
    private func reorder(_ id: TaskItem.ID, before targetID: TaskItem.ID?) {
        model.moveTask(id: id, before: targetID)
    }

    /// A slim strip under the open list that drops a task to the end.
    private func endDropZone() -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if dropTargetID == nil, dragID != nil {
                    InsertionMarker()
                        .padding(.horizontal, 14)
                        .transition(.opacity)
                }
            }
            .onDrop(of: [.text], delegate: EndDropDelegate(
                dragID: $dragID,
                dropTargetID: $dropTargetID,
                onReorder: reorder
            ))
    }

    /// Done tasks fold away: the latest stays visible, the rest show on expand.
    @ViewBuilder
    private func doneGroup(_ done: [TaskItem]) -> some View {
        groupHeader(
            title: "Done",
            count: done.count,
            expanded: $doneExpanded,
            expandable: done.count > 1
        )
        rows(doneExpanded ? done : Array(done.prefix(1)))
    }

    @ViewBuilder
    private func collapsibleGroup(title: String, tasks: [TaskItem], expanded: Binding<Bool>) -> some View {
        groupHeader(title: title, count: tasks.count, expanded: expanded, expandable: true)
        if expanded.wrappedValue {
            rows(tasks)
        }
    }

    private func groupHeader(title: String, count: Int, expanded: Binding<Bool>, expandable: Bool) -> some View {
        Button {
            guard expandable else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                expanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(title) · \(count)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                if expandable {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if !expanded.wrappedValue {
                        Text("show all")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expandable ? (expanded.wrappedValue ? "Show only the latest" : "Show all \(count)") : "")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                showPresets = true
            } label: {
                Label("Presets", systemImage: "checklist")
            }
            .help("Manage presets")

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Open settings")

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .help("Quit Tunnel Vision")
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Drops a task after the last open row by targeting nil — `moveTask`'s
/// "move to the end" case. The marker shows on the end strip itself only
/// while this zone is hovered.
private struct EndDropDelegate: DropDelegate {
    @Binding var dragID: TaskItem.ID?
    @Binding var dropTargetID: TaskItem.ID?
    let onReorder: (TaskItem.ID, TaskItem.ID?) -> Void

    func dropEntered(info: DropInfo) {
        guard dragID != nil else { return }
        dropTargetID = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard dragID != nil else { return nil }
        dropTargetID = nil
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dragID = nil
            dropTargetID = nil
        }
        guard let id = dragID else { return false }
        onReorder(id, nil)
        return true
    }
}

/// A calendar for the day the panel shows, with a way back to today.
private struct DayPickerView: View {
    let today: String
    let onPick: (String) -> Void

    @State private var date: Date

    init(day: String, today: String, onPick: @escaping (String) -> Void) {
        self.today = today
        self.onPick = onPick
        _date = State(initialValue: DayKey.date(from: day) ?? Date())
    }

    var body: some View {
        VStack(spacing: 8) {
            DatePicker("Day", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Text("Check-offs are kept per day; past days show what got done. Tasks repeat daily show again today.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Spacer()
                Button("Today") {
                    if let todayDate = DayKey.date(from: today) {
                        date = todayDate
                    }
                    onPick(today)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 260)
        .onChange(of: date) { _, value in
            onPick(DayKey.key(for: value))
        }
    }
}
