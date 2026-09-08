import Foundation
import XCTest

@testable import TunnelVision

/// Stands in for the Accessibility API: windows per pid, minimise calls recorded.
@MainActor
final class FakeWindowManager: WindowManaging {
    var trusted = true
    var apps: [ProcessSnapshot] = []
    var windowsByPID: [pid_t: [AXWindowSnapshot]] = [:]
    var calls: [(id: CGWindowID, minimized: Bool)] = []
    var observed: Set<pid_t> = []

    var isTrusted: Bool { trusted }

    func runningApplications() -> [ProcessSnapshot] { apps }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { windowsByPID[pid] ?? [] }

    func setMinimized(_ minimized: Bool, windowID: CGWindowID, pid: pid_t) -> Bool {
        guard var list = windowsByPID[pid], let index = list.firstIndex(where: { $0.id == windowID }) else { return false }
        let old = list[index]
        list[index] = AXWindowSnapshot(id: old.id, title: old.title, isMinimized: minimized, isStandard: old.isStandard)
        windowsByPID[pid] = list
        calls.append((windowID, minimized))
        return true
    }

    func observe(pid: pid_t, onChange: @escaping @MainActor () -> Void) { observed.insert(pid) }
    func stopObserving(pid: pid_t) { observed.remove(pid) }

    // MARK: Helpers

    func launch(_ bundleID: String, name: String, pid: pid_t) {
        apps.append(ProcessSnapshot(pid: pid, name: name, bundleID: bundleID, isSelf: false, isRegularApp: true))
    }

    func addWindow(_ id: CGWindowID, pid: pid_t, title: String, minimized: Bool = false, standard: Bool = true) {
        windowsByPID[pid, default: []].append(AXWindowSnapshot(id: id, title: title, isMinimized: minimized, isStandard: standard))
    }

    func retitle(_ id: CGWindowID, pid: pid_t, to title: String) {
        guard var list = windowsByPID[pid], let index = list.firstIndex(where: { $0.id == id }) else { return }
        let old = list[index]
        list[index] = AXWindowSnapshot(id: old.id, title: title, isMinimized: old.isMinimized, isStandard: old.isStandard)
        windowsByPID[pid] = list
    }

    func isMinimized(_ id: CGWindowID, pid: pid_t) -> Bool {
        windowsByPID[pid]?.first { $0.id == id }?.isMinimized ?? false
    }

    var minimised: [CGWindowID] { calls.filter(\.minimized).map(\.id) }
    var restored: [CGWindowID] { calls.filter { !$0.minimized }.map(\.id) }
}

private let xcode = "com.apple.dt.Xcode"
private let helium = "net.imput.helium"
private let slack = "com.example.slack"

