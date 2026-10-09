import Foundation

/// What the background task views decide, kept out of the views so it can
/// be tested: status words, which tasks the Background section takes, the
/// editor's readiness hint, which approval the floating bar shows, and when
/// a pane may be opened.
enum BackgroundPresentation {
    // MARK: Status

    static func label(for status: BackgroundStatus) -> String {
        switch status {
        case .waiting: "Waiting"
        case .queued: "Queued"
        case .running: "Running"
        case .blocked: "Needs you"
        case .review: "Ready for review"
        case .paneClosed: "Pane closed"
        }
    }

    /// An SF Symbol for the status.
    static func symbol(for status: BackgroundStatus) -> String {
        switch status {
        case .waiting: "clock"
        case .queued: "tray.full"
        case .running: "circle.dotted.circle"
        case .blocked: "exclamationmark.bubble.fill"
        case .review: "checkmark.seal"
        case .paneClosed: "xmark.rectangle"
        }
    }

    // MARK: Section

    /// Today's lists with background tasks taken out, and the Background
    /// section's tasks: open ones first, in list order, then those checked
    /// off today.
    static func split(open: [TaskItem], done: [TaskItem]) -> (open: [TaskItem], done: [TaskItem], background: [TaskItem]) {
        (
            open.filter { !$0.isBackground },
            done.filter { !$0.isBackground },
            open.filter(\.isBackground) + done.filter(\.isBackground)
        )
    }

    /// The workspace a task's agent lives in: the live herdr label, else
    /// the one kept at assignment time.
    static func workspaceLabel(for assignee: AgentRef, labels: [String: String]) -> String {
        labels[assignee.workspaceID] ?? assignee.label
    }

