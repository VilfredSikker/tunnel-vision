import Foundation
import TunnelVisionControlKit
import XCTest

@testable import TunnelVision

// MARK: - Prompt parser

final class ApprovalParserTests: XCTestCase {
    func testParsesTheUnsandboxedBashPrompt() throws {
        let prompt = try XCTUnwrap(ApprovalParser.parse(ApprovalFixtures.bashUnsandboxed))
        XCTAssertEqual(prompt.title, "Bash command (unsandboxed)")
        XCTAssertEqual(prompt.question, "Do you want to proceed?")
        XCTAssertEqual(prompt.body, [
            "Tip: auto mode handles these prompts for you — choose \"switch to auto mode\" below",
            "Print spike-three",
            "echo spike-three",
        ], "the dashed rules around the command are not body lines")
        XCTAssertEqual(prompt.options.map(\.number), [1, 2, 3])
        XCTAssertEqual(prompt.options.map(\.label), [
            "Yes",
            "Yes, and switch to auto mode · auto mode handles these prompts for you",
            "No",
        ])
        XCTAssertEqual(prompt.cursorIndex, 0)
        XCTAssertFalse(prompt.options.contains { $0.needsTypedInput })
    }

    func testParsesTheAskRuleBashPrompt() throws {
        let prompt = try XCTUnwrap(ApprovalParser.parse(ApprovalFixtures.bashAskRule))
        XCTAssertEqual(prompt.title, "Bash command")
        XCTAssertEqual(prompt.question, "Do you want to proceed?")
        XCTAssertEqual(prompt.body, [
            "Echo spike-two",
            "echo spike-two",
            "Ask rule Bash(echo spike*) overrides auto mode for this command.",
            "/permissions to let auto mode decide",
        ])
        XCTAssertEqual(prompt.options.map(\.label), ["Yes", "No"], "the Esc footer is not an option")
        XCTAssertEqual(prompt.cursorIndex, 0)
    }

    func testParsesAnAskUserQuestionWithDescriptionsAndASeparator() throws {
        let prompt = try XCTUnwrap(ApprovalParser.parse(ApprovalFixtures.askUserQuestion))
        XCTAssertEqual(prompt.title, "Plan scope", "the header, without its checkbox")
        XCTAssertEqual(prompt.question, "What should the plan cover when you say \"plan a file\"?")
        XCTAssertEqual(prompt.options.map(\.number), [1, 2, 3, 4, 5], "the rule between 4 and 5 does not end the list")
        XCTAssertEqual(prompt.options.map(\.label), [
            "Permission test flow", "A specific file", "Review existing files", "Type something.", "Chat about this",
        ], "the `❯ Plan a file` input line at the top is not an option")
        XCTAssertEqual(prompt.options[0].detail, [
            "Plan a repeatable way to create a file, then delete it, to check which steps trigger approval prompts or hooks.",
        ])
        XCTAssertEqual(prompt.options.map(\.needsTypedInput), [false, false, false, true, true])
        XCTAssertEqual(prompt.cursorIndex, 0)
    }

    func testParsesAPlanApproval() throws {
        let prompt = try XCTUnwrap(ApprovalParser.parse(ApprovalFixtures.planApproval))
        XCTAssertEqual(prompt.title, "Plan approval")
        XCTAssertEqual(prompt.question, "Claude has written up a plan and is ready to execute. Would you like to proceed?")
        XCTAssertEqual(prompt.options.map(\.label), ["Yes, and use auto mode", "Yes, manually approve edits", "Tell Claude what to change"])
        XCTAssertEqual(prompt.options[2].detail, ["shift+tab to approve with this feedback"])
        XCTAssertEqual(prompt.options.map(\.needsTypedInput), [false, false, true])
        XCTAssertEqual(prompt.body.first, "- .../spike/permission-test.txt only. hook.sh, probe.txt and settings.json stay untouched.")
        XCTAssertEqual(prompt.body.last, "To explain why no prompt appeared, read settings.json and hook.sh in the spike directory (read-only). Not part of this plan unless you ask.")
    }

    func testCursorBelowTheFirstOption() throws {
        let moved = ApprovalFixtures.bashUnsandboxed
            .replacingOccurrences(of: " ❯ 1. Yes\n   2. Yes,", with: "   1. Yes\n ❯ 2. Yes,")
        let prompt = try XCTUnwrap(ApprovalParser.parse(moved))
        XCTAssertEqual(prompt.cursorIndex, 1)
        XCTAssertEqual(prompt.options.map(\.number), [1, 2, 3], "options above the cursor are found too")
    }

    func testFingerprintTellsTwoCommandsApart() throws {
        let first = try XCTUnwrap(ApprovalParser.parse(ApprovalFixtures.bashAskRule))
        let other = try XCTUnwrap(ApprovalParser.parse(ApprovalFixtures.bashAskRule.replacingOccurrences(of: "echo spike-two", with: "rm -rf build")))
        XCTAssertEqual(first.options.map(\.label), other.options.map(\.label))
        XCTAssertNotEqual(first.fingerprint, other.fingerprint, "same title and options, different command")
        XCTAssertEqual(first.fingerprint, try XCTUnwrap(ApprovalParser.parse(ApprovalFixtures.bashAskRule)).fingerprint)
    }

    func testAScreenWithoutAPromptIsNotParsed() {
        XCTAssertNil(ApprovalParser.parse("❯ Plan a file\n\n  1. a numbered step\n  2. another"), "no cursor on a numbered option")
        XCTAssertNil(ApprovalParser.parse(""))
    }

    func testTypedInputLabels() {
        XCTAssertTrue(ApprovalParser.needsTypedInput("Type something."))
        XCTAssertTrue(ApprovalParser.needsTypedInput("Chat about this"))
        XCTAssertTrue(ApprovalParser.needsTypedInput("Tell Claude what to change"))
        XCTAssertFalse(ApprovalParser.needsTypedInput("Yes"))
        XCTAssertFalse(ApprovalParser.needsTypedInput("No"))
    }

    func testKeysMoveFromTheCursorThenSelect() {
        XCTAssertEqual(ApprovalParser.keys(from: 0, to: 2), ["Down", "Down", "Enter"], "cursor above the choice")
        XCTAssertEqual(ApprovalParser.keys(from: 2, to: 0), ["Up", "Up", "Enter"], "cursor below the choice")
        XCTAssertEqual(ApprovalParser.keys(from: 1, to: 1), ["Enter"], "cursor already on it")
    }
}

// MARK: - herdr wire format

