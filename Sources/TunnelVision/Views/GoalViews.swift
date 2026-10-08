import SwiftUI

/// Open goals above the task list, each with how many of its steps are
/// finished and how many are still open. Goals grow step by step, so this
/// counts steps instead of showing a fraction of a total nobody knows yet.
struct GoalsStrip: View {
    let model: AppState

    var body: some View {
        VStack(spacing: 2) {
            ForEach(model.openGoals) { goal in
                GoalRow(model: model, goal: goal)
            }
        }
        .padding(.horizontal, 14)
    }
}

private struct GoalRow: View {
    let model: AppState
    let goal: Goal

    private var steps: [TaskItem] { model.tasks.filter { $0.goalID == goal.id } }

    private var progress: String {
        let finished = steps.filter { $0.lastDoneDay != nil }.count
        let open = steps.filter { model.isOpen($0, on: model.todayKey) && !$0.isDone(on: model.todayKey) }.count
        if steps.isEmpty { return "no steps yet" }
        return "\(finished) done · \(open) open"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(goal.title)
                .font(.callout)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(progress)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help(goal.doneWhen.isEmpty ? goal.title : "Done when: \(goal.doneWhen)")
        .contextMenu {
            Button("Finish goal") { model.setGoalDone(id: goal.id, done: true) }
            Button("Delete goal", role: .destructive) { model.deleteGoal(id: goal.id) }
        }
    }
}
