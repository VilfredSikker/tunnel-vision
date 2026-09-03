import Foundation
import XCTest

@testable import Anchor

/// Records every action instead of touching real apps.
@MainActor
final class FakeProcessManager: ProcessManaging {
    var apps: [ProcessSnapshot] = []
    var hidden: [pid_t] = []
    var unhidden: [pid_t] = []
    var terminated: [pid_t] = []
    var suspended: [pid_t] = []
    var resumed: [pid_t] = []
    var failSuspend = false

    func runningApplications() -> [ProcessSnapshot] {
        apps.filter { !terminated.contains($0.pid) }
    }

    func bundleID(of pid: pid_t) -> String? {
        apps.first { $0.pid == pid }?.bundleID
    }

    func hide(pid: pid_t) {
        guard !terminated.contains(pid) else { return }
        if !hidden.contains(pid) { hidden.append(pid) }
    }

    func unhide(pid: pid_t) {
        if !unhidden.contains(pid) { unhidden.append(pid) }
    }

    func terminate(pid: pid_t) {
        if !terminated.contains(pid) { terminated.append(pid) }
    }

    func suspend(pid: pid_t) -> Bool {
        guard !failSuspend, !terminated.contains(pid) else { return false }
        if !suspended.contains(pid) { suspended.append(pid) }
        return true
    }

    func resume(pid: pid_t) -> Bool {
        if !resumed.contains(pid) { resumed.append(pid) }
        return true
    }

    func isRunning(pid: pid_t) -> Bool {
        apps.contains { $0.pid == pid } && !terminated.contains(pid)
    }

    func launch(bundleID: String, name: String = "App", pid: pid_t = 9001, regular: Bool = true) {
        apps.append(ProcessSnapshot(pid: pid, name: name, bundleID: bundleID, isSelf: false, isRegularApp: regular))
    }
}

private let slackID = "com.example.slack"
private let xcodeID = "com.apple.dt.Xcode"

@MainActor
final class EnforcerTests: XCTestCase {
    private var thawURL: URL!
    private var store: FrozenPidStore!

    override func setUp() async throws {
        thawURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnchorEnforcer-\(UUID().uuidString)")
            .appendingPathComponent("frozen-pids.json")
        store = FrozenPidStore(url: thawURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: thawURL.deletingLastPathComponent())
    }

    // MARK: Pure policy

    func testAllowedBundlesFromRules() {
        let rules = [
            Rule(bundleID: xcodeID),
            Rule(bundleID: slackID, scope: .url, pattern: "example.com"),
            Rule(bundleID: "com.example.denied", effect: .deny),
            Rule(bundleID: "   "),
        ]
        let allowed = LockPolicy.allowedBundleIDs(rules: rules)
        XCTAssertTrue(allowed.contains(xcodeID))
        XCTAssertTrue(allowed.contains(slackID), "any-scope rule admits the whole app at layer 1")
        XCTAssertFalse(allowed.contains("com.example.denied"))
        XCTAssertEqual(allowed.count, 2)
    }

    func testEnforcementDecision() {
        let allowed: Set<String> = [xcodeID]
        func decide(_ mode: Mode, _ bundleID: String?, regular: Bool = true, exempt: Set<String> = []) -> Enforcement {
            Enforcement.decide(mode: mode, bundleID: bundleID, isRegularApp: regular, allowed: allowed, exempt: exempt)
        }
        XCTAssertEqual(decide(.dark, nil), .none, "unbundled processes are untargetable")
        XCTAssertEqual(decide(.dark, xcodeID), .none)
        XCTAssertEqual(decide(.dark, "com.apple.finder", exempt: LockPolicy.exemptSystemBundles), .none)
        XCTAssertEqual(decide(.dark, slackID), .dark)
        XCTAssertEqual(decide(.closed, slackID), .closed)
        XCTAssertEqual(decide(.frozen, slackID), .frozen)
        XCTAssertEqual(decide(.frozen, slackID, regular: false), .none, "only Cmd-Tab apps are policed")
        XCTAssertEqual(decide(.closed, "com.example.menubar-helper", regular: false), .none)
    }

