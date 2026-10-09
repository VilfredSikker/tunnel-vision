import Observation
import SwiftUI

/// Answers given from Tunnel Vision and how they went. An answer usually
/// removes its approval from `BackgroundAgents`, so the outcome is kept
/// here for a moment and the views show the answered approval until it
/// has been read. Shared by the panel and the floating bar.
@MainActor
@Observable
final class ApprovalReplies {
    static let shared = ApprovalReplies()

    struct Reply {
        let approval: PendingApproval
        var state: ApprovalReplyState
    }

    /// Oldest answer first.
    private(set) var replies: [Reply] = []

    func state(for id: UUID) -> ApprovalReplyState? {
        replies.first { $0.approval.id == id }?.state
    }

    /// Live approvals plus answered ones still showing their outcome.
    func visible(_ live: [PendingApproval]) -> [PendingApproval] {
        ApprovalReplyState.visible(live: live, answered: replies.map(\.approval))
    }

    /// Sends the answer; the task is returned for tests to await.
    @discardableResult
    func answer(_ approval: PendingApproval, option: Int, background: BackgroundAgents) -> Task<Void, Never>? {
        guard state(for: approval.id) != .sending else { return nil }
        set(.sending, for: approval)
        return Task { [weak self] in
            let result = await background.answer(approvalID: approval.id, option: option)
            guard let self else { return }
            let state = ApprovalReplyState(result)
            self.set(state, for: approval)
            self.forget(approval.id, after: state)
        }
    }

    /// Clears an outcome once it has been up long enough.
    private func forget(_ id: UUID, after state: ApprovalReplyState) {
        guard let linger = state.linger else { return }
        Task { [weak self] in
            try? await Task.sleep(for: linger)
            // A newer answer to the same prompt keeps its own outcome.
            if self?.state(for: id) == state {
                self?.replies.removeAll { $0.approval.id == id }
            }
        }
    }

    private func set(_ state: ApprovalReplyState, for approval: PendingApproval) {
        if let index = replies.firstIndex(where: { $0.approval.id == approval.id }) {
            replies[index].state = state
        } else {
            replies.append(Reply(approval: approval, state: state))
        }
    }
}

/// One prompt from a background agent with its options as buttons. The
/// full variant sits in the panel under its task; the compact one in the
/// floating bar, under the clock.
struct ApprovalView: View {
    enum Style {
        case full
        case compact
    }

    let model: AppState
    let approval: PendingApproval
    var style: Style = .full
    /// How many more approvals wait behind this one (the bar's "+N").
    var more: Int = 0

    private var replies: ApprovalReplies { .shared }
    private var reply: ApprovalReplyState? { replies.state(for: approval.id) }
    private var isSending: Bool { reply == .sending }
    /// Answered and gone from the agent: only the outcome is left to show.
    private var isSettled: Bool { !model.background.approvals.contains { $0.id == approval.id } }

    private var assignee: AgentRef? {
        model.tasks.first { $0.id == approval.taskID }?.background?.assignee
    }

    private var source: String {
        BackgroundPresentation.sourceLine(for: approval, assignee: assignee, labels: model.background.workspaceLabels)
    }

    private var buttonOptions: [ApprovalOption] { approval.options.filter { !$0.needsTypedInput } }
    private var hasTypedOption: Bool { approval.options.contains(where: \.needsTypedInput) }
    private var offersOpenPane: Bool { hasTypedOption || reply?.offersOpenPane == true }

    var body: some View {
        switch style {
        case .full: full
        case .compact: compact
        }
    }

    // MARK: Full

    private var full: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(approval.question)
                .font(.callout)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            let lines = BackgroundPresentation.bodyExcerpt(for: approval)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .help(approval.body.joined(separator: "\n"))
            }
            if !isSettled {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(buttonOptions, id: \.number) { option in
                        optionButton(option)
                            .controlSize(.small)
                    }
                }
                .padding(.top, 2)
            }
            footer
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: Compact

    private var compact: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(source)
                    .fontWeight(.semibold)
                    + Text(" " + BackgroundPresentation.excerpt(for: approval))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                if more > 0 {
                    Text("+\(more)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .help("\(more) more waiting; see the panel")
                }
            }
            .font(.caption2)
            .lineLimit(1)
            .help(([source, approval.question] + approval.body).joined(separator: "\n"))
            if !isSettled {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { compactButtons }
                    VStack(alignment: .leading, spacing: 3) { compactButtons }
                }
                .controlSize(.small)
            }
            footer
        }
    }

    @ViewBuilder
    private var compactButtons: some View {
        ForEach(buttonOptions, id: \.number) { option in
            optionButton(option)
        }
    }

    // MARK: Parts

    private func optionButton(_ option: ApprovalOption) -> some View {
        Button {
            replies.answer(approval, option: option.number, background: model.background)
        } label: {
            Text(option.label)
                .lineLimit(style == .compact ? 1 : 2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: style == .compact ? 220 : .infinity, alignment: .leading)
        }
        .approvalButtonStyle(compact: style == .compact)
        .disabled(isSending)
        .help(([option.label] + option.detail).joined(separator: "\n"))
    }

    /// The outcome of the last answer, and "Open pane" when the user has to
    /// finish in the pane itself.
    @ViewBuilder
    private var footer: some View {
        if isSending || reply?.message != nil || offersOpenPane {
            HStack(spacing: 6) {
                if isSending {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Sending…")
                } else if let message = reply?.message {
                    Text(message)
                        .foregroundStyle(reply == .sent ? Theme.allowed : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if offersOpenPane {
                    OpenPaneButton(model: model, paneID: approval.paneID, compact: style == .compact)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

/// Brings an agent's pane forward. Off during a work session, when the
/// workspace lock would bounce straight back.
struct OpenPaneButton: View {
    let model: AppState
    let paneID: String
    var title: String = "Open pane"
    /// In the floating bar: drawn by SwiftUI itself, so the first click lands.
    var compact: Bool = false

    @State private var failed = false

    private var allowed: Bool { BackgroundPresentation.canOpenPane(during: model.phase) }

    var body: some View {
        Button(failed ? "Couldn't open — retry" : title) {
            Task {
                failed = !(await model.background.openPane(paneID))
            }
        }
        .paneButtonStyle(compact: compact)
        .disabled(!allowed)
        .help(allowed ? "Show the agent's pane in herdr" : BackgroundPresentation.openPaneLaterHelp)
    }
}

// MARK: - Button styles

/// The floating bar's buttons are drawn by SwiftUI itself: an AppKit-backed
/// control there may want a click to focus the panel before it acts.
private struct BarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.18 : 0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

private extension View {
    @ViewBuilder
    func approvalButtonStyle(compact: Bool) -> some View {
        if compact {
            buttonStyle(BarButtonStyle())
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func paneButtonStyle(compact: Bool) -> some View {
        if compact {
            buttonStyle(.plain).foregroundStyle(.tint)
        } else {
            buttonStyle(.link)
        }
    }
}