@MainActor
final class WindowEnforcerTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_752_000_000)

    private func makeEnforcer(_ fake: FakeWindowManager) -> WindowEnforcer {
        WindowEnforcer(windows: fake, clock: { [self] in now }, autoSweep: false)
    }

    private func xcodeWorld() -> FakeWindowManager {
        let fake = FakeWindowManager()
        fake.launch(xcode, name: "Xcode", pid: 10)
        fake.addWindow(1, pid: 10, title: "Anchor — AppState.swift")
        fake.addWindow(2, pid: 10, title: "Other — main.swift")
        return fake
    }

    // MARK: Policy

    func testTitlePatternsSkipWholeAppAndURLBundles() {
        let rules = [
            Rule(bundleID: xcode, scope: .window, pattern: " Anchor "),
            Rule(bundleID: slack, scope: .window, pattern: "Engineering"),
            Rule(bundleID: slack),
            Rule(bundleID: helium, scope: .window, pattern: "Docs"),
            Rule(bundleID: helium, scope: .url, pattern: "github.com"),
            Rule(bundleID: xcode, scope: .window, pattern: "Denied", effect: .deny),
            Rule(bundleID: "", scope: .window, pattern: "Orphan"),
        ]
        let patterns = WindowLockPolicy.titlePatterns(rules: rules)
        XCTAssertEqual(patterns, [xcode: ["anchor"]], "an app rule allows Slack whole; Helium's URL rules make it the browser layer's")
        XCTAssertTrue(WindowLockPolicy.matches(title: "anchor — Models.swift", patterns: ["anchor"]))
        XCTAssertFalse(WindowLockPolicy.matches(title: "Something", patterns: [""]))
    }

    // MARK: Lock

    func testLockMinimisesNonMatchingWindowsAndKeepsMatching() {
        let fake = xcodeWorld()
        let enforcer = makeEnforcer(fake)
        var notices: [String] = []
        enforcer.onBlockedWindow = { _, _, title in notices.append(title) }

        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertTrue(enforcer.isActive)
        XCTAssertEqual(fake.minimised, [2], "only the window off the rule goes")
        XCTAssertFalse(fake.isMinimized(1, pid: 10))
        XCTAssertEqual(notices, ["Other — main.swift"])
        XCTAssertTrue(fake.observed.contains(10), "the app is watched for new and retitled windows")
    }

    func testMatchedWindowStaysAllowedWhenRetitled() {
        let fake = xcodeWorld()
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])

        // The editor switches files: the title no longer contains "Anchor".
        fake.retitle(1, pid: 10, to: "Untitled 3")
        enforcer.sweepAll()
        XCTAssertFalse(fake.isMinimized(1, pid: 10), "a window that matched once is allowed for the session")
        XCTAssertEqual(fake.minimised, [2])
    }

    func testNewWindowsAreJudgedByTitle() {
        let fake = xcodeWorld()
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])

        fake.addWindow(3, pid: 10, title: "Anchor — Tests.swift")
        fake.addWindow(4, pid: 10, title: "Reddit")
        enforcer.sweepAll()
        XCTAssertFalse(fake.isMinimized(3, pid: 10))
        XCTAssertTrue(fake.isMinimized(4, pid: 10))

        // The user brings the blocked one back: it goes again.
        fake.setMinimized(false, windowID: 4, pid: 10)
        enforcer.sweepAll()
        XCTAssertTrue(fake.isMinimized(4, pid: 10))
    }

    func testUnlockRestoresOnlyWhatItMinimised() {
        let fake = xcodeWorld()
        fake.addWindow(5, pid: 10, title: "Parked", minimized: true)
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertEqual(fake.minimised, [2], "a window the user had minimised is not touched")

        enforcer.unlock()
        XCTAssertFalse(enforcer.isActive)
        XCTAssertEqual(fake.restored, [2])
        XCTAssertTrue(fake.isMinimized(5, pid: 10), "the user's own minimised window stays put")
        XCTAssertTrue(fake.observed.isEmpty)
    }

    func testAllowForSessionBringsMatchingWindowsBack() {
        let fake = xcodeWorld()
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertTrue(fake.isMinimized(2, pid: 10))

        enforcer.allowForSession(bundleID: xcode, titlePattern: "Other — main.swift")
        XCTAssertFalse(fake.isMinimized(2, pid: 10))
        enforcer.sweepAll()
        XCTAssertFalse(fake.isMinimized(2, pid: 10), "and it is not minimised again")
        fake.addWindow(6, pid: 10, title: "[other — main.swift] copy")
        fake.addWindow(7, pid: 10, title: "Other — README.md")
        enforcer.sweepAll()
        XCTAssertFalse(fake.isMinimized(6, pid: 10), "the session pattern matches new windows too, case-insensitively")
        XCTAssertTrue(fake.isMinimized(7, pid: 10), "but it is the whole title, not a word of it")
    }

    func testRelockAllowingTheWholeAppRestoresItsWindows() {
        let fake = xcodeWorld()
        fake.launch(slack, name: "Slack", pid: 20)
        fake.addWindow(21, pid: 20, title: "General")
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [
            Rule(bundleID: xcode, scope: .window, pattern: "Anchor"),
            Rule(bundleID: slack, scope: .window, pattern: "Engineering"),
        ])
        XCTAssertEqual(Set(fake.minimised), [2, 21])

        // "Add to preset" allowed Slack as a whole app.
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor"), Rule(bundleID: slack)])
        XCTAssertEqual(fake.restored, [21])
        XCTAssertTrue(enforcer.isActive)
        XCTAssertTrue(fake.isMinimized(2, pid: 10), "Xcode's discipline continues")
    }

    func testNoWindowRulesMeansInactive() {
        let fake = xcodeWorld()
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode)])
        XCTAssertFalse(enforcer.isActive)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testWithoutAccessibilityTheLayerIsInert() {
        let fake = xcodeWorld()
        fake.trusted = false
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertFalse(enforcer.isActive, "a window rule falls back to allowing the whole app")
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testUntitledWindowsGetAGracePeriod() {
        let fake = xcodeWorld()
        fake.addWindow(7, pid: 10, title: "")
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertFalse(fake.isMinimized(7, pid: 10), "a window may still be getting its title")

        now = now.addingTimeInterval(WindowEnforcer.untitledGrace + 0.1)
        enforcer.sweepAll()
        XCTAssertTrue(fake.isMinimized(7, pid: 10), "still untitled after the grace: minimised")
    }

    func testUntitledWindowThatGainsAMatchingTitleIsAllowed() {
        let fake = xcodeWorld()
        fake.addWindow(7, pid: 10, title: "")
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        fake.retitle(7, pid: 10, to: "Anchor — New.swift")
        now = now.addingTimeInterval(5)
        enforcer.sweepAll()
        XCTAssertFalse(fake.isMinimized(7, pid: 10))
    }

    func testMinimisedUntitledWindowIsRestoredWhenItsTitleMatches() {
        let fake = xcodeWorld()
        fake.addWindow(7, pid: 10, title: "")
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])

        // The window stayed untitled past its grace: it is minimised.
        now = now.addingTimeInterval(WindowEnforcer.untitledGrace + 0.1)
        enforcer.sweepAll()
        XCTAssertTrue(fake.isMinimized(7, pid: 10))

        // The app then names it with a matching title: it must come back,
        // not sit in the Dock for the rest of the session.
        fake.retitle(7, pid: 10, to: "Anchor — AppState.swift")
        enforcer.sweepAll()
        XCTAssertFalse(fake.isMinimized(7, pid: 10), "a window that matches a rule is restored on screen")
        XCTAssertTrue(fake.restored.contains(7))
        enforcer.sweepAll()
        XCTAssertFalse(fake.isMinimized(7, pid: 10), "and stays up on later sweeps")
    }

    func testNonStandardWindowsAreIgnored() {
        let fake = xcodeWorld()
        fake.addWindow(8, pid: 10, title: "Find", standard: false)
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertFalse(fake.isMinimized(8, pid: 10), "palettes and dialogs are not disciplined")
    }

    func testBlockedWindowNoticesAreThrottledPerApp() {
        let fake = xcodeWorld()
        fake.addWindow(9, pid: 10, title: "Also off")
        let enforcer = makeEnforcer(fake)
        var notices: [String] = []
        enforcer.onBlockedWindow = { _, _, title in notices.append(title) }
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertEqual(notices.count, 1, "two windows minimised in one sweep: one notice")

        now = now.addingTimeInterval(5)
        fake.setMinimized(false, windowID: 2, pid: 10)
        enforcer.sweepAll()
        XCTAssertEqual(notices.count, 2)
    }
}