    func testBackgroundAppsAreNeverEnforced() {
        let fake = FakeProcessManager()
        fake.launch(bundleID: slackID, name: "Slack", pid: 102)
        fake.launch(bundleID: "com.example.helper", name: "Helper Agent", pid: 104, regular: false)
        let enforcer = AppEnforcer(process: fake, frozenStore: store)

        enforcer.lock(mode: .frozen, rules: [Rule(bundleID: xcodeID)])
        XCTAssertTrue(fake.suspended.contains(102), "regular apps off the allowlist are frozen")
        XCTAssertFalse(fake.hidden.contains(104), "a menu-bar helper cannot appear in the picker, so it is never punished")
        XCTAssertFalse(fake.suspended.contains(104))
    }

    // MARK: Modes

    func testDarkHidesDisallowedAppsAndUnhidesOnUnlock() {
        let fake = FakeProcessManager()
        fake.launch(bundleID: xcodeID, name: "Xcode", pid: 101)
        fake.launch(bundleID: slackID, name: "Slack", pid: 102)
        fake.launch(bundleID: "com.apple.finder", name: "Finder", pid: 103)
        let enforcer = AppEnforcer(process: fake, frozenStore: store)

        enforcer.lock(mode: .dark, rules: [Rule(bundleID: xcodeID)])
        XCTAssertTrue(fake.hidden.contains(102))
        XCTAssertFalse(fake.hidden.contains(101), "allowed app stays visible")
        XCTAssertFalse(fake.hidden.contains(103), "system apps are exempt")

        enforcer.unlock()
        XCTAssertTrue(fake.unhidden.contains(102))
    }

    func testClosedTerminatesDisallowedApps() {
        let fake = FakeProcessManager()
        fake.launch(bundleID: xcodeID, name: "Xcode", pid: 101)
        fake.launch(bundleID: slackID, name: "Slack", pid: 102)
        let enforcer = AppEnforcer(process: fake, frozenStore: store)

        enforcer.lock(mode: .closed, rules: [Rule(bundleID: xcodeID)])
        XCTAssertTrue(fake.terminated.contains(102))
        XCTAssertFalse(fake.terminated.contains(101))
    }

