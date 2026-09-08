import Foundation
import XCTest

@testable import TunnelVision

// MARK: - Wire format

final class HerdrProtocolTests: XCTestCase {
    func testRequestIsOneJSONLine() throws {
        let data = HerdrProtocol.request(id: "r1", method: "workspace.focus", params: ["workspace_id": "w1"])
        XCTAssertEqual(data.last, 0x0A, "newline-delimited")
        let object = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any]
        XCTAssertEqual(object?["id"] as? String, "r1")
        XCTAssertEqual(object?["method"] as? String, "workspace.focus")
        XCTAssertEqual((object?["params"] as? [String: Any])?["workspace_id"] as? String, "w1")
    }

    func testParsesSessionSnapshot() throws {
        let line = Data("""
        {"id":"cli:api:snapshot","result":{"snapshot":{"focused_workspace_id":"w35","focused_tab_id":"w35:t2","workspaces":[
        {"workspace_id":"w1","label":"discovery","focused":false,"worktree":{"repo_name":"discovery","checkout_path":"/Users/me/Projects/discovery"}},
        {"workspace_id":"w35","label":"ai-tooling","focused":true,"worktree":{"repo_name":"discovery","checkout_path":"/Users/me/.herdr/worktrees/discovery/ai-tooling"}},
        {"workspace_id":"w9","label":"scratch","focused":false}
        ]}}}
        """.utf8)
        let snapshot = try HerdrProtocol.parseSnapshot(line)
        XCTAssertEqual(snapshot.focusedWorkspaceID, "w35")
        XCTAssertEqual(snapshot.workspaces.map(\.id), ["w1", "w35", "w9"])
        XCTAssertEqual(snapshot.workspaces[1].label, "ai-tooling")
        XCTAssertEqual(snapshot.workspaces[1].repoName, "discovery")
        XCTAssertTrue(snapshot.workspaces[1].focused)
        XCTAssertNil(snapshot.workspaces[2].repoName, "workspaces outside a repo have no worktree block")
    }

    func testParsesPushedEvents() {
        let focused = Data(#"{"event":"workspace_focused","data":{"type":"workspace_focused","workspace_id":"w35"}}"#.utf8)
        XCTAssertEqual(HerdrProtocol.parseEvent(focused), .workspaceFocused(id: "w35"))

        let dotted = Data(#"{"event":"workspace.focused","data":{"workspace_id":"w1"}}"#.utf8)
        XCTAssertEqual(HerdrProtocol.parseEvent(dotted), .workspaceFocused(id: "w1"), "dotted kinds are accepted too")

        let renamed = Data(#"{"event":"workspace_renamed","data":{"type":"workspace_renamed","workspace_id":"w1","label":"Anchor"}}"#.utf8)
        XCTAssertEqual(HerdrProtocol.parseEvent(renamed), .workspaceRenamed(id: "w1", label: "Anchor"))

        let closed = Data(#"{"event":"workspace_closed","data":{"type":"workspace_closed","workspace_id":"w1"}}"#.utf8)
        XCTAssertEqual(HerdrProtocol.parseEvent(closed), .workspaceClosed(id: "w1"))

        let created = Data(#"{"event":"workspace_created","data":{"type":"workspace_created","workspace":{"workspace_id":"w7","label":"new"}}}"#.utf8)
        XCTAssertEqual(
            HerdrProtocol.parseEvent(created),
            .workspaceCreated(HerdrWorkspace(id: "w7", label: "new", repoName: nil, checkoutPath: nil, focused: false))
        )

        let unrelated = Data(#"{"event":"tab_focused","data":{"type":"tab_focused","tab_id":"w1:t1"}}"#.utf8)
        XCTAssertEqual(HerdrProtocol.parseEvent(unrelated), .other)

        let ack = Data(#"{"id":"anchor-events","result":{"type":"subscription_started"}}"#.utf8)
        XCTAssertNil(HerdrProtocol.parseEvent(ack), "responses are not events")
    }

    func testErrorLinesAreRecognised() {
        let error = Data(#"{"id":"x","error":{"code":"workspace_not_found","message":"no such workspace"}}"#.utf8)
        XCTAssertEqual(HerdrProtocol.errorMessage(in: error), "no such workspace")
        let ok = Data(#"{"id":"x","result":{"type":"pong"}}"#.utf8)
        XCTAssertNil(HerdrProtocol.errorMessage(in: ok))
    }
}

// MARK: - Guard

@MainActor
final class FakeHerdrClient: HerdrControlling {
    var isAvailable = true
    var snapshotResult = HerdrSnapshot(focusedWorkspaceID: nil, workspaces: [])
    var focused: [String] = []
    var notices: [String] = []
    var focusError: Error?

    func snapshot() async throws -> HerdrSnapshot { snapshotResult }

    func focusWorkspace(id: String) async throws {
        if let focusError { throw focusError }
        focused.append(id)
    }

    func notify(title: String, body: String?) async {
        notices.append(title)
    }

    func events() -> AsyncStream<HerdrEvent> {
        AsyncStream { $0.finish() }
    }
}

@MainActor
final class HerdrWorkspaceGuardTests: XCTestCase {
    private let anchor = HerdrWorkspace(id: "w1", label: "promodoro-cop", repoName: nil, checkoutPath: nil, focused: false)
    private let review = HerdrWorkspace(id: "w2", label: "easy-review", repoName: nil, checkoutPath: nil, focused: false)
    private let other = HerdrWorkspace(id: "w9", label: "discovery", repoName: nil, checkoutPath: nil, focused: false)

    private func makeGuard(labels: Set<String>, focused: String?) -> (HerdrWorkspaceGuard, FakeHerdrClient) {
        let client = FakeHerdrClient()
        client.snapshotResult = HerdrSnapshot(focusedWorkspaceID: focused, workspaces: [anchor, review, other])
        let guardian = HerdrWorkspaceGuard(client: client, taskTitle: { "Ship it" })
        guardian.setAllowedLabels(labels)
        return (guardian, client)
    }

    func testAllowedLabelsComeOnlyFromHerdrAllowRules() {
        let rules = [
            Rule(bundleID: "com.mitchellh.ghostty"),
            Rule(bundleID: "com.mitchellh.ghostty", scope: .herdr, pattern: " Promodoro-Cop "),
            Rule(bundleID: "", scope: .herdr, pattern: "easy-review"),
            Rule(bundleID: "", scope: .herdr, pattern: "denied", effect: .deny),
            Rule(bundleID: "x", scope: .window, pattern: "not herdr"),
        ]
        XCTAssertEqual(HerdrWorkspaceGuard.allowedLabels(in: rules), ["promodoro-cop", "easy-review"])
    }

    func testBootstrapBouncesWhenFocusedWorkspaceIsNotAllowed() async throws {
        let (guardian, client) = makeGuard(labels: ["promodoro-cop"], focused: "w9")
        try await guardian.bootstrap()
        XCTAssertEqual(client.focused, ["w1"], "no return target yet: the first allowed workspace wins")
        XCTAssertEqual(client.notices.count, 1)
    }

    func testBootstrapLeavesAnAllowedWorkspaceAlone() async throws {
        let (guardian, client) = makeGuard(labels: ["promodoro-cop"], focused: "w1")
        try await guardian.bootstrap()
        XCTAssertTrue(client.focused.isEmpty)
        XCTAssertEqual(guardian.returnTarget, "w1")
    }

    func testBounceReturnsToTheLastAllowedWorkspace() async throws {
        let (guardian, client) = makeGuard(labels: ["promodoro-cop", "easy-review"], focused: "w1")
        try await guardian.bootstrap()
        await guardian.handle(.workspaceFocused(id: "w2"))
        XCTAssertEqual(guardian.returnTarget, "w2")
        await guardian.handle(.workspaceFocused(id: "w9"))
        XCTAssertEqual(client.focused, ["w2"], "multi-select: bounce to where the user last was, not the first pick")
    }

    func testLabelsMatchCaseInsensitively() async throws {
        let (guardian, _) = makeGuard(labels: ["PROMODORO-COP"], focused: nil)
        try await guardian.bootstrap()
        XCTAssertTrue(guardian.isAllowed("w1"))
        XCTAssertFalse(guardian.isAllowed("w9"))
    }

    func testRenameMovesAWorkspaceOutOfTheAllowedSet() async throws {
        let (guardian, client) = makeGuard(labels: ["promodoro-cop", "easy-review"], focused: "w1")
        try await guardian.bootstrap()
        await guardian.handle(.workspaceRenamed(id: "w1", label: "something-else"))
        XCTAssertFalse(guardian.isAllowed("w1"))
        XCTAssertNil(guardian.returnTarget, "a renamed-away return target is dropped")
        await guardian.handle(.workspaceFocused(id: "w1"))
        XCTAssertEqual(client.focused, ["w2"], "falls back to the remaining allowed workspace")
    }

    func testClosedReturnTargetFallsBackToAnotherAllowedWorkspace() async throws {
        let (guardian, client) = makeGuard(labels: ["promodoro-cop", "easy-review"], focused: "w2")
        try await guardian.bootstrap()
        await guardian.handle(.workspaceClosed(id: "w2"))
        await guardian.handle(.workspaceFocused(id: "w9"))
        XCTAssertEqual(client.focused, ["w1"])
    }

    func testNothingToBounceToWhenNoAllowedWorkspaceIsOpen() async throws {
        let (guardian, client) = makeGuard(labels: ["not-open"], focused: "w9")
        try await guardian.bootstrap()
        XCTAssertTrue(client.focused.isEmpty)
        XCTAssertTrue(client.notices.isEmpty)
    }

    func testCreatedWorkspaceBecomesAllowedWhenItsLabelMatches() async throws {
        let (guardian, client) = makeGuard(labels: ["fresh"], focused: "w9")
        try await guardian.bootstrap()
        XCTAssertTrue(client.focused.isEmpty)
        await guardian.handle(.workspaceCreated(HerdrWorkspace(id: "w7", label: "Fresh", repoName: nil, checkoutPath: nil, focused: false)))
        await guardian.handle(.workspaceFocused(id: "w9"))
        XCTAssertEqual(client.focused, ["w7"])
    }

    func testNoticesAreThrottled() async throws {
        let (guardian, client) = makeGuard(labels: ["promodoro-cop"], focused: "w1")
        try await guardian.bootstrap()
        await guardian.handle(.workspaceFocused(id: "w9"))
        await guardian.handle(.workspaceFocused(id: "w9"))
        XCTAssertEqual(client.focused, ["w1", "w1"], "every switch bounces")
        XCTAssertEqual(client.notices.count, 1, "but the toast is not repeated within a few seconds")
    }

    func testFocusFailureDoesNotToast() async throws {
        let (guardian, client) = makeGuard(labels: ["promodoro-cop"], focused: "w1")
        try await guardian.bootstrap()
        client.focusError = HerdrError.disconnected
        await guardian.handle(.workspaceFocused(id: "w9"))
        XCTAssertTrue(client.notices.isEmpty)
    }

    func testLockWithoutHerdrRulesStaysInactive() {
        let (guardian, _) = makeGuard(labels: [], focused: nil)
        guardian.lockStateChanged(active: true, rules: [Rule(bundleID: "com.apple.dt.Xcode")], mode: .dark)
        XCTAssertFalse(guardian.isActive)
        guardian.lockStateChanged(active: true, rules: [Rule(bundleID: "", scope: .herdr, pattern: "promodoro-cop")], mode: .dark)
        XCTAssertTrue(guardian.isActive)
        XCTAssertEqual(guardian.allowedLabels, ["promodoro-cop"])
        guardian.lockStateChanged(active: false, rules: [], mode: .dark)
        XCTAssertFalse(guardian.isActive)
        XCTAssertTrue(guardian.allowedLabels.isEmpty)
    }

    func testMissingSocketKeepsTheGuardInactive() {
        let (guardian, client) = makeGuard(labels: [], focused: nil)
        client.isAvailable = false
        guardian.lockStateChanged(active: true, rules: [Rule(bundleID: "", scope: .herdr, pattern: "promodoro-cop")], mode: .dark)
        XCTAssertFalse(guardian.isActive, "no herdr, no herdr lock — the app-level lock still holds")
    }
}

// MARK: - Picks → rules

final class HerdrSelectionTests: XCTestCase {
    private let ghostty = "com.mitchellh.ghostty"

    func testHerdrPicksBecomeRulesCarryingTheHostTerminal() {
        let rules = SelectionBuilder.rules(
            wholeAppBundles: [],
            windows: [],
            herdr: [
                PickedHerdrRef(hostBundleID: ghostty, label: "promodoro-cop"),
                PickedHerdrRef(hostBundleID: ghostty, label: "easy-review"),
            ]
        )
        XCTAssertEqual(rules.count, 2)
        XCTAssertTrue(rules.allSatisfy { $0.scope == .herdr && $0.bundleID == ghostty && $0.isComplete })
        XCTAssertEqual(rules.map(\.pattern), ["easy-review", "promodoro-cop"])
        XCTAssertEqual(LockPolicy.allowedBundleIDs(rules: rules), [ghostty], "the terminal stays open through its herdr rules")
    }

    func testHerdrPicksSurviveAWholeAppPickOfTheTerminal() {
        let rules = SelectionBuilder.rules(
            wholeAppBundles: [ghostty],
            windows: [],
            herdr: [PickedHerdrRef(hostBundleID: ghostty, label: "promodoro-cop")]
        )
        XCTAssertEqual(rules.map(\.scope), [.app, .herdr], "unlike windows, a herdr pick narrows even a whole-app pick")
    }

    func testHerdrRuleWithoutHostIsStillComplete() {
        let rule = Rule(bundleID: "", scope: .herdr, pattern: "promodoro-cop")
        XCTAssertTrue(rule.isComplete)
        XCTAssertTrue(LockPolicy.allowedBundleIDs(rules: [rule]).isEmpty)
        XCTAssertEqual(rule.summary, "herdr · “promodoro-cop”")
        XCTAssertFalse(Rule(bundleID: "", scope: .herdr, pattern: "  ").isComplete)
    }

    func testSeedMarksHerdrLabels() {
        let seed = SelectionBuilder.seed(
            apps: [],
            rules: [
                Rule(bundleID: ghostty, scope: .herdr, pattern: "Promodoro-Cop"),
                Rule(bundleID: ghostty, scope: .herdr, pattern: "easy-review", effect: .deny),
            ]
        )
        XCTAssertEqual(seed.herdrLabels, ["promodoro-cop"])
        XCTAssertTrue(seed.wholeAppBundles.isEmpty, "a herdr rule does not make the terminal a whole-app pick")
    }

    @MainActor
    func testOverlayModelMultiSelectsWorkspacesAndCountsTheHost() {
        let terminal = PickerAppInfo(id: ghostty, pid: 5, name: "Ghostty", bundleID: ghostty, icon: nil, windows: [])
        let model = PickerOverlayModel(apps: [terminal], wholeAppBundles: [], windowIDs: [], mode: .dark, allowsPresetSave: true)
        let anchor = HerdrWorkspace(id: "w1", label: "promodoro-cop", repoName: nil, checkoutPath: nil, focused: true)
        let review = HerdrWorkspace(id: "w2", label: "easy-review", repoName: "easy-review", checkoutPath: nil, focused: false)
        model.herdr = PickerHerdrInfo(hostBundleID: ghostty, workspaces: [anchor, review])

        XCTAssertTrue(model.nothingPicked)
        model.toggleHerdr(anchor)
        model.toggleHerdr(review)
        XCTAssertTrue(model.isPicked(anchor) && model.isPicked(review))
        XCTAssertEqual(model.summary.herdrCount, 2)
        XCTAssertEqual(model.summary.appCount, 1, "the host terminal counts as allowed")
        XCTAssertEqual(model.herdrWorkspaces(hostedBy: terminal).count, 2)
        XCTAssertNil(model.standaloneHerdr, "hosted workspaces render under the terminal, not on their own")

        model.toggleHerdr(review)
        XCTAssertFalse(model.isPicked(review))
        let rules = model.rules()
        XCTAssertEqual(rules.map(\.scope), [.herdr])
        XCTAssertEqual(rules.first?.pattern, "promodoro-cop")
        XCTAssertEqual(rules.first?.bundleID, ghostty)
    }

    @MainActor
    func testUnknownHostGetsAStandaloneSection() {
        let model = PickerOverlayModel(apps: [], wholeAppBundles: [], windowIDs: [], mode: .dark, allowsPresetSave: true)
        let anchor = HerdrWorkspace(id: "w1", label: "promodoro-cop", repoName: nil, checkoutPath: nil, focused: true)
        model.herdr = PickerHerdrInfo(hostBundleID: nil, workspaces: [anchor])
        XCTAssertNotNil(model.standaloneHerdr)
        model.toggleHerdr(anchor)
        XCTAssertEqual(model.summary.appCount, 0, "no host to admit")
        XCTAssertEqual(model.rules().first?.bundleID, "")
    }
}
