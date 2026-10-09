import AppKit
import SwiftUI

/// Today's background tasks under the day's list: each with where it is
/// with its agent, and the prompts its agent waits on right under it.
struct BackgroundSection: View {
    let model: AppState
    let tasks: [TaskItem]
    let onEdit: (TaskItem) -> Void

    /// Approvals whose task is not among the rows (deleted meanwhile, or
    /// not on today's list): shown on their own at the top.
    private var unattached: [PendingApproval] {
        let ids = Set(tasks.map(\.id))
        return ApprovalReplies.shared.visible(model.background.approvals).filter { !ids.contains($0.taskID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Background · \(tasks.count)")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            if !model.background.isHerdrReachable {
                Text("herdr isn't running — background tasks wait")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }
            ForEach(unattached) { approval in
                ApprovalView(model: model, approval: approval)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
            ForEach(tasks) { task in
                BackgroundRowView(model: model, task: task, onEdit: { onEdit(task) })
                if task.id != tasks.last?.id {
                    Divider().padding(.leading, 42)
                }
            }
        }
        .task {
            // Fresh labels and statuses whenever the panel shows the section.
            await model.background.refreshAgents()
        }
    }
}

/// One background task: status, title, its agent's workspace, the agent's
/// report once there is one, and its pending prompts. No start button: a
/// focus session sends it.
struct BackgroundRowView: View {
    let model: AppState
    let task: TaskItem
    let onEdit: () -> Void

    private var info: BackgroundInfo { task.background ?? BackgroundInfo() }
    private var isDone: Bool { task.isDone(on: model.todayKey) }
    private var approvals: [PendingApproval] {
        ApprovalReplies.shared.visible(model.background.approvals).filter { $0.taskID == task.id }
    }

    private var statusLabel: String {
        isDone ? "Reviewed" : BackgroundPresentation.label(for: info.status)
    }

    private var statusSymbol: String {
        isDone ? "checkmark.circle.fill" : BackgroundPresentation.symbol(for: info.status)
    }

    private var statusColor: Color {
        if isDone { return Theme.allowed }
        switch info.status {
        case .blocked: return .orange
        case .running: return Theme.allowed
        case .review: return .accentColor
        case .paneClosed: return Theme.blocked
        case .waiting, .queued: return .secondary
        }
    }

    private var subtitle: String {
        [statusLabel, BackgroundPresentation.assigneeLine(for: task, labels: model.background.workspaceLabels)]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 13))
                    .foregroundStyle(statusColor)
                    .frame(width: 20)
                    .help(statusLabel)
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
                    if !info.summary.isEmpty || info.link != nil {
                        summary
                    }
                }
                .help(rowHelp)
                Spacer(minLength: 4)
                trailingAction
            }
            // A click on the row goes to the agent's pane; its buttons and
            // link keep their own actions.
            .contentShape(Rectangle())
            .onTapGesture { openPaneFromRow() }
            ForEach(approvals) { approval in
                ApprovalView(model: model, approval: approval)
                    .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu { contextMenu }
    }

    private var rowHelp: String {
        let doneWhen = task.doneWhen.isEmpty ? nil : "Done when: \(task.doneWhen)"
        let open: String? = switch BackgroundPresentation.rowClick(
            hasPane: info.assignee?.paneID != nil, phase: model.phase
        ) {
        case .openPane: "Click to open the agent’s pane"
        case .later: "Click opens the agent’s pane at the break"
        case .none: nil
        }
        return [doneWhen, open].compactMap { $0 }.joined(separator: "\n")
    }

    private func openPaneFromRow() {
        guard BackgroundPresentation.rowClick(hasPane: info.assignee?.paneID != nil, phase: model.phase) == .openPane,
              let pane = info.assignee?.paneID else { return }
        Task { await model.background.openPane(pane) }
    }

    /// The agent's one-line report, as a link when it pointed at a result.
    @ViewBuilder
    private var summary: some View {
        let text = info.summary.isEmpty ? (info.link ?? "") : info.summary
        if let link = info.link, let url = URL(string: link), url.scheme != nil {
            Link(destination: url) {
                Text(text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .font(.caption)
            .help(link)
        } else {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(info.link ?? text)
        }
    }

    @ViewBuilder
    private var trailingAction: some View {
        if !isDone, info.status == .review {
            Button {
                model.setTaskDone(id: task.id, done: true)
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.allowed)
            }
            .buttonStyle(.borderless)
            .help("Mark reviewed")
        } else if !isDone, info.status.holdsPane, let pane = info.assignee?.paneID {
            let allowed = BackgroundPresentation.canOpenPane(during: model.phase)
            Button {
                Task { await model.background.openPane(pane) }
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!allowed)
            .help(allowed ? "Open pane" : BackgroundPresentation.openPaneLaterHelp)
        }
    }

    private var contextMenu: some View {
        Group {
            Button("Edit…") { onEdit() }
            if let pane = info.assignee?.paneID {
                Button("Open pane") {
                    Task { await model.background.openPane(pane) }
                }
                .disabled(!BackgroundPresentation.canOpenPane(during: model.phase))
            }
            if isDone {
                Button("Uncheck") { model.setTaskDone(id: task.id, done: false) }
            } else if info.status == .review {
                Button("Mark reviewed") { model.setTaskDone(id: task.id, done: true) }
            }
            Divider()
            Button("Delete", role: .destructive) { model.deleteTask(id: task.id) }
        }
    }
}
