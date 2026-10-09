import Foundation
import Observation
import os

/// How an approval answer went.
enum ApprovalAnswer: Equatable, Sendable {
    /// The keys went in and the prompt is gone.
    case answered
    /// The keys went in but the same prompt is still on screen; the user
    /// should open the pane.
    case stillShowing
    /// Nothing was sent: the prompt changed, the pane is no longer blocked,
    /// or the option cannot be answered from a button. The approval is gone.
    case refused(String)
}

/// Background tasks: tasks handed to Claude Code agents in herdr panes. A
/// focus session sends each ready one to its agent once; herdr's status
/// events then move it along (running, blocked on a prompt, finished for
/// review), and a prompt the agent shows is read off its screen so the
/// user can answer it from Tunnel Vision.
///
/// The task records live in `AppState`; this holds the herdr side: the
/// last agents list, the prompts waiting for an answer, and the event loop.
@MainActor
@Observable
final class BackgroundAgents {
    private static let log = Logger(subsystem: "com.tunnelvision.timer", category: "background")

    /// The model whose tasks are dispatched. Set by `AppState`.
    weak var model: AppState?

    /// Agent panes as herdr last reported them.
    private(set) var agents: [HerdrAgent] = []
    /// Workspace labels by id, from the last herdr snapshot.
    private(set) var workspaceLabels: [String: String] = [:]
    /// Prompts from agents working on background tasks, one per pane.
    private(set) var approvals: [PendingApproval] = []
    /// herdr answered the last time it was asked.
    private(set) var isHerdrReachable = false

    /// How long after sending an idle status still reads as "has not picked
    /// the prompt up yet". Past it, idle means finished.
    var idleGraceSeconds: TimeInterval = 10
    /// The pause after answering before checking the prompt went away.
    var settleDelay: Duration = .milliseconds(800)

    @ObservationIgnored private var client: HerdrControlling?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var watches = false
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    /// Tasks whose brief is going out right now; keeps a second dispatch
    /// (or an event arriving mid-send) from sending one twice.
    @ObservationIgnored private var sending: Set<UUID> = []
    /// Tasks the agent has been seen working on since they were sent.
    @ObservationIgnored private var seenWorking: Set<UUID> = []
    /// The dispatch a focus start kicked off, for tests to await.
    @ObservationIgnored private(set) var pendingDispatch: Task<Void, Never>?

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Connects to herdr. `watch` follows status events while a background
    /// task is out (the app); tests drive events by hand.
    func attach(client: HerdrControlling, watch: Bool = true) {
        self.client = client
        watches = watch
        watchIfNeeded()
    }

    // MARK: Agents