    /// The row's second line: who the task goes to, or why it will not go
    /// out yet. A task already sent always names its agent.
    static func assigneeLine(for task: TaskItem, labels: [String: String]) -> String {
        guard let info = task.background else { return "" }
        guard let assignee = info.assignee else { return "Unassigned" }
        if info.sentAt == nil, task.doneWhen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Not ready: add done-when"
        }
        return workspaceLabel(for: assignee, labels: labels)
    }

    // MARK: Editor

    /// herdr's agents by workspace label, labels in alphabetical order and
    /// agents in herdr's order within each.
    static func agentGroups(_ agents: [HerdrAgent], labels: [String: String]) -> [(label: String, agents: [HerdrAgent])] {
        var order: [String] = []
        var byLabel: [String: [HerdrAgent]] = [:]
        for agent in agents {
            let label = labels[agent.workspaceID] ?? agent.workspaceID
            if byLabel[label] == nil { order.append(label) }
            byLabel[label, default: []].append(agent)
        }
        return order
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { ($0, byLabel[$0] ?? []) }
    }

    /// One agent in the picker: its kind, what it is doing, and its pane.
    static func agentTitle(_ agent: HerdrAgent) -> String {
        "\(agent.agent ?? "agent") · \(agent.status.rawValue) · \(agent.paneID)"
    }

    /// The one-line hint under the editor's agent picker. `stored` is the
    /// task's saved background state (nil for a new task); `assignee` the
    /// agent picked in the editor. Picking a different agent for an unsent
    /// task starts it over as waiting, as `AppState.mergedBackground` does.
    static func readinessHint(doneWhen: String, assignee: AgentRef?, stored: BackgroundInfo?, startsWithFocus: Bool) -> String {
        if let stored, stored.sentAt != nil {
            return "Sent to its agent · \(label(for: stored.status))"
        }
        let hasOutcome = !doneWhen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasOutcome, assignee != nil, let stored, stored.assignee == assignee {
            switch stored.status {
            case .queued: return "Queued: goes out when its agent is free"
            case .paneClosed: return "Its pane closed: pick another agent"
            case .waiting, .running, .blocked, .review: break
            }
        }
        switch (hasOutcome, assignee != nil) {
        case (false, false): return "Needs a done-when and an agent"
        case (false, true): return "Needs a done-when"
        case (true, false): return "Needs an agent"
        case (true, true):
            return startsWithFocus
                ? "Ready: starts with your next focus session"
                : "Ready, but starting with focus is off in Settings"
        }
    }

    // MARK: Approvals

    /// The menu bar tooltip line while approvals wait.
    static func waitingText(_ count: Int) -> String {
        "\(count) background request\(count == 1 ? "" : "s") waiting"
    }

    /// The approval the floating bar shows, the oldest, and how many more wait.
    static func barApproval(_ approvals: [PendingApproval]) -> (approval: PendingApproval, more: Int)? {
        guard let first = approvals.first else { return nil }
        return (first, approvals.count - 1)
    }

    /// "customer-funnel · Bash command (unsandboxed)": where the prompt
    /// comes from and what it is about.
    static func sourceLine(for approval: PendingApproval, assignee: AgentRef?, labels: [String: String]) -> String {
        let workspace: String
        if let assignee {
            workspace = workspaceLabel(for: assignee, labels: labels)
        } else {
            // A pane id starts with its workspace id: `w5K:p1`.
            let id = approval.paneID.components(separatedBy: ":").first ?? approval.paneID
            workspace = labels[id] ?? id
        }
        return approval.title.isEmpty ? workspace : "\(workspace) · \(approval.title)"
    }

    /// Titles the parser gives prompts without a header of their own; their
    /// body is the plan or text above the question.
    private static let untitledPrompts: Set<String> = ["Plan approval", "Claude needs input"]

    /// The context lines worth showing, without Claude Code's "Tip:" lines.
    static func contextLines(for approval: PendingApproval) -> [String] {
        approval.body.filter { !$0.hasPrefix("Tip:") }
    }

    /// Up to three context lines for the panel; the full text goes in the
    /// tooltip. A permission prompt reads description, command, then notes.
    static func bodyExcerpt(for approval: PendingApproval) -> [String] {
        Array(contextLines(for: approval).prefix(3))
    }

    /// The bar's one-line excerpt: the question, then for a permission
    /// prompt the command, which follows its one-line description.
    static func excerpt(for approval: PendingApproval) -> String {
        guard !untitledPrompts.contains(approval.title) else { return approval.question }
        let lines = contextLines(for: approval)
        guard let command = lines.count >= 2 ? lines[1] : lines.first, !command.isEmpty else { return approval.question }
        return "\(approval.question) · \(command)"
    }

    /// Opening a pane focuses its herdr workspace, which the workspace lock
    /// would bounce straight back from during a session.
    static func canOpenPane(during phase: SessionPhase) -> Bool {
        phase != .work && phase != .paused
    }

    static let openPaneLaterHelp = "Available at the break"

    enum RowClick: Equatable {
        /// The click opens the agent's pane.
        case openPane
        /// The task has a pane, but a focus session is on.
        case later
        /// No pane to go to (unassigned).
        case none
    }

    /// What a click on a background row does.
    static func rowClick(hasPane: Bool, phase: SessionPhase) -> RowClick {
        guard hasPane else { return .none }
        return canOpenPane(during: phase) ? .openPane : .later
    }
}

/// How answering an approval from Tunnel Vision went, as the approval view
/// shows it.
enum ApprovalReplyState: Equatable, Sendable {
    case sending
    case sent
    case stillShowing
    case refused(String)

    init(_ answer: ApprovalAnswer) {
        switch answer {
        case .answered: self = .sent
        case .stillShowing: self = .stillShowing
        case .refused(let reason): self = .refused(reason)
        }
    }

    /// The line under the buttons; nil while sending.
    var message: String? {
        switch self {
        case .sending: nil
        case .sent: "Sent"
        case .stillShowing: "The prompt is still showing; answer it in the pane"
        case .refused(let reason): "Not sent: \(reason)"
        }
    }

    /// The user has to finish in the pane.
    var offersOpenPane: Bool {
        switch self {
        case .stillShowing, .refused: true
        case .sending, .sent: false
        }
    }

    /// How long the outcome stays up once it is known.
    var linger: Duration? {
        switch self {
        case .sending: nil
        case .sent: .seconds(2)
        case .stillShowing, .refused: .seconds(8)
        }
    }

    /// The approvals to show: answered ones still showing their outcome
    /// first, where the user just was, then those still waiting, oldest
    /// first.
    static func visible(live: [PendingApproval], answered: [PendingApproval]) -> [PendingApproval] {
        let liveIDs = Set(live.map(\.id))
        return answered.filter { !liveIDs.contains($0.id) } + live
    }
}