final class HerdrAgentProtocolTests: XCTestCase {
    func testParsesTheAgentList() throws {
        let line = Data("""
        {"id":"x","result":{"type":"agent_list","agents":[
        {"pane_id":"w5K:p1","workspace_id":"w5K","tab_id":"w5K:t1","terminal_id":"t1","cwd":"/repo","agent":"claude","agent_status":"working","focused":true,"revision":3,"agent_session":{"source":"hook","agent":"claude","kind":"id","value":"abc-123"}},
        {"pane_id":"w6:p2","workspace_id":"w6","tab_id":"w6:t1","terminal_id":"t2","agent":null,"agent_status":"idle","focused":false,"revision":1,"agent_session":{"source":"hook","agent":"claude","kind":"path","value":"/tmp/x.jsonl"}},
        {"pane_id":"w7:p1","workspace_id":"w7","tab_id":"w7:t1","terminal_id":"t3","agent_status":"sleeping","focused":false,"revision":1}
        ]}}
        """.utf8)
        let agents = try HerdrProtocol.parseAgents(line)
        XCTAssertEqual(agents.map(\.paneID), ["w5K:p1", "w6:p2", "w7:p1"])
        XCTAssertEqual(agents[0].status, .working)
        XCTAssertEqual(agents[0].sessionID, "abc-123")
        XCTAssertEqual(agents[0].agent, "claude")
        XCTAssertTrue(agents[0].focused)
        XCTAssertNil(agents[1].sessionID, "a session path is not a session id")
        XCTAssertEqual(agents[2].status, .unknown, "an unknown status reads as unknown")
    }