    /// Asks herdr for its agents and workspace labels, and brings the
    /// background tasks in line with what it reports. Nil when herdr cannot
    /// be reached.
    @discardableResult
    func refreshAgents() async -> [HerdrAgent]? {
        guard let client, client.isAvailable else {
            isHerdrReachable = false
            return nil
        }
        do {
            let list = try await client.agents()
            agents = list
            isHerdrReachable = true
            if let snapshot = try? await client.snapshot() {
                workspaceLabels = Dictionary(snapshot.workspaces.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
            }
            await reconcile(list)
            return list
        } catch {
            isHerdrReachable = false
            Self.log.info("agent list failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// An `assign_to` value or a caller's pane as an agent reference, from
    /// the last agents list. `target` is a pane id or a workspace label;
    /// without it the caller's own pane is used. Throws for a target herdr
    /// does not list; nil when there is nothing to assign.
    func resolveAssignee(target: String?, callerPane: String?, callerWorkspace: String?) throws -> AgentRef? {
        if let target = target?.trimmingCharacters(in: .whitespaces), !target.isEmpty {
            if let agent = agents.first(where: { $0.paneID == target }) {
                return reference(for: agent)
            }
            let lowered = target.lowercased()
            let workspaceIDs = workspaceLabels.filter { $0.value.lowercased() == lowered }.map(\.key)
            let candidates = agents.filter { workspaceIDs.contains($0.workspaceID) || $0.workspaceID == target }
            // Several agents in one workspace: the Claude one, then the focused one.
            let pick = candidates.first { $0.agent == "claude" && $0.focused }
                ?? candidates.first { $0.agent == "claude" }
                ?? candidates.first
            guard let pick else {
                throw BackgroundError.unknownAgent(target)
            }
            return reference(for: pick)
        }
        guard let pane = callerPane, !pane.isEmpty else { return nil }
        if let agent = agents.first(where: { $0.paneID == pane }) {
            return reference(for: agent)
        }
        // herdr not reachable from here: the pane id the helper inherited
        // is still the right target.
        let workspace = callerWorkspace ?? pane.components(separatedBy: ":").first ?? pane
        return AgentRef(paneID: pane, workspaceID: workspace, sessionID: nil, label: workspaceLabels[workspace] ?? workspace)
    }

    /// An agent from the list as the reference a task keeps.
    func reference(for agent: HerdrAgent) -> AgentRef {
        AgentRef(
            paneID: agent.paneID,
            workspaceID: agent.workspaceID,
            sessionID: agent.sessionID,
            label: workspaceLabels[agent.workspaceID] ?? agent.workspaceID
        )
    }

    // MARK: Dispatch

    /// A focus session started: send what is ready, off the caller's path.
    func focusStarted() {
        pendingDispatch = Task { [weak self] in
            await self?.dispatchReady()
        }
    }

    /// Sends every ready background task to its agent: an idle agent gets
    /// it now, a busy one queues it, a vanished pane marks it. Without
    /// herdr nothing happens.
    func dispatchReady() async {
        guard let model else { return }
        let ready = model.readyBackgroundTasks().map(\.id).filter { !sending.contains($0) }
        guard !ready.isEmpty else { return }
        guard let client, client.isAvailable else {
            Self.log.info("herdr not available: \(ready.count) background task(s) not sent")
            return
        }
        // Claimed before the first await, so nothing else sends them meanwhile.
        sending.formUnion(ready)
        defer { sending.subtract(ready) }
        guard let list = await refreshAgents() else {
            Self.log.info("herdr not reachable: \(ready.count) background task(s) not sent")
            return
        }
        for id in ready {
            guard let task = model.tasks.first(where: { $0.id == id }),
                  model.isReadyBackground(task),
                  let pane = task.background?.assignee?.paneID else { continue }
            guard let agent = list.first(where: { $0.paneID == pane }) else {
                model.updateBackground(id: id) { $0.status = .paneClosed }
                Self.log.info("background task \(id, privacy: .public): pane \(pane, privacy: .public) is gone")
                continue
            }
            if agent.status.isIdle, !isPaneTaken(pane, besides: id) {
                await send(taskID: id, to: pane)
            } else {
                model.updateBackground(id: id) { $0.status = .queued }
            }
        }
        watchIfNeeded()
    }

    /// The brief an agent gets for a task.
    nonisolated static func brief(for task: TaskItem) -> String {
        """
        \(task.title)

        Done when: \(task.doneWhen)

        Tunnel Vision task id: \(task.id.uuidString)

        Work through this to the end without stopping to ask, unless you truly must.
        When you are done, call the tunnelvision_report_background MCP tool with this task id, a one-line summary of what you did, and a link to the result (a PR or a file) if there is one.
        """
    }

    /// Another task of ours is out on the pane. A send marks its task
    /// running before submitting, so one going out right now counts.
    private func isPaneTaken(_ pane: String, besides id: UUID) -> Bool {
        guard let model else { return false }
        return model.tasks.contains { task in
            guard task.id != id, task.background?.assignee?.paneID == pane else { return false }
            return task.background?.status.holdsPane == true
        }
    }

    /// Marks the task sent first, so a relaunch or a second dispatch never
    /// sends it again, then submits the brief. A failed submit puts it back.
    private func send(taskID: UUID, to pane: String) async {
        guard let model, let client,
              let task = model.tasks.first(where: { $0.id == taskID }),
              let previous = task.background?.status else { return }
        let now = clock()
        model.updateBackground(id: taskID) {
            $0.sentAt = now
            $0.status = .running
        }
        sending.insert(taskID)
        defer { sending.remove(taskID) }
        do {
            try await client.prompt(target: pane, text: Self.brief(for: task))
            Self.log.info("background task \(taskID, privacy: .public) sent to \(pane, privacy: .public)")
            scheduleGraceCheck()
        } catch {
            model.updateBackground(id: taskID) {
                $0.sentAt = nil
                $0.status = previous
            }
            Self.log.error("sending background task \(taskID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The task out on the pane: sent, not yet finished.
    private func currentTask(onPane pane: String) -> TaskItem? {
        model?.tasks
            .filter { $0.background?.assignee?.paneID == pane && $0.background?.status.holdsPane == true }
            .max { ($0.background?.sentAt ?? .distantPast) < ($1.background?.sentAt ?? .distantPast) }
    }

    /// The next queued task for the pane, in list order.
    private func nextQueued(onPane pane: String) -> TaskItem? {
        model?.tasks.first { $0.background?.assignee?.paneID == pane && $0.background?.status == .queued && $0.background?.sentAt == nil }
    }

    // MARK: Status

    func handle(_ event: HerdrEvent) async {
        guard case .agentStatusChanged(let pane, let status) = event else { return }
        guard let status else {
            // No agent in the pane any more: it may have closed. A fresh
            // list settles it, marking a task out on it as pane closed.
            if currentTask(onPane: pane) != nil {
                await refreshAgents()
            }
            return
        }
        if let index = agents.firstIndex(where: { $0.paneID == pane }) {
            let old = agents[index]
            agents[index] = HerdrAgent(paneID: old.paneID, workspaceID: old.workspaceID, cwd: old.cwd, agent: old.agent, status: status, focused: old.focused, sessionID: old.sessionID)
        }
        await apply(status, onPane: pane)
    }

    /// One pane's status, applied to the task out on it, then the pane's
    /// queue moves if it is free.
    private func apply(_ status: HerdrAgentStatus, onPane pane: String) async {
        guard let model else { return }
        if let task = currentTask(onPane: pane), let info = task.background {
            switch status {
            case .working:
                seenWorking.insert(task.id)
                if info.status == .blocked {
                    model.updateBackground(id: task.id) { $0.status = .running }
                }
                dropApproval(onPane: pane)
            case .blocked:
                if info.status != .blocked {
                    model.updateBackground(id: task.id) { $0.status = .blocked }
                }
                await captureApproval(pane: pane, taskID: task.id)
            case .idle, .done:
                dropApproval(onPane: pane)
                // Right after the prompt goes in the pane can still read
                // idle; that is not the agent finishing.
                let sentAt = info.sentAt ?? .distantPast
                let settled = seenWorking.contains(task.id) || clock().timeIntervalSince(sentAt) >= idleGraceSeconds
                if settled {
                    model.updateBackground(id: task.id) { $0.status = .review }
                    seenWorking.remove(task.id)
                } else {
                    if info.status == .blocked {
                        model.updateBackground(id: task.id) { $0.status = .running }
                    }
                    return
                }
            case .unknown:
                return
            }
        }
        if status.isIdle, currentTask(onPane: pane) == nil, let next = nextQueued(onPane: pane), !sending.contains(next.id) {
            await send(taskID: next.id, to: pane)
        }
    }

    /// Brings stored statuses in line with a fresh agents list: catches
    /// events missed while disconnected, and marks tasks whose pane closed.
    private func reconcile(_ list: [HerdrAgent]) async {
        guard let model else { return }
        let byPane = Dictionary(list.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
        var panes: [String] = []
        for task in model.tasks {
            guard let info = task.background, let pane = info.assignee?.paneID,
                  info.status == .queued || info.status.holdsPane else { continue }
            if byPane[pane] == nil {
                model.updateBackground(id: task.id) { $0.status = .paneClosed }
                dropApproval(onPane: pane)
            } else if !panes.contains(pane) {
                panes.append(pane)
            }
        }
        for pane in panes {
            if let status = byPane[pane]?.status {
                await apply(status, onPane: pane)
            }
        }
    }

    // MARK: Approvals

    /// Reads the blocked pane and offers its prompt. A screen that does not
    /// parse leaves no approval; the task still shows as blocked.
    private func captureApproval(pane: String, taskID: UUID) async {
        guard let client else { return }
        guard let text = try? await client.read(target: pane), let prompt = ApprovalParser.parse(text) else {
            Self.log.info("pane \(pane, privacy: .public) is blocked but its prompt did not parse")
            dropApproval(onPane: pane)
            return
        }
        // The pane may have moved on while it was read.
        guard currentTask(onPane: pane)?.id == taskID else { return }
        if let existing = approvals.first(where: { $0.paneID == pane }), existing.fingerprint == prompt.fingerprint {
            return
        }
        dropApproval(onPane: pane)
        approvals.append(PendingApproval(id: UUID(), paneID: pane, taskID: taskID, prompt: prompt))
    }

    private func dropApproval(onPane pane: String) {
        if approvals.contains(where: { $0.paneID == pane }) {
            approvals.removeAll { $0.paneID == pane }
        }
    }

    func dropApproval(id: UUID) {
        approvals.removeAll { $0.id == id }
    }

    /// Answers a prompt with the option numbered `option`. Re-checks first
    /// that the pane is still blocked on the very same prompt, then moves
    /// the cursor there and presses Enter, then looks again.
    func answer(approvalID: UUID, option: Int) async -> ApprovalAnswer {
        guard let approval = approvals.first(where: { $0.id == approvalID }) else {
            return .refused("no such approval; it may have been answered in the pane")
        }
        guard let target = approval.options.firstIndex(where: { $0.number == option }) else {
            return .refused("the prompt has no option \(option)")
        }
        guard !approval.options[target].needsTypedInput else {
            return .refused("“\(approval.options[target].label)” needs typing; open the pane")
        }
        guard let client, client.isAvailable else {
            return .refused("herdr is not reachable")
        }
        let pane = approval.paneID
        func refuse(_ reason: String) -> ApprovalAnswer {
            dropApproval(id: approvalID)
            return .refused(reason)
        }
        guard let list = try? await client.agents() else {
            return refuse("herdr did not list its agents")
        }
        agents = list
        guard list.first(where: { $0.paneID == pane })?.status == .blocked else {
            return refuse("the agent is no longer waiting on this prompt")
        }
        guard let text = try? await client.read(target: pane),
              let current = ApprovalParser.parse(text),
              current.fingerprint == approval.fingerprint else {
            return refuse("the prompt on screen changed")
        }
        do {
            try await client.sendKeys(target: pane, keys: ApprovalParser.keys(from: current.cursorIndex, to: target))
        } catch {
            return refuse("sending the keys failed: \(error)")
        }
        try? await Task.sleep(for: settleDelay)
        let next = (try? await client.read(target: pane)).flatMap(ApprovalParser.parse)
        if next?.fingerprint == approval.fingerprint {
            Self.log.info("approval on \(pane, privacy: .public) still showing after the answer")
            return .stillShowing
        }
        dropApproval(id: approvalID)
        guard let task = currentTask(onPane: pane), task.background?.status == .blocked else { return .answered }
        if let next {
            // The agent went straight to its next prompt; herdr may not
            // report a change from blocked to blocked.
            approvals.append(PendingApproval(id: UUID(), paneID: pane, taskID: task.id, prompt: next))
        } else {
            model?.updateBackground(id: task.id) { $0.status = .running }
        }
        return .answered
    }

    // MARK: Open pane

    /// Brings the terminal app forward; tests swap it out.
    @ObservationIgnored var activateHost: () -> Void = { HerdrHost.activateTerminal() }

    /// Shows the agent's pane: herdr focuses it, then the terminal hosting
    /// herdr comes to the front. False when herdr could not be reached.
    @discardableResult
    func openPane(_ paneID: String) async -> Bool {
        guard let client, client.isAvailable else { return false }
        do {
            try await client.focusAgent(target: paneID)
        } catch {
            Self.log.info("focusing pane \(paneID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return false
        }
        activateHost()
        return true
    }

    // MARK: Event loop

    /// A background task is out or queued: its pane's status matters.
    private var needsWatching: Bool {
        model?.tasks.contains { info in
            guard let status = info.background?.status else { return false }
            return status == .queued || status.holdsPane
        } ?? false
    }

    /// Follows herdr's status events while something needs them, and
    /// reconnects with backoff. Each connection starts by reconciling.
    func watchIfNeeded() {
        guard watches, eventTask == nil, client != nil, needsWatching else { return }
        eventTask = Task { [weak self] in
            await self?.watchLoop()
            self?.eventTask = nil
        }
    }

    private func watchLoop() async {
        var backoff: Duration = .seconds(1)
        while needsWatching, !Task.isCancelled, let client {
            let stream = client.events(kinds: HerdrProtocol.agentEventKinds)
            if await refreshAgents() != nil {
                backoff = .seconds(1)
            }
            for await event in stream {
                await handle(event)
                guard needsWatching else { return }
            }
            guard needsWatching, !Task.isCancelled else { return }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
        }
    }

    /// The pane may finish inside the idle grace and send no further event:
    /// look once more when the grace is over.
    private func scheduleGraceCheck() {
        guard watches else { return }
        let delay = idleGraceSeconds + 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.refreshAgents()
        }
        watchIfNeeded()
    }
}

enum BackgroundError: Error, Equatable {
    case unknownAgent(String)
}
