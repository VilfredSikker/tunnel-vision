import SwiftUI

/// A task's checklist with tickable items. A tick saves at once and stays on
/// the task, so a repeating task shows it again the next day. Reads the task
/// from the model by id, so it stays current inside a popover.
struct ChecklistView: View {
    let model: AppState
    let taskID: TaskItem.ID

    private var items: [ChecklistItem] {
        model.tasks.first { $0.id == taskID }?.checklist ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                // The text sits beside the checkbox, not in its label, so a
                // click on a link opens it instead of ticking the item.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { item.done },
                        set: { model.setChecklistItem(taskID: taskID, itemID: item.id, done: $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    Text(LinkText.attributed(item.text))
                        .strikethrough(item.done, color: .secondary)
                        .foregroundStyle(item.done ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(item.text)
                }
            }
        }
    }
}

/// Ticked against total items on a row; a click opens the description and
/// checklist, so items can be ticked without opening the editor.
struct ChecklistBadge: View {
    let model: AppState
    let task: TaskItem

    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "checklist")
                Text("\(task.checklist.filter(\.done).count)/\(task.checklist.count)")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Show the checklist")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(task.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if !task.notes.isEmpty {
                    Text(LinkText.attributed(task.notes))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ChecklistView(model: model, taskID: task.id)
            }
            .padding(12)
            .frame(width: 260, alignment: .leading)
        }
    }
}