    func testFrozenSuspendsHidesAndThawsOnUnlock() {
        let fake = FakeProcessManager()
        fake.launch(bundleID: slackID, name: "Slack", pid: 102)
        let enforcer = AppEnforcer(process: fake, frozenStore: store)

        enforcer.lock(mode: .frozen, rules: [Rule(bundleID: xcodeID)])
        XCTAssertTrue(fake.hidden.contains(102), "frozen = hidden + SIGSTOP")
        XCTAssertTrue(fake.suspended.contains(102))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thawURL.path), "frozen pids are persisted crash-safe")

        enforcer.unlock()
        XCTAssertTrue(fake.resumed.contains(102))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thawURL.path), "thaw file cleared on clean unlock")
    }

    func testAppLaunchedDuringSessionIsEnforced() {
        let fake = FakeProcessManager()
        fake.launch(bundleID: xcodeID, name: "Xcode", pid: 101)
        let enforcer = AppEnforcer(process: fake, frozenStore: store)
        enforcer.lock(mode: .dark, rules: [Rule(bundleID: xcodeID)])
        XCTAssertTrue(fake.hidden.isEmpty)

        fake.launch(bundleID: slackID, name: "Slack", pid: 555)
        enforcer.enforce(snapshot: fake.apps.last!)
        XCTAssertTrue(fake.hidden.contains(555), "a blocked app opened mid-session is hidden at once")
    }

    func testAllowForSessionUnfreezesAndUnhides() {
        let fake = FakeProcessManager()
        fake.launch(bundleID: slackID, name: "Slack", pid: 102)
        let enforcer = AppEnforcer(process: fake, frozenStore: store)

        enforcer.lock(mode: .frozen, rules: [Rule(bundleID: xcodeID)])
        XCTAssertTrue(fake.suspended.contains(102))

        enforcer.allowForSession(bundleID: slackID)
        XCTAssertTrue(fake.resumed.contains(102), "allowed mid-session apps are thawed")
        XCTAssertTrue(fake.unhidden.contains(102))

        // A later launch of the same app must now pass.
        fake.launch(bundleID: slackID, name: "Slack", pid: 556)
        enforcer.enforce(snapshot: fake.apps.last!)
        XCTAssertFalse(fake.hidden.contains(556))
    }

    func testBlockedNoticeFiresThrottled() {
        let fake = FakeProcessManager()
        fake.launch(bundleID: slackID, name: "Slack", pid: 102)
        let enforcer = AppEnforcer(process: fake, frozenStore: store)
        var notices: [String] = []
        enforcer.onBlockedApp = { name, _ in notices.append(name) }

        enforcer.lock(mode: .dark, rules: [Rule(bundleID: xcodeID)])
        XCTAssertEqual(notices, ["Slack"])
        enforcer.enforce(snapshot: fake.apps.first { $0.bundleID == slackID }!)
        XCTAssertEqual(notices.count, 1, "notices are throttled per bundle")
        enforcer.unlock()
    }

    func testRelockWithGrownAllowlistRestoresVictims() {
        let fake = FakeProcessManager()
        fake.launch(bundleID: slackID, name: "Slack", pid: 102)
        let enforcer = AppEnforcer(process: fake, frozenStore: store)

        enforcer.lock(mode: .dark, rules: [Rule(bundleID: xcodeID)])
        XCTAssertTrue(fake.hidden.contains(102))

        // "Add to preset" arrives mid-session → relock with Slack allowed.
        enforcer.lock(mode: .dark, rules: [Rule(bundleID: xcodeID), Rule(bundleID: slackID)])
        XCTAssertTrue(fake.unhidden.contains(102), "newly allowed victims come back at once")
        XCTAssertEqual(fake.hidden.count, 1, "relock must not hide the newly allowed app again")
    }

    func testThawsFrozenAppsFromPreviousRun() {
        let fake = FakeProcessManager()
        fake.launch(bundleID: slackID, name: "Slack", pid: 777)
        try? FileManager.default.createDirectory(at: thawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("[777]".utf8).write(to: thawURL)

        let enforcer = AppEnforcer(process: fake, frozenStore: store)
        XCTAssertTrue(fake.resumed.contains(777), "Anchor died frozen: next launch SIGCONTs survivors")
        XCTAssertTrue(fake.unhidden.contains(777), "frozen victims were hidden too and come back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: thawURL.path))
        XCTAssertFalse(enforcer.isLocking)
    }

    func testFrozenSuspendFailureKeepsHiddenRecord() {
        let fake = FakeProcessManager()
        fake.launch(bundleID: slackID, name: "Slack", pid: 102)
        fake.failSuspend = true
        let enforcer = AppEnforcer(process: fake, frozenStore: store)

        enforcer.lock(mode: .frozen, rules: [Rule(bundleID: xcodeID)])
        XCTAssertTrue(fake.hidden.contains(102), "hidden even when the stop fails")
        XCTAssertFalse(fake.suspended.contains(102))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thawURL.path), "hide is crash-safe on its own")

        enforcer.unlock()
        XCTAssertTrue(fake.unhidden.contains(102))
        XCTAssertFalse(fake.resumed.contains(102), "nothing was stopped, nothing to resume")
        XCTAssertFalse(FileManager.default.fileExists(atPath: thawURL.path))
    }

    func testCrashRestoreUnhidesDarkModeVictim() throws {
        let fake = FakeProcessManager()
        fake.launch(bundleID: slackID, name: "Slack", pid: 778)
        let dir = thawURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let victim = FrozenPidStore.Victim(pid: 778, hidden: true, frozen: false)
        try JSONEncoder().encode([victim]).write(to: thawURL)

        let enforcer = AppEnforcer(process: fake, frozenStore: store)
        XCTAssertTrue(fake.unhidden.contains(778), "hidden-only victims are restored after a crash")
        XCTAssertFalse(fake.resumed.contains(778))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thawURL.path))
        XCTAssertFalse(enforcer.isLocking)
    }
}