    func testParsesAPaneRead() throws {
        let line = Data(#"{"id":"x","result":{"type":"pane_read","read":{"pane_id":"w5K:p1","workspace_id":"w5K","tab_id":"w5K:t1","source":"visible","format":"text","text":"hello\nworld","revision":4,"truncated":false}}}"#.utf8)
        XCTAssertEqual(try HerdrProtocol.parseRead(line), "hello\nworld")
        XCTAssertThrowsError(try HerdrProtocol.parseRead(Data(#"{"id":"x","result":{}}"#.utf8)))
    }

    func testParsesAgentStatusEvents() {
        let changed = Data(#"{"event":"pane.agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"w5K:p1","agent_status":"blocked"}}"#.utf8)
        XCTAssertEqual(HerdrProtocol.parseEvent(changed), .agentStatusChanged(paneID: "w5K:p1", status: .blocked))
        let gone = Data(#"{"event":"pane_agent_status_changed","data":{"pane_id":"w5K:p1","agent_status":null}}"#.utf8)
        XCTAssertEqual(HerdrProtocol.parseEvent(gone), .agentStatusChanged(paneID: "w5K:p1", status: nil))
    }
}

// MARK: - Model

final class BackgroundModelTests: XCTestCase {
    func testAnArchiveWithoutBackgroundStillDecodes() throws {
        let json = Data("""
        {"id":"8D7E2C4F-3B0A-4C59-9E61-2B5F8A1D0C77","title":"Old","durationSeconds":1500,"overrides":[],"doneDays":[]}
        """.utf8)
        let task = try JSONDecoder().decode(TaskItem.self, from: json)
        XCTAssertNil(task.background)
        XCTAssertFalse(task.isBackground)

        let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.startBackgroundTasksWithFocus, "on by default")
    }

    func testBackgroundRoundTripsAndToleratesAnUnknownStatus() throws {
        var task = TaskItem(title: "Agent work", durationSeconds: 60)
        task.background = BackgroundInfo(
            assignee: AgentRef(paneID: "w5:p1", workspaceID: "w5", sessionID: "s1", label: "repo"),
            status: .paneClosed,
            sentAt: Date(timeIntervalSince1970: 1_000),
            summary: "Did it",
            link: "https://example.com/pr/1"
        )
        let decoded = try JSONDecoder().decode(TaskItem.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(decoded, task)

        let future = Data(#"{"status":"archived","sentAt":10}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(BackgroundInfo.self, from: future).status, .review, "a sent task with a status this build does not know")
        XCTAssertEqual(try JSONDecoder().decode(BackgroundInfo.self, from: Data("{}".utf8)).status, .waiting)
    }

    func testARepeatedCopyKeepsTheAgentAndStartsUnsent() {
        let agent = AgentRef(paneID: "w5:p1", workspaceID: "w5", sessionID: nil, label: "repo")
        var task = TaskItem(title: "Agent work", durationSeconds: 60, doneWhen: "PR open")
        task.background = BackgroundInfo(assignee: agent, status: .review, sentAt: Date(), summary: "done", link: "x")
        let copy = task.repeatedCopy()
        XCTAssertEqual(copy.background, BackgroundInfo(assignee: agent))
        XCTAssertNil(TaskItem(title: "Plain", durationSeconds: 60).repeatedCopy().background)
    }

    func testTheBriefCarriesTheOutcomeTheIdAndTheReportTool() {
        let task = TaskItem(title: "Fix the flaky test", durationSeconds: 60, doneWhen: "CI green on main")
        let brief = BackgroundAgents.brief(for: task)
        XCTAssertTrue(brief.hasPrefix("Fix the flaky test\n"))
        XCTAssertTrue(brief.contains("Done when: CI green on main"))
        XCTAssertTrue(brief.contains(task.id.uuidString))
        XCTAssertTrue(brief.contains("without stopping to ask, unless you truly must"))
        XCTAssertTrue(brief.contains("tunnelvision_report_background"))
        XCTAssertTrue(brief.contains("summary"))
        XCTAssertTrue(brief.contains("link"))
    }
}

// MARK: - Dispatch, status, approvals

@MainActor
final class BackgroundAgentsTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_752_000_000)
    private var url: URL!
    private var client: FakeHerdrClient!

    private let pane = "w5:p1"
    private var agent: AgentRef { AgentRef(paneID: pane, workspaceID: "w5", sessionID: "s1", label: "repo") }

    override func setUp() async throws {
        now = Date(timeIntervalSince1970: 1_752_000_000)
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TunnelVisionBackground-\(UUID().uuidString)")
            .appendingPathComponent("data.json")
        client = FakeHerdrClient()
        client.agentsResult = [herdrAgent(pane, .idle)]
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func makeState() -> AppState {
        let state = AppState(fileURL: url, clock: { [weak self] in self?.now ?? Date() }, autoTick: false)
        var quiet = state.settings
        quiet.soundOn = false
        state.updateSettings(quiet)
        state.background.settleDelay = .zero
        state.background.attach(client: client, watch: false)
        return state
    }

    private func herdrAgent(_ pane: String, _ status: HerdrAgentStatus, workspace: String = "w5") -> HerdrAgent {
        HerdrAgent(paneID: pane, workspaceID: workspace, cwd: "/repo", agent: "claude", status: status, focused: false, sessionID: "s1")
    }

    @discardableResult
    private func addBackground(_ state: AppState, title: String = "Agent work", doneWhen: String = "PR open", assignee: AgentRef?) -> TaskItem {
        state.addTask(title: title, durationSeconds: 60, presetID: nil, overrides: [], doneWhen: doneWhen, background: BackgroundInfo(assignee: assignee))
    }

    private func info(_ state: AppState, _ task: TaskItem) -> BackgroundInfo? {
        state.tasks.first { $0.id == task.id }?.background
    }

    private func status(_ state: AppState, _ task: TaskItem) -> BackgroundStatus? {
        info(state, task)?.status
    }

    private func event(_ status: HerdrAgentStatus, pane: String? = nil) -> HerdrEvent {
        .agentStatusChanged(paneID: pane ?? self.pane, status: status)
    }

    // MARK: Ready

    func testReadyRules() {
        let state = makeState()
        let ready = addBackground(state, assignee: agent)
        let noOutcome = addBackground(state, doneWhen: "", assignee: agent)
        let unassigned = addBackground(state, assignee: nil)
        let plain = state.addTask(title: "Plain", durationSeconds: 60, presetID: nil, overrides: [], doneWhen: "x")
        let doneToday = addBackground(state, assignee: agent)
        state.setTaskDone(id: doneToday.id, done: true)
        let queued = addBackground(state, assignee: agent)
        state.updateBackground(id: queued.id) { $0.status = .queued }
        let sent = addBackground(state, assignee: agent)
        state.updateBackground(id: sent.id) { $0.sentAt = Date() }

        XCTAssertEqual(state.readyBackgroundTasks().map(\.id), [ready.id])
        for task in [noOutcome, unassigned, plain, doneToday, queued, sent] {
            XCTAssertFalse(state.isReadyBackground(state.tasks.first { $0.id == task.id }!), task.title)
        }
    }

    func testBackgroundTasksNeverRunOnTheTimer() {
        let state = makeState()
        let task = addBackground(state, assignee: agent)
        XCTAssertNil(state.nextUpID(on: state.todayKey), "a background task is never next up")
        state.startTask(id: task.id)
        XCTAssertEqual(state.phase, .idle, "and never starts a focus session")
        XCTAssertNil(state.repeatTask(id: task.id))
        let plain = state.addTask(title: "Plain", durationSeconds: 60, presetID: nil, overrides: [])
        XCTAssertEqual(state.nextUpID(on: state.todayKey), plain.id)
    }

    // MARK: Dispatch

    func testFocusStartSendsOnceAndSentAtPersists() async {
        let state = makeState()
        let task = addBackground(state, assignee: agent)
        let plain = state.addTask(title: "Plain", durationSeconds: 60, presetID: nil, overrides: [])

        state.startTask(id: plain.id)
        await state.background.pendingDispatch?.value
        XCTAssertEqual(client.prompts.count, 1)
        XCTAssertEqual(client.prompts.first?.pane, pane)
        XCTAssertEqual(client.prompts.first?.text, BackgroundAgents.brief(for: task))
        XCTAssertEqual(status(state, task), .running)
        XCTAssertEqual(info(state, task)?.sentAt, now)

        // Pause and resume enter the work phase again: nothing goes twice.
        state.pause()
        state.resume()
        await state.background.pendingDispatch?.value
        state.stopNow()
        state.startTask(id: plain.id)
        await state.background.pendingDispatch?.value
        XCTAssertEqual(client.prompts.count, 1, "a second session does not resend")

        // A relaunch reads the same archive: still sent, never resent.
        let relaunched = makeState()
        XCTAssertEqual(info(relaunched, task)?.sentAt, now)
        XCTAssertEqual(status(relaunched, task), .running)
        await relaunched.background.dispatchReady()
        XCTAssertEqual(client.prompts.count, 1, "a relaunch does not resend")
    }

    func testTheSettingTurnsFocusDispatchOff() async {
        let state = makeState()
        var settings = state.settings
        settings.startBackgroundTasksWithFocus = false
        state.updateSettings(settings)
        let task = addBackground(state, assignee: agent)
        let plain = state.addTask(title: "Plain", durationSeconds: 60, presetID: nil, overrides: [])
        state.startTask(id: plain.id)
        await state.background.pendingDispatch?.value
        XCTAssertTrue(client.prompts.isEmpty)
        XCTAssertEqual(status(state, task), .waiting)
    }

    func testUnassignedTasksAreSkipped() async {
        let state = makeState()
        let task = addBackground(state, assignee: nil)
        await state.background.dispatchReady()
        XCTAssertTrue(client.prompts.isEmpty)
        XCTAssertEqual(status(state, task), .waiting)
        XCTAssertEqual(client.agentsCalls, 0, "nothing ready, herdr is not even asked")
    }

    func testWithoutHerdrDispatchIsANoOp() async {
        let state = makeState()
        let task = addBackground(state, assignee: agent)
        client.isAvailable = false
        await state.background.dispatchReady()
        XCTAssertEqual(status(state, task), .waiting)

        client.isAvailable = true
        client.agentsError = HerdrError.disconnected
        await state.background.dispatchReady()
        XCTAssertEqual(status(state, task), .waiting, "an unreachable herdr marks nothing, not even a closed pane")
        XCTAssertTrue(client.prompts.isEmpty)
    }

    func testAClosedPaneIsMarked() async {
        let state = makeState()
        let task = addBackground(state, assignee: AgentRef(paneID: "w9:p4", workspaceID: "w9", sessionID: nil, label: "gone"))
        await state.background.dispatchReady()
        XCTAssertEqual(status(state, task), .paneClosed)
        XCTAssertTrue(client.prompts.isEmpty)
    }

    func testAFailedPromptLeavesTheTaskUnsent() async {
        let state = makeState()
        let task = addBackground(state, assignee: agent)
        client.promptError = HerdrError.disconnected
        await state.background.dispatchReady()
        XCTAssertNil(info(state, task)?.sentAt)
        XCTAssertEqual(status(state, task), .waiting, "ready again for the next session")
    }

    func testABusyAgentQueuesThenGetsItWhenIdle() async {
        let state = makeState()
        client.agentsResult = [herdrAgent(pane, .working)]
        let task = addBackground(state, assignee: agent)
        await state.background.dispatchReady()
        XCTAssertEqual(status(state, task), .queued)
        XCTAssertTrue(client.prompts.isEmpty)

        await state.background.handle(event(.working))
        XCTAssertTrue(client.prompts.isEmpty)
        await state.background.handle(event(.idle))
        XCTAssertEqual(client.prompts.count, 1)
        XCTAssertEqual(status(state, task), .running)
        XCTAssertEqual(info(state, task)?.sentAt, now)
    }

    func testOneTaskAtATimePerPane() async {
        let state = makeState()
        let first = addBackground(state, title: "First", assignee: agent)
        let second = addBackground(state, title: "Second", assignee: agent)
        await state.background.dispatchReady()
        XCTAssertEqual(status(state, first), .running)
        XCTAssertEqual(status(state, second), .queued, "the pane is taken by the first")
        XCTAssertEqual(client.prompts.count, 1)

        await state.background.handle(event(.working))
        await state.background.handle(event(.idle))
        XCTAssertEqual(status(state, first), .review)
        XCTAssertEqual(status(state, second), .running, "goes out once the first is in review")
        XCTAssertEqual(client.prompts.map(\.text), [BackgroundAgents.brief(for: first), BackgroundAgents.brief(for: second)])
    }

    // MARK: Status

    func testIdleRightAfterSendingIsNotFinishing() async {
        let state = makeState()
        let task = addBackground(state, assignee: agent)
        await state.background.dispatchReady()

        await state.background.handle(event(.idle))
        XCTAssertEqual(status(state, task), .running, "the agent has not picked the prompt up yet")
        now = now.addingTimeInterval(11)
        await state.background.handle(event(.idle))
        XCTAssertEqual(status(state, task), .review, "idle 10 s after sending is finished")
    }

    func testStatusMapping() async {
        let state = makeState()
        let task = addBackground(state, assignee: agent)
        await state.background.dispatchReady()
        client.screens = [ApprovalFixtures.bashUnsandboxed]

        await state.background.handle(event(.working))
        XCTAssertEqual(status(state, task), .running)
        await state.background.handle(event(.blocked))
        XCTAssertEqual(status(state, task), .blocked)
        XCTAssertEqual(state.background.approvals.count, 1)
        let approval = state.background.approvals[0]
        XCTAssertEqual(approval.taskID, task.id)
        XCTAssertEqual(approval.paneID, pane)
        XCTAssertEqual(approval.title, "Bash command (unsandboxed)")

        await state.background.handle(event(.working))
        XCTAssertEqual(status(state, task), .running)
        XCTAssertTrue(state.background.approvals.isEmpty, "answered in the pane: the approval goes")

        await state.background.handle(event(.done))
        XCTAssertEqual(status(state, task), .review, "seen working, so idle or done is finished at once")
    }

    func testOtherAgentsProduceNoApprovals() async {
        let state = makeState()
        client.screens = [ApprovalFixtures.bashAskRule]
        let unsent = addBackground(state, assignee: AgentRef(paneID: "w6:p1", workspaceID: "w6", sessionID: nil, label: "x"))
        await state.background.handle(event(.blocked, pane: "w6:p1"))
        await state.background.handle(event(.blocked, pane: "w8:p1"))
        XCTAssertTrue(state.background.approvals.isEmpty)
        XCTAssertEqual(client.reads, 0, "panes without a sent task are not even read")
        XCTAssertEqual(status(state, unsent), .waiting)
    }

    func testReconcileAfterRelaunchCatchesMissedEvents() async {
        let state = makeState()
        let task = addBackground(state, assignee: agent)
        await state.background.dispatchReady()
        now = now.addingTimeInterval(600)
        client.agentsResult = [herdrAgent(pane, .idle)]
        let relaunched = makeState()
        await relaunched.background.refreshAgents()
        XCTAssertEqual(status(relaunched, task), .review, "it finished while the app was closed")

        let other = addBackground(relaunched, title: "Other", assignee: AgentRef(paneID: "w7:p1", workspaceID: "w7", sessionID: nil, label: "y"))
        relaunched.updateBackground(id: other.id) {
            $0.status = .running
            $0.sentAt = self.now
        }
        await relaunched.background.refreshAgents()
        XCTAssertEqual(status(relaunched, other), .paneClosed)
    }

    func testReportPutsTheTaskInReview() {
        let state = makeState()
        let task = addBackground(state, assignee: agent)
        XCTAssertTrue(state.reportBackground(id: task.id, summary: " Fixed it \n", link: "  https://github.com/o/r/pull/9 "))
        XCTAssertEqual(info(state, task)?.status, .review)
        XCTAssertEqual(info(state, task)?.summary, "Fixed it")
        XCTAssertEqual(info(state, task)?.link, "https://github.com/o/r/pull/9")
        let plain = state.addTask(title: "Plain", durationSeconds: 60, presetID: nil, overrides: [])
        XCTAssertFalse(state.reportBackground(id: plain.id, summary: "x", link: nil))
    }

    func testAnEditCannotRollTheRunStateBack() async {
        let state = makeState()
        let task = addBackground(state, assignee: agent)
        let staleCopy = state.tasks.first { $0.id == task.id }!
        await state.background.dispatchReady()
        var edited = staleCopy
        edited.title = "Renamed"
        state.updateTask(edited)
        XCTAssertEqual(status(state, task), .running)
        XCTAssertNotNil(info(state, task)?.sentAt)
    }

    // MARK: Answers

    private func blockedApproval(screens: [String]) async -> (AppState, TaskItem, PendingApproval) {
        let state = makeState()
        let task = addBackground(state, assignee: agent)
        await state.background.dispatchReady()
        client.screens = screens
        client.agentsResult = [herdrAgent(pane, .blocked)]
        await state.background.handle(event(.blocked))
        return (state, task, state.background.approvals[0])
    }

    func testAnswerMovesTheCursorAndSelects() async {
        let (state, task, approval) = await blockedApproval(screens: [
            ApprovalFixtures.bashUnsandboxed, ApprovalFixtures.bashUnsandboxed, "⏺ Running echo spike-three",
        ])
        let result = await state.background.answer(approvalID: approval.id, option: 3)
        XCTAssertEqual(result, .answered)
        XCTAssertEqual(client.sentKeys.map(\.keys), [["Down", "Down", "Enter"]])
        XCTAssertEqual(client.sentKeys.first?.pane, pane)
        XCTAssertTrue(state.background.approvals.isEmpty)
        XCTAssertEqual(status(state, task), .running)
    }

    func testAnswerRefusesWhenThePromptChanged() async {
        let (state, _, approval) = await blockedApproval(screens: [ApprovalFixtures.bashUnsandboxed, ApprovalFixtures.bashAskRule])
        let result = await state.background.answer(approvalID: approval.id, option: 1)
        guard case .refused = result else { return XCTFail("expected a refusal, got \(result)") }
        XCTAssertTrue(client.sentKeys.isEmpty, "no keys for a prompt the user did not see")
        XCTAssertTrue(state.background.approvals.isEmpty, "the stale approval is dropped")
    }

    func testAnswerRefusesWhenThePaneIsNoLongerBlocked() async {
        let (state, _, approval) = await blockedApproval(screens: [ApprovalFixtures.bashUnsandboxed])
        client.agentsResult = [herdrAgent(pane, .working)]
        let result = await state.background.answer(approvalID: approval.id, option: 1)
        guard case .refused = result else { return XCTFail("expected a refusal, got \(result)") }
        XCTAssertTrue(client.sentKeys.isEmpty)
        XCTAssertTrue(state.background.approvals.isEmpty)
    }

    func testAnswerReportsAPromptThatStaysUp() async {
        let (state, _, approval) = await blockedApproval(screens: [ApprovalFixtures.bashUnsandboxed])
        let result = await state.background.answer(approvalID: approval.id, option: 1)
        XCTAssertEqual(result, .stillShowing)
        XCTAssertEqual(client.sentKeys.map(\.keys), [["Enter"]])
        XCTAssertEqual(state.background.approvals.count, 1, "kept, so the UI can offer to open the pane")
    }

    func testAPromptRightAfterTheAnswerBecomesTheNextApproval() async {
        let (state, task, approval) = await blockedApproval(screens: [
            ApprovalFixtures.bashUnsandboxed, ApprovalFixtures.bashUnsandboxed, ApprovalFixtures.bashAskRule,
        ])
        let result = await state.background.answer(approvalID: approval.id, option: 1)
        XCTAssertEqual(result, .answered)
        XCTAssertEqual(state.background.approvals.map(\.title), ["Bash command"], "herdr may not report blocked to blocked")
        XCTAssertNotEqual(state.background.approvals.first?.id, approval.id)
        XCTAssertEqual(status(state, task), .blocked)
    }

    func testAPaneLosingItsAgentIsChecked() async {
        let state = makeState()
        let task = addBackground(state, assignee: agent)
        await state.background.dispatchReady()
        client.agentsResult = []
        await state.background.handle(.agentStatusChanged(paneID: pane, status: nil))
        XCTAssertEqual(status(state, task), .paneClosed)
    }

    func testTheWorkspaceLockAndBackgroundSubscribeSeparately() async {
        let state = makeState()
        addBackground(state, assignee: agent)
        let guardian = HerdrWorkspaceGuard(client: client, taskTitle: { "x" })
        guardian.setAllowedLabels(["repo"])
        await guardian.connectOnce()
        XCTAssertEqual(client.subscriptions, [HerdrProtocol.workspaceEventKinds], "an agent kind herdr refuses cannot end the lock's stream")
        XCTAssertFalse(HerdrProtocol.workspaceEventKinds.contains("pane.agent_status_changed"))
        XCTAssertEqual(HerdrProtocol.agentEventKinds, ["pane.agent_status_changed"])
        guardian.deactivate()
    }

    func testTypedInputOptionsAreNotAnswered() async {
        let (state, _, approval) = await blockedApproval(screens: [ApprovalFixtures.askUserQuestion])
        let result = await state.background.answer(approvalID: approval.id, option: 4)
        guard case .refused = result else { return XCTFail("expected a refusal, got \(result)") }
        XCTAssertTrue(client.sentKeys.isEmpty)
    }

    // MARK: Replies from the UI

    func testARefusedAnswerStaysVisibleWithItsReason() async {
        let (state, _, approval) = await blockedApproval(screens: [ApprovalFixtures.bashUnsandboxed, ApprovalFixtures.bashAskRule])
        let replies = ApprovalReplies()
        await replies.answer(approval, option: 1, background: state.background)?.value
        XCTAssertTrue(state.background.approvals.isEmpty, "the core dropped the stale approval")
        XCTAssertEqual(replies.state(for: approval.id), .refused("the prompt on screen changed"))
        XCTAssertEqual(replies.visible(state.background.approvals).map(\.id), [approval.id], "kept on screen so the reason can be read")
    }

    func testAnAnswerInFlightIsNotSentTwice() async {
        let (state, _, approval) = await blockedApproval(screens: [
            ApprovalFixtures.bashUnsandboxed, ApprovalFixtures.bashUnsandboxed, "⏺ done",
        ])
        let replies = ApprovalReplies()
        let first = replies.answer(approval, option: 1, background: state.background)
        XCTAssertEqual(replies.state(for: approval.id), .sending)
        XCTAssertNil(replies.answer(approval, option: 1, background: state.background), "a second tap while sending does nothing")
        await first?.value
        XCTAssertEqual(replies.state(for: approval.id), .sent)
        XCTAssertEqual(client.sentKeys.count, 1)
    }

    // MARK: Open pane

    func testOpenPaneFocusesTheAgentThenTheTerminal() async {
        let state = makeState()
        var activated = 0
        state.background.activateHost = { activated += 1 }
        let opened = await state.background.openPane(pane)
        XCTAssertTrue(opened)
        XCTAssertEqual(client.focusedPanes, [pane])
        XCTAssertEqual(activated, 1)
    }

    func testOpenPaneWithoutHerdrDoesNothing() async {
        let state = makeState()
        var activated = 0
        state.background.activateHost = { activated += 1 }
        client.focusAgentError = HerdrError.server("no such pane")
        let failed = await state.background.openPane(pane)
        XCTAssertFalse(failed)
        XCTAssertEqual(activated, 0, "the terminal stays put when herdr could not focus the pane")

        client.focusAgentError = nil
        client.isAvailable = false
        let unavailable = await state.background.openPane(pane)
        XCTAssertFalse(unavailable)
        XCTAssertTrue(client.focusedPanes.isEmpty)
    }
}

// MARK: - Presentation

final class BackgroundPresentationTests: XCTestCase {
    private let assignee = AgentRef(paneID: "w5:p1", workspaceID: "w5", sessionID: nil, label: "old-name")

    private func approval(_ fixture: String, pane: String = "w5:p1") throws -> PendingApproval {
        PendingApproval(id: UUID(), paneID: pane, taskID: UUID(), prompt: try XCTUnwrap(ApprovalParser.parse(fixture)))
    }

    private func task(_ title: String, background: BackgroundInfo? = nil, doneWhen: String = "PR open") -> TaskItem {
        TaskItem(title: title, durationSeconds: 60, doneWhen: doneWhen, background: background)
    }

    func testStatusWords() {
        XCTAssertEqual(BackgroundStatus.allCases.map(BackgroundPresentation.label(for:)), [
            "Waiting", "Queued", "Running", "Needs you", "Ready for review", "Pane closed",
        ])
        let symbols = BackgroundStatus.allCases.map(BackgroundPresentation.symbol(for:))
        XCTAssertEqual(Set(symbols).count, symbols.count, "each status has its own symbol")
    }

    func testBackgroundTasksLeaveTheListsForTheirSection() {
        let plain = task("Plain")
        let agentOpen = task("Agent open", background: BackgroundInfo(assignee: assignee))
        let plainDone = task("Plain done")
        let agentDone = task("Agent done", background: BackgroundInfo(assignee: assignee, status: .review))
        let split = BackgroundPresentation.split(open: [agentOpen, plain], done: [agentDone, plainDone])
        XCTAssertEqual(split.open.map(\.title), ["Plain"])
        XCTAssertEqual(split.done.map(\.title), ["Plain done"])
        XCTAssertEqual(split.background.map(\.title), ["Agent open", "Agent done"], "open ones first, then today's checked off")
    }

    func testTheRowNamesTheAgentOrWhyItWaits() {
        let labels = ["w5": "customer-funnel"]
        XCTAssertEqual(BackgroundPresentation.assigneeLine(for: task("a", background: BackgroundInfo(assignee: assignee)), labels: labels), "customer-funnel", "the live label wins")
        XCTAssertEqual(BackgroundPresentation.assigneeLine(for: task("a", background: BackgroundInfo(assignee: assignee)), labels: [:]), "old-name")
        XCTAssertEqual(BackgroundPresentation.assigneeLine(for: task("a", background: BackgroundInfo()), labels: labels), "Unassigned")
        XCTAssertEqual(BackgroundPresentation.assigneeLine(for: task("a", background: BackgroundInfo(assignee: assignee), doneWhen: " "), labels: labels), "Not ready: add done-when")
        let sent = BackgroundInfo(assignee: assignee, status: .running, sentAt: Date())
        XCTAssertEqual(BackgroundPresentation.assigneeLine(for: task("a", background: sent, doneWhen: ""), labels: labels), "customer-funnel", "a sent task names its agent")
        XCTAssertEqual(BackgroundPresentation.assigneeLine(for: task("plain"), labels: labels), "")
    }

    func testTheEditorsReadinessHint() {
        let other = AgentRef(paneID: "w7:p1", workspaceID: "w7", sessionID: nil, label: "other")
        func hint(_ doneWhen: String, agent: AgentRef?, stored: BackgroundInfo? = nil, focus: Bool = true) -> String {
            BackgroundPresentation.readinessHint(doneWhen: doneWhen, assignee: agent, stored: stored, startsWithFocus: focus)
        }
        XCTAssertEqual(hint("PR open", agent: assignee), "Ready: starts with your next focus session")
        XCTAssertEqual(hint("  ", agent: assignee), "Needs a done-when")
        XCTAssertEqual(hint("PR open", agent: nil), "Needs an agent")
        XCTAssertEqual(hint("", agent: nil), "Needs a done-when and an agent")
        XCTAssertEqual(hint("PR open", agent: assignee, focus: false), "Ready, but starting with focus is off in Settings")
        let sent = BackgroundInfo(assignee: assignee, status: .review, sentAt: Date())
        XCTAssertEqual(hint("", agent: nil, stored: sent), "Sent to its agent · Ready for review", "a sent task is past readiness")

        // Unsent but not waiting: the dispatcher queued it or found its pane gone.
        let queued = BackgroundInfo(assignee: assignee, status: .queued)
        XCTAssertEqual(hint("PR open", agent: assignee, stored: queued), "Queued: goes out when its agent is free")
        let closed = BackgroundInfo(assignee: assignee, status: .paneClosed)
        XCTAssertEqual(hint("PR open", agent: assignee, stored: closed), "Its pane closed: pick another agent")
        XCTAssertEqual(hint("PR open", agent: other, stored: closed), "Ready: starts with your next focus session", "another agent starts it over as waiting")
        XCTAssertEqual(hint("", agent: assignee, stored: queued), "Needs a done-when")
    }

    func testTheBarShowsTheOldestApprovalAndCountsTheRest() throws {
        XCTAssertNil(BackgroundPresentation.barApproval([]))
        let first = try approval(ApprovalFixtures.bashUnsandboxed)
        let second = try approval(ApprovalFixtures.planApproval)
        let third = try approval(ApprovalFixtures.bashAskRule)
        let one = try XCTUnwrap(BackgroundPresentation.barApproval([first]))
        XCTAssertEqual(one.approval.id, first.id)
        XCTAssertEqual(one.more, 0)
        let three = try XCTUnwrap(BackgroundPresentation.barApproval([first, second, third]))
        XCTAssertEqual(three.approval.id, first.id)
        XCTAssertEqual(three.more, 2)
    }

    func testAnsweredApprovalsShowFirstUntilTheirOutcomeIsRead() throws {
        let answered = try approval(ApprovalFixtures.bashUnsandboxed)
        let waiting = try approval(ApprovalFixtures.planApproval)
        XCTAssertEqual(ApprovalReplyState.visible(live: [waiting], answered: [answered]).map(\.id), [answered.id, waiting.id])
        XCTAssertEqual(ApprovalReplyState.visible(live: [answered, waiting], answered: [answered]).map(\.id), [answered.id, waiting.id], "a live one is not listed twice")
        XCTAssertEqual(BackgroundPresentation.barApproval(ApprovalReplyState.visible(live: [waiting], answered: [answered]))?.more, 1)
    }

    func testReplyStates() {
        XCTAssertEqual(ApprovalReplyState(.answered), .sent)
        XCTAssertEqual(ApprovalReplyState(.stillShowing), .stillShowing)
        XCTAssertEqual(ApprovalReplyState(.refused("the prompt on screen changed")), .refused("the prompt on screen changed"))
        XCTAssertEqual(ApprovalReplyState.sent.message, "Sent")
        XCTAssertEqual(ApprovalReplyState.refused("herdr is not reachable").message, "Not sent: herdr is not reachable")
        XCTAssertNil(ApprovalReplyState.sending.message)
        XCTAssertFalse(ApprovalReplyState.sent.offersOpenPane)
        XCTAssertTrue(ApprovalReplyState.stillShowing.offersOpenPane)
        XCTAssertTrue(ApprovalReplyState.refused("x").offersOpenPane)
        XCTAssertNil(ApprovalReplyState.sending.linger, "nothing to clear while sending")
    }

    func testSourceLineAndExcerpt() throws {
        let bash = try approval(ApprovalFixtures.bashUnsandboxed)
        XCTAssertEqual(BackgroundPresentation.sourceLine(for: bash, assignee: assignee, labels: ["w5": "customer-funnel"]), "customer-funnel · Bash command (unsandboxed)")
        XCTAssertEqual(BackgroundPresentation.sourceLine(for: bash, assignee: nil, labels: ["w5": "customer-funnel"]), "customer-funnel · Bash command (unsandboxed)", "the pane id names the workspace")
        XCTAssertEqual(BackgroundPresentation.sourceLine(for: bash, assignee: nil, labels: [:]), "w5 · Bash command (unsandboxed)")
        XCTAssertEqual(BackgroundPresentation.excerpt(for: bash), "Do you want to proceed? · echo spike-three", "the command, not the tip above it")
        XCTAssertEqual(BackgroundPresentation.bodyExcerpt(for: bash), ["Print spike-three", "echo spike-three"])

        let askRule = try approval(ApprovalFixtures.bashAskRule)
        XCTAssertEqual(BackgroundPresentation.excerpt(for: askRule), "Do you want to proceed? · echo spike-two", "the command, not the notes after it")
        XCTAssertEqual(BackgroundPresentation.bodyExcerpt(for: askRule), [
            "Echo spike-two", "echo spike-two", "Ask rule Bash(echo spike*) overrides auto mode for this command.",
        ])

        let question = try approval(ApprovalFixtures.askUserQuestion)
        XCTAssertEqual(BackgroundPresentation.excerpt(for: question), "What should the plan cover when you say \"plan a file\"?")

        let plan = try approval(ApprovalFixtures.planApproval)
        XCTAssertEqual(BackgroundPresentation.excerpt(for: plan), "Claude has written up a plan and is ready to execute. Would you like to proceed?", "no plan line passes for a command")
        XCTAssertEqual(BackgroundPresentation.bodyExcerpt(for: plan).count, 3)
    }

    func testOpenPaneWaitsForTheBreak() {
        XCTAssertTrue(BackgroundPresentation.canOpenPane(during: .idle))
        XCTAssertTrue(BackgroundPresentation.canOpenPane(during: .breakTime))
        XCTAssertFalse(BackgroundPresentation.canOpenPane(during: .work), "the workspace lock would bounce straight back")
        XCTAssertFalse(BackgroundPresentation.canOpenPane(during: .paused))
        XCTAssertEqual(BackgroundPresentation.openPaneLaterHelp, "Available at the break")
    }

    func testARowClickOpensThePaneOutsideFocus() {
        XCTAssertEqual(BackgroundPresentation.rowClick(hasPane: true, phase: .idle), .openPane)
        XCTAssertEqual(BackgroundPresentation.rowClick(hasPane: true, phase: .breakTime), .openPane)
        XCTAssertEqual(BackgroundPresentation.rowClick(hasPane: true, phase: .work), .later)
        XCTAssertEqual(BackgroundPresentation.rowClick(hasPane: true, phase: .paused), .later)
        XCTAssertEqual(BackgroundPresentation.rowClick(hasPane: false, phase: .idle), .none, "an unassigned task has nowhere to go")
    }

    func testAgentsGroupByWorkspaceLabel() {
        func agent(_ pane: String, _ workspace: String) -> HerdrAgent {
            HerdrAgent(paneID: pane, workspaceID: workspace, cwd: nil, agent: "claude", status: .idle, focused: false, sessionID: nil)
        }
        let groups = BackgroundPresentation.agentGroups(
            [agent("w2:p1", "w2"), agent("w1:p1", "w1"), agent("w2:p2", "w2"), agent("w9:p1", "w9")],
            labels: ["w1": "zeta", "w2": "Alpha"]
        )
        XCTAssertEqual(groups.map(\.label), ["Alpha", "w9", "zeta"], "by label, case-insensitive; an unlabelled workspace by its id")
        XCTAssertEqual(groups.first?.agents.map(\.paneID), ["w2:p1", "w2:p2"])
        XCTAssertEqual(BackgroundPresentation.agentTitle(agent("w2:p1", "w2")), "claude · idle · w2:p1")
    }

    func testMenuBarTooltip() {
        XCTAssertEqual(BackgroundPresentation.waitingText(1), "1 background request waiting")
        XCTAssertEqual(BackgroundPresentation.waitingText(3), "3 background requests waiting")
    }
}

// MARK: - Control API and MCP

@MainActor
final class BackgroundControlTests: XCTestCase {
    private var url: URL!
    private var now = Date(timeIntervalSince1970: 1_752_000_000)
    private var model: AppState!
    private var api: ControlAPI!
    private var client: FakeHerdrClient!

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TunnelVisionBackgroundControl-\(UUID().uuidString)")
            .appendingPathComponent("data.json")
        model = AppState(fileURL: url, clock: { [weak self] in self?.now ?? Date() }, autoTick: false)
        var quiet = model.settings
        quiet.soundOn = false
        model.updateSettings(quiet)
        client = FakeHerdrClient()
        client.snapshotResult = HerdrSnapshot(focusedWorkspaceID: "w5", workspaces: [
            HerdrWorkspace(id: "w5", label: "tunnel-vision", repoName: nil, checkoutPath: nil, focused: true),
            HerdrWorkspace(id: "w6", label: "easy-review", repoName: nil, checkoutPath: nil, focused: false),
        ])
        client.agentsResult = [
            HerdrAgent(paneID: "w5:p1", workspaceID: "w5", cwd: "/tv", agent: "claude", status: .working, focused: true, sessionID: "sess-5"),
            HerdrAgent(paneID: "w6:p2", workspaceID: "w6", cwd: "/er", agent: "claude", status: .idle, focused: false, sessionID: "sess-6"),
        ]
        model.background.settleDelay = .zero
        model.background.attach(client: client, watch: false)
        api = ControlAPI(model: model)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        try await api.respond(method: method, params: params)
    }

    private func background(_ result: [String: Any]) -> [String: Any] {
        (result["task"] as? [String: Any])?["background"] as? [String: Any] ?? [:]
    }

    func testABackgroundTaskGoesToTheCallingPane() async throws {
        let result = try await call("tasks.add", [
            "title": "Fix the flaky test", "done_when": "CI green", "background": true,
            "caller_pane": "w5:p1", "caller_workspace": "w5",
        ])
        let json = background(result)
        let assignee = json["assignee"] as? [String: Any]
        XCTAssertEqual(assignee?["pane_id"] as? String, "w5:p1")
        XCTAssertEqual(assignee?["label"] as? String, "tunnel-vision", "the label comes from herdr's snapshot")
        XCTAssertEqual(assignee?["session_id"] as? String, "sess-5", "the session id from herdr's agent list")
        XCTAssertEqual(json["status"] as? String, "waiting")
        XCTAssertEqual(json["ready"] as? Bool, true)
        XCTAssertTrue(json["sent_at"] is NSNull)
    }

    func testAssignToPicksAPaneOrAWorkspaceLabel() async throws {
        let byLabel = background(try await call("tasks.add", ["title": "A", "background": true, "assign_to": "Easy-Review", "caller_pane": "w5:p1"]))
        XCTAssertEqual((byLabel["assignee"] as? [String: Any])?["pane_id"] as? String, "w6:p2", "assign_to wins over the caller")
        let byPane = background(try await call("tasks.add", ["title": "B", "assign_to": "w5:p1"]))
        XCTAssertEqual((byPane["assignee"] as? [String: Any])?["pane_id"] as? String, "w5:p1", "assign_to alone makes it background")
        do {
            _ = try await call("tasks.add", ["title": "C", "background": true, "assign_to": "nowhere"])
            XCTFail("an unknown agent is refused")
        } catch let error as ControlError {
            guard case .notFound = error else { return XCTFail("\(error)") }
        }
    }

    func testNoCallerAndNoAssignToLeavesItUnassigned() async throws {
        let json = background(try await call("tasks.add", ["title": "A", "done_when": "x", "background": true]))
        XCTAssertTrue(json["assignee"] is NSNull)
        XCTAssertEqual(json["ready"] as? Bool, false)
        let plain = try await call("tasks.add", ["title": "Plain", "caller_pane": "w5:p1"])
        XCTAssertTrue((plain["task"] as? [String: Any])?["background"] is NSNull, "the caller pane alone does not make a task background")
    }

    func testUpdateTurnsBackgroundOnAndOffAndReassigns() async throws {
        let id = (try await call("tasks.add", ["title": "A", "done_when": "x"])["task"] as? [String: Any])?["id"] as! String
        var json = background(try await call("tasks.update", ["id": id, "background": true, "caller_pane": "w5:p1"]))
        XCTAssertEqual((json["assignee"] as? [String: Any])?["pane_id"] as? String, "w5:p1")
        json = background(try await call("tasks.update", ["id": id, "assign_to": "w6:p2"]))
        XCTAssertEqual((json["assignee"] as? [String: Any])?["pane_id"] as? String, "w6:p2")

        let task = model.tasks.first { $0.id.uuidString == id }!
        model.updateBackground(id: task.id) { $0.sentAt = self.now; $0.status = .running }
        do {
            _ = try await call("tasks.update", ["id": id, "assign_to": "w5:p1"])
            XCTFail("a sent task keeps its agent")
        } catch let error as ControlError {
            guard case .refused = error else { return XCTFail("\(error)") }
        }
        let off = try await call("tasks.update", ["id": id, "background": false])
        XCTAssertTrue((off["task"] as? [String: Any])?["background"] is NSNull)
    }

    func testSessionStartRefusesABackgroundTask() async throws {
        let id = (try await call("tasks.add", ["title": "A", "assign_to": "w6:p2"])["task"] as? [String: Any])?["id"] as! String
        do {
            _ = try await call("session.start", ["id": id])
            XCTFail("a background task never starts on the timer")
        } catch let error as ControlError {
            guard case .refused = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(model.phase, .idle)
    }

    func testReportListAgentsAndApprovals() async throws {
        let id = (try await call("tasks.add", ["title": "A", "done_when": "x", "assign_to": "w6:p2"])["task"] as? [String: Any])?["id"] as! String
        let agents = try await call("agents.list")
        let list = agents["agents"] as? [[String: Any]] ?? []
        XCTAssertEqual(list.map { $0["pane_id"] as? String }, ["w5:p1", "w6:p2"])
        XCTAssertEqual(list.first?["label"] as? String, "tunnel-vision")
        XCTAssertEqual(list.first?["status"] as? String, "working")
        XCTAssertEqual(agents["herdr_reachable"] as? Bool, true)

        // Sent to the idle pane, then it asks something.
        await model.background.dispatchReady()
        client.screens = [ApprovalFixtures.bashAskRule]
        client.agentsResult[1] = HerdrAgent(paneID: "w6:p2", workspaceID: "w6", cwd: "/er", agent: "claude", status: .blocked, focused: false, sessionID: "sess-6")
        await model.background.handle(.agentStatusChanged(paneID: "w6:p2", status: .working))
        await model.background.handle(.agentStatusChanged(paneID: "w6:p2", status: .blocked))
        let approvals = try await call("approvals.list")["approvals"] as? [[String: Any]] ?? []
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals.first?["task_id"] as? String, id)
        XCTAssertEqual(approvals.first?["title"] as? String, "Bash command")
        XCTAssertEqual((approvals.first?["options"] as? [[String: Any]])?.map { $0["label"] as? String }, ["Yes", "No"])
        XCTAssertEqual(approvals.first?["cursor"] as? Int, 1)

        client.screens = [ApprovalFixtures.bashAskRule, ApprovalFixtures.bashAskRule, "done"]
        client.reads = 1
        let answered = try await call("approvals.answer", ["id": approvals.first?["id"] as! String, "option": 2])
        XCTAssertEqual(answered["answered"] as? Bool, true)
        XCTAssertEqual(client.sentKeys.map(\.keys), [["Down", "Enter"]])

        let reported = background(try await call("background.report", ["id": id, "summary": "Fixed", "link": "https://x/pr/1"]))
        XCTAssertEqual(reported["status"] as? String, "review")
        XCTAssertEqual(reported["summary"] as? String, "Fixed")
        XCTAssertEqual(reported["link"] as? String, "https://x/pr/1")
    }

    func testTheMCPHelperAddsItsPaneToTaskCalls() {
        let env = ["HERDR_PANE_ID": "w5:p1", "HERDR_WORKSPACE_ID": "w5", "HOME": "/x"]
        let added = ControlTools.addingCaller(to: ["title": "A"], method: "tasks.add", environment: env)
        XCTAssertEqual(added["caller_pane"] as? String, "w5:p1")
        XCTAssertEqual(added["caller_workspace"] as? String, "w5")
        XCTAssertEqual(added["title"] as? String, "A")
        XCTAssertNotNil(ControlTools.addingCaller(to: [:], method: "tasks.update", environment: env)["caller_pane"])
        XCTAssertNil(ControlTools.addingCaller(to: [:], method: "tasks.list", environment: env)["caller_pane"], "only adds and updates carry it")
        XCTAssertNil(ControlTools.addingCaller(to: [:], method: "tasks.add", environment: ["HOME": "/x"])["caller_pane"], "outside herdr there is no pane")
    }

    func testNewToolsRoute() {
        XCTAssertEqual(ControlTools.route(tool: "tunnelvision_list_agents", arguments: [:])?.method, "agents.list")
        XCTAssertEqual(ControlTools.route(tool: "tunnelvision_report_background", arguments: ["id": "x"])?.method, "background.report")
        XCTAssertEqual(ControlTools.route(tool: "tunnelvision_list_approvals", arguments: [:])?.method, "approvals.list")
        let answer = ControlTools.route(tool: "tunnelvision_answer_approval", arguments: ["id": "a", "option": 2])
        XCTAssertEqual(answer?.method, "approvals.answer")
        XCTAssertEqual(answer?.params["option"] as? Int, 2)
        let names = Set(ControlTools.all.map(\.name))
        for name in ["tunnelvision_list_agents", "tunnelvision_report_background", "tunnelvision_list_approvals", "tunnelvision_answer_approval"] {
            XCTAssertTrue(names.contains(name), name)
        }
        let addTask = ControlTools.all.first { $0.name == "tunnelvision_add_task" }
        let properties = addTask?.inputSchema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["background"])
        XCTAssertNotNil(properties?["assign_to"])
    }
}
