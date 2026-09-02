import AppKit
import SwiftUI

/// The main popover panel: current session header (when one runs), today's task
/// list, and the footer.
struct MainPanel: View {
    let model: AppState

    @State private var editorMode: EditorMode?
    @State private var showPresets = false
    @State private var showStrictStop = false
    @State private var dragID: TaskItem.ID?

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

    var body: some View {
        VStack(spacing: 0) {
            if model.phase == .work || model.phase == .paused {
                SessionHeader(model: model, onStrictStop: { showStrictStop = true })
            } else if model.phase == .breakTime {
                BreakHeader(model: model)
            }

            if model.phase == .work || model.phase == .paused || model.phase == .breakTime {
                Divider()
            }

            todaySection

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
            if let title = model.activeTask?.title {
                StrictStopView(taskTitle: title) {
                    model.stopNow()
                    showStrictStop = false
                }
            }
        }
    }

    // MARK: Today's task list

    private var todaySection: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Today")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.todayCount > 0 {
                    Text("\(model.todayCount) session\(model.todayCount == 1 ? "" : "s") done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

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
                        ForEach(model.tasks) { task in
                            TaskRowView(
                                model: model,
                                task: task,
                                onEdit: { editorMode = .edit(task) },
                                dragID: $dragID
                            )
                            if task.id != model.tasks.last?.id {
                                Divider().padding(.leading, 42)
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
            .help("Quit Anchor")
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
